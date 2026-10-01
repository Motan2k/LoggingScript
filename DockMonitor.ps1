#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnostic monitor for Dell WD19TBS (Thunderbolt) dock peripherals failing after sleep / resume.

.DESCRIPTION
    Logs everything around sleep, resume, lock, unlock and logon that can affect the dock:
      - power transitions (Win32_PowerManagementEvent, Kernel-Power, Power-Troubleshooter, loop time gaps)
      - PnP device arrivals / removals / status changes (dock, Thunderbolt, USB, HID, NIC, monitors, audio)
      - every Windows service state change
      - process starts / stops (all of them inside a 5 min window after resume / logon / lock,
        selected ones - Dell, Thunderbolt, scripts, msiexec, pnputil... - at any time)
      - session state (console user, lock / logon screen) and logon / unlock events
      - relevant event logs (System, Kernel-PnP, LSM, Winlogon, User Profile, GroupPolicy, MDM, Security...)
      - full snapshots at fixed offsets after resume, lock and logon, diffed against the previous
        snapshot and against the last "healthy" reference (user logged on, screen unlocked)
      - configuration dump at start: power settings, USB selective suspend, modern standby,
        DMA / BitLocker / device-installation policies, per-device power management flags

    Output: <LogRoot>\DockMonitor_yyyy-MM-dd.log (one file per day, kept RetentionDays days).

.EXAMPLE
    .\DockMonitor.ps1 -Install
    Copies the script to C:\ProgramData\DockMonitor, registers a SYSTEM scheduled task that starts
    at boot (so the lock screen and the logon itself are covered) and starts it now.
.EXAMPLE
    .\DockMonitor.ps1 -Install -EnableDiagnosticLogs
    Same, and also enables the DriverFrameworks-UserMode log and the "Plug and Play Events" /
    "Other Logon/Logoff Events" audit subcategories (may be overridden by company GPO).
.EXAMPLE
    .\DockMonitor.ps1 -Run
    Runs in the current elevated console (Ctrl+C to stop). Output is also shown on screen.
.EXAMPLE
    .\DockMonitor.ps1 -CollectReports
    Sleep study, sleep diagnostics, device/service lists, gpresult and evtx exports -> zip.
.EXAMPLE
    .\DockMonitor.ps1 -Uninstall
    Removes the scheduled task and stops the monitor. Logs are kept.
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')][switch]$Run,
    [Parameter(ParameterSetName = 'Install')][switch]$Install,
    [Parameter(ParameterSetName = 'Install')][switch]$EnableDiagnosticLogs,
    [Parameter(ParameterSetName = 'Uninstall')][switch]$Uninstall,
    [Parameter(ParameterSetName = 'Reports')][switch]$CollectReports,
    [Parameter(ParameterSetName = 'Reports')][int]$ReportDays = 3,

    [string]$LogRoot = (Join-Path $env:ProgramData 'DockMonitor'),
    [int]$PollSeconds = 2,
    [int]$PeriodicSnapshotMinutes = 5,
    [int]$LookbackMinutes = 10,
    [int]$RetentionDays = 14
)

$ErrorActionPreference = 'Continue'
$TaskName = 'DockMonitor'

# Devices considered "dock related" (flagged <DOCK> in the log)
$DockNameRegex = 'Dell|Dock|WD19|Thunderbolt|USB4|Realtek USB|ASMedia|Type-C|UCSI|Billboard|DisplayLink|MST|USB Hub|Root Hub'
$DockIdRegex   = 'VID_413C|VID_0BDA|VID_8087|VID_2109|VID_1A40|TBT|THUNDERBOLT|USB4'
# Processes that are always logged, not only inside the resume / logon window
$InterestingProcRegex = '(?i)dell|thunder|tbt|displaylink|realtek|pnputil|devcon|drvinst|gpscript|msiexec|intune|agentexecutor|powershell|pwsh|wscript|cscript|^reg\.exe|^sc\.exe|^net1?\.exe|powercfg|rundll32|dism'

$SeriesOffsets = @{
    RESUME = @(0, 5, 15, 30, 60, 120, 300)
    LOGON  = @(0, 5, 15, 30, 60, 120, 300)
    LOCK   = @(0, 10, 30)
}

$CmErrorText = @{
    1 = 'not configured'; 3 = 'driver corrupted / low memory'; 10 = 'cannot start'; 12 = 'no free resources'
    14 = 'restart required'; 18 = 'reinstall drivers'; 19 = 'registry problem'; 21 = 'being removed'
    22 = 'disabled'; 24 = 'not present / not working'; 28 = 'no driver'; 31 = 'driver failed to load'
    32 = 'driver disabled (start type)'; 37 = 'driver returned failure'; 39 = 'driver corrupted or missing'
    43 = 'stopped, reported problems'; 45 = 'not connected'; 47 = 'safe removal pending'; 48 = 'blocked (known problems)'
    52 = 'unsigned driver'
}

#region Logging helpers ------------------------------------------------------------------------

function Write-Log {
    param([string]$Tag, [string]$Message)
    $line = '{0} [{1,-7}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Tag, $Message
    $file = Join-Path $LogRoot ('DockMonitor_{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
    for ($i = 0; $i -lt 5; $i++) {
        try { [System.IO.File]::AppendAllText($file, $line + "`r`n", [System.Text.Encoding]::UTF8); break }
        catch { Start-Sleep -Milliseconds 50 }
    }
    if ($script:Interactive) { Write-Host $line }
}

function Get-Condensed([string]$Text, [int]$Max = 400) {
    if (-not $Text) { return '' }
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max) + '...' }
    $t
}

function Write-CommandOutput([string]$Tag, [string]$Prefix, [scriptblock]$Command) {
    try {
        foreach ($l in @(& $Command 2>&1)) {
            $s = ([string]$l).TrimEnd()
            if ($s.Trim()) { Write-Log $Tag "$Prefix $s" }
        }
    } catch { Write-Log WARN "$Prefix failed: $($_.Exception.Message)" }
}

function Remove-OldLogs {
    Get-ChildItem -Path $LogRoot -Filter 'DockMonitor_*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

#endregion

#region Devices / snapshots -------------------------------------------------------------------

function Test-DockRelated($d) {
    ($d.Name -match $DockNameRegex) -or ($d.Id -match $DockIdRegex)
}

function Format-Device($d) {
    $flag = if (Test-DockRelated $d) { ' <DOCK>' } else { '' }
    $err = if ($d.Err -ne 0) { " err=$($d.Err) ($($CmErrorText[[int]$d.Err]))" } else { '' }
    '{0} [{1}] status={2}{3}{4} | {5}' -f $d.Name, $d.Class, $d.Status, $err, $flag, $d.Id
}

function Get-DeviceTable {
    $t = @{}
    foreach ($d in @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue)) {
        if (-not $d.DeviceID) { continue }
        $t[$d.DeviceID] = [pscustomobject]@{
            Id     = $d.DeviceID
            Name   = $d.Name
            Class  = $d.PNPClass
            Status = $d.Status
            Err    = [int]$d.ConfigManagerErrorCode
        }
    }
    $t
}

function Compare-DeviceTable($Old, $New, [string]$Tag, [string]$Context) {
    $n = 0
    foreach ($k in $New.Keys) {
        if (-not $Old.ContainsKey($k)) {
            Write-Log $Tag "$Context [+DEV] $(Format-Device $New[$k])"; $n++
            continue
        }
        $o = $Old[$k]; $c = $New[$k]
        if ($o.Status -ne $c.Status -or $o.Err -ne $c.Err) {
            Write-Log $Tag ("{0} [~DEV] {1}: status {2}/err {3} -> {4}/err {5}" -f $Context, (Format-Device $c), $o.Status, $o.Err, $c.Status, $c.Err); $n++
        }
    }
    foreach ($k in $Old.Keys) {
        if (-not $New.ContainsKey($k)) { Write-Log $Tag "$Context [-DEV] $(Format-Device $Old[$k])"; $n++ }
    }
    $n
}

function Update-DeviceCache {
    $script:DevDirtyAt = $null
    $new = Get-DeviceTable
    $n = Compare-DeviceTable $script:DevCache $new 'PNP' '[live]'
    if ($n -eq 0) { Write-Log PNP '[live] device change event, but no device added/removed/changed status' }
    $script:DevCache = $new
}

function Get-SystemSnapshot {
    $snap = @{ Time = Get-Date }
    $snap.Devices = Get-DeviceTable

    $svc = @{}
    foreach ($s in @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue)) {
        $svc[$s.Name] = [pscustomobject]@{ Name = $s.Name; Display = $s.DisplayName; State = $s.State; StartMode = $s.StartMode }
    }
    $snap.Services = $svc

    $proc = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $proc[$p.ProcessName] = [int]$proc[$p.ProcessName] + 1 }
    $snap.Processes = $proc

    $net = @{}
    try {
        foreach ($a in @(Get-NetAdapter -ErrorAction Stop)) {
            $net[$a.Name] = [pscustomobject]@{ Name = $a.Name; Desc = $a.InterfaceDescription; Status = [string]$a.Status; Speed = [string]$a.LinkSpeed }
        }
    } catch {}
    $snap.Net = $net

    $mon = @{}
    foreach ($m in @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue)) {
        $mon[$m.InstanceName] = [bool]$m.Active
    }
    $snap.Monitors = $mon

    $snap.User = $script:SessUser
    $snap.Locked = $script:SessLock
    $snap
}

function Write-SnapshotSummary($Snap, [string]$Label) {
    $devs     = @($Snap.Devices.Values)
    $dock     = @($devs | Where-Object { Test-DockRelated $_ })
    $dockErr  = @($dock | Where-Object { $_.Err -ne 0 })
    $problem  = @($devs | Where-Object { $_.Err -ne 0 })
    $kbd      = @($devs | Where-Object { $_.Class -eq 'Keyboard' -and $_.Err -eq 0 }).Count
    $mouse    = @($devs | Where-Object { $_.Class -eq 'Mouse' -and $_.Err -eq 0 }).Count
    $audio    = @($devs | Where-Object { $_.Class -eq 'AudioEndpoint' -and $_.Err -eq 0 }).Count
    $monAct   = @($Snap.Monitors.Values | Where-Object { $_ }).Count
    $autoDown = @($Snap.Services.Values | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' } | Sort-Object Name)
    $netTxt   = (@($Snap.Net.Values | Sort-Object Name | ForEach-Object { '{0}={1} ({2})' -f $_.Name, $_.Status, $_.Desc }) -join '; ')

    Write-Log SNAP ("[{0}] user='{1}' lockScreen={2} | dockDevices={3} (errors={4}) | keyboards={5} mice={6} audioEndpoints={7} | monitors active={8}/{9} | problemDevices={10} | autoServicesNotRunning={11}" -f `
        $Label, $Snap.User, $Snap.Locked, $dock.Count, $dockErr.Count, $kbd, $mouse, $audio, $monAct, $Snap.Monitors.Count, $problem.Count, $autoDown.Count)
    Write-Log SNAP "[$Label]   network: $netTxt"
    foreach ($d in $problem) { Write-Log SNAP "[$Label]   problem device: $(Format-Device $d)" }
    if ($autoDown.Count) { Write-Log SNAP "[$Label]   auto-start services not running: $((@($autoDown | ForEach-Object { $_.Name })) -join ', ')" }
}

function Compare-Snapshot($Old, $New, [string]$Label, [switch]$IncludeProcesses) {
    if (-not $Old) { return }
    $ctx = "[$Label]"
    $n = Compare-DeviceTable $Old.Devices $New.Devices 'DIFF' $ctx

    foreach ($k in $New.Services.Keys) {
        $o = $Old.Services[$k]; $c = $New.Services[$k]
        if (-not $o) { Write-Log DIFF "$ctx [+SVC] $k ($($c.Display)) state=$($c.State) start=$($c.StartMode)"; $n++; continue }
        if ($o.State -ne $c.State -or $o.StartMode -ne $c.StartMode) {
            Write-Log DIFF ('{0} [~SVC] {1} ({2}): {3} -> {4} (StartMode {5} -> {6})' -f $ctx, $k, $c.Display, $o.State, $c.State, $o.StartMode, $c.StartMode); $n++
        }
    }
    foreach ($k in $Old.Services.Keys) {
        if (-not $New.Services.ContainsKey($k)) { Write-Log DIFF "$ctx [-SVC] $k ($($Old.Services[$k].Display))"; $n++ }
    }

    foreach ($k in $New.Net.Keys) {
        $o = $Old.Net[$k]; $c = $New.Net[$k]
        if (-not $o) { Write-Log DIFF "$ctx [+NET] $k ($($c.Desc)) $($c.Status) $($c.Speed)"; $n++; continue }
        if ($o.Status -ne $c.Status) { Write-Log DIFF "$ctx [~NET] $k ($($c.Desc)): $($o.Status) -> $($c.Status) $($c.Speed)"; $n++ }
    }
    foreach ($k in $Old.Net.Keys) {
        if (-not $New.Net.ContainsKey($k)) { Write-Log DIFF "$ctx [-NET] $k ($($Old.Net[$k].Desc))"; $n++ }
    }

    foreach ($k in $New.Monitors.Keys) {
        if (-not $Old.Monitors.ContainsKey($k)) { Write-Log DIFF "$ctx [+MON] $k active=$($New.Monitors[$k])"; $n++ }
        elseif ($Old.Monitors[$k] -ne $New.Monitors[$k]) { Write-Log DIFF "$ctx [~MON] $k active $($Old.Monitors[$k]) -> $($New.Monitors[$k])"; $n++ }
    }
    foreach ($k in $Old.Monitors.Keys) {
        if (-not $New.Monitors.ContainsKey($k)) { Write-Log DIFF "$ctx [-MON] $k"; $n++ }
    }

    if ($Old.User -ne $New.User -or $Old.Locked -ne $New.Locked) {
        Write-Log DIFF "$ctx [~SESSION] user '$($Old.User)' -> '$($New.User)', lockScreen $($Old.Locked) -> $($New.Locked)"; $n++
    }

    if ($IncludeProcesses) {
        $started = @($New.Processes.Keys | Where-Object { -not $Old.Processes.ContainsKey($_) } | Sort-Object)
        $gone    = @($Old.Processes.Keys | Where-Object { -not $New.Processes.ContainsKey($_) } | Sort-Object)
        if ($started.Count) { Write-Log DIFF "$ctx [+PROC] $($started -join ', ')"; $n++ }
        if ($gone.Count)    { Write-Log DIFF "$ctx [-PROC] $($gone -join ', ')"; $n++ }
    }

    if ($n -eq 0) { Write-Log DIFF "$ctx no differences" }
}

function Test-SessionHealthy {
    $script:SessUser -and -not $script:SessLock -and (Get-Date) -gt $script:WindowUntil -and $script:Pending.Count -eq 0
}

#endregion

#region Series (snapshots after resume / logon / lock) ------------------------------------------

function Start-Series([string]$Kind, [string]$Reason) {
    $now = Get-Date
    $last = $script:LastSeries[$Kind]
    if ($last -and ($now - $last).TotalSeconds -lt 45) {
        Write-Log INFO "$Kind series already running (extra trigger: $Reason)"
        return
    }
    $script:LastSeries[$Kind] = $now
    Write-Log $Kind "==================== $Kind detected ($Reason) ===================="
    foreach ($o in $SeriesOffsets[$Kind]) {
        [void]$script:Pending.Add([pscustomobject]@{ Due = $now.AddSeconds($o); Label = "$Kind +${o}s" })
    }
    $until = $now.AddMinutes(5)
    if ($until -gt $script:WindowUntil) { $script:WindowUntil = $until }

    if ($Kind -eq 'RESUME') {
        Write-CommandOutput RESUME 'powercfg /lastwake:' { powercfg.exe /lastwake }
        try {
            $b = Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | Select-Object -First 1
            if ($b) { Write-Log RESUME "battery status=$($b.BatteryStatus) (2 = on AC / dock power) charge=$($b.EstimatedChargeRemaining)%" }
        } catch {}
    }
}

function Invoke-PendingSnapshots {
    $now = Get-Date
    $due = @($script:Pending | Where-Object { $_.Due -le $now })
    if (-not $due.Count) { return }
    foreach ($d in $due) { $script:Pending.Remove($d) }
    $label = (@($due | ForEach-Object { $_.Label }) -join ' & ')

    $snap = Get-SystemSnapshot
    Write-SnapshotSummary $snap $label
    Compare-Snapshot $script:LastSnap $snap ("$label vs previous snapshot {0:HH:mm:ss}" -f $script:LastSnap.Time) -IncludeProcesses
    if ($script:RefSnap) {
        Compare-Snapshot $script:RefSnap $snap ("$label vs HEALTHY reference {0:HH:mm:ss}" -f $script:RefSnap.Time)
    }
    $script:LastSnap = $snap
}

function Invoke-PeriodicSnapshot {
    $snap = Get-SystemSnapshot
    Write-SnapshotSummary $snap 'periodic'
    Compare-Snapshot $script:LastSnap $snap ("periodic vs previous snapshot {0:HH:mm:ss}" -f $script:LastSnap.Time)
    $script:LastSnap = $snap
    if (Test-SessionHealthy) {
        $script:RefSnap = $snap
        Write-Log SNAP 'healthy reference updated (user logged on, screen unlocked, no resume/logon in progress)'
    }
}

#endregion

#region Session state ---------------------------------------------------------------------------

function Get-ConsoleUser {
    try { (Get-CimInstance -ClassName Win32_ComputerSystem -Property UserName -ErrorAction Stop).UserName } catch { $null }
}

function Test-LockScreen {
    [bool](Get-Process -Name LogonUI -ErrorAction SilentlyContinue)
}

function Update-SessionState {
    $user = Get-ConsoleUser
    $lock = Test-LockScreen

    if ($user -ne $script:SessUser) {
        Write-Log SESSION "console user changed: '$($script:SessUser)' -> '$user'"
        $script:SessUser = $user
        if ($user -and -not $lock) { Start-Series 'LOGON' 'console user appeared' }
    }
    if ($lock -ne $script:SessLock) {
        $script:SessLock = $lock
        if ($lock) {
            Write-Log SESSION 'lock / logon screen (LogonUI.exe) is now SHOWN'
            Start-Series 'LOCK' 'LogonUI.exe started'
        } else {
            Write-Log SESSION "lock / logon screen HIDDEN (user '$user' unlocked or logged on)"
            if ($user) { Start-Series 'LOGON' 'LogonUI.exe closed' }
        }
    }
}

#endregion

#region Event logs ------------------------------------------------------------------------------

$SystemProviders = @(
    'Microsoft-Windows-Kernel-Power', 'Microsoft-Windows-Power-Troubleshooter', 'Microsoft-Windows-Kernel-PnP',
    'Service Control Manager', 'Microsoft-Windows-Winlogon', 'Microsoft-Windows-UserModePowerService',
    'Microsoft-Windows-Kernel-Boot', 'Microsoft-Windows-Kernel-General', 'Microsoft-Windows-DriverFrameworks-UserMode',
    'USBHUB3', 'USBXHCI', 'UcmUcsiCx', 'Microsoft-Windows-USB-USBHUB3', 'Microsoft-Windows-USB-USBXHCI', 'Display',
    'Microsoft-Windows-Dhcp-Client', 'Microsoft-Windows-NDIS', 'Microsoft-Windows-DeviceSetupManager'
)

$SourceDefs = @(
    @{ Log = 'System'; Filter = {
            param($e)
            if ($e.ProviderName -eq 'Service Control Manager' -and $e.Id -eq 7036) { return $false }   # covered by WMI service events
            if ($e.ProviderName -eq 'Microsoft-Windows-DistributedCOM' -and $e.Id -eq 10016) { return $false }
            ($SystemProviders -contains $e.ProviderName) -or ($e.Level -ge 1 -and $e.Level -le 3) -or ($e.ProviderName -match $DockNameRegex)
        } }
    @{ Log = 'Application'; Filter = {
            param($e)
            ($e.Level -ge 1 -and $e.Level -le 2) -or ($e.ProviderName -match 'Winlogon|User Profile|Group Policy') -or
            ($e.Level -eq 3 -and $e.ProviderName -match 'Dell|Thunderbolt|Intel|DisplayLink|Realtek')
        } }
    @{ Log = 'Security'; Ids = @(4624, 4634, 4647, 4800, 4801, 4802, 4803, 6416, 6419, 6420, 6421, 6422, 6423, 6424); Filter = {
            param($e)
            if ($e.Id -eq 4624) {
                ($e.Properties[8].Value -in 2, 7, 10, 11) -and ($e.Properties[6].Value -notin 'Font Driver Host', 'Window Manager')
            } elseif ($e.Id -eq 4634) {
                ($e.Properties[4].Value -in 2, 7, 10, 11) -and ($e.Properties[2].Value -notin 'Font Driver Host', 'Window Manager')
            } else { $true }
        } }
    @{ Log = 'Microsoft-Windows-Kernel-PnP/Configuration' }
    @{ Log = 'Microsoft-Windows-Kernel-PnP/Device Management' }
    @{ Log = 'Microsoft-Windows-DeviceSetupManager/Admin' }
    @{ Log = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational' }
    @{ Log = 'Microsoft-Windows-Winlogon/Operational' }
    @{ Log = 'Microsoft-Windows-User Profile Service/Operational' }
    @{ Log = 'Microsoft-Windows-GroupPolicy/Operational'; Filter = {
            param($e)
            ($e.Level -ge 1 -and $e.Level -le 3) -or ($e.Id -in 4000, 4001, 4004, 4005, 4006, 4016, 5016, 6016, 7016, 8000, 8001, 8004, 8005, 8006)
        } }
    @{ Log = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin'; Filter = { param($e) $e.Level -ge 1 -and $e.Level -le 3 } }
    @{ Log = 'Microsoft-Windows-DriverFrameworks-UserMode/Operational'; Filter = {
            param($e)
            ($e.Level -ge 1 -and $e.Level -le 3) -or ($e.Id -in 2003, 2010, 2100, 2101, 2102, 2105, 2106, 10110, 10111)
        } }
)

function Initialize-EventSources {
    $script:EvtSources = New-Object System.Collections.ArrayList
    $defs = @($SourceDefs)

    # Vendor logs (Thunderbolt / Dell / DisplayLink...) if present
    foreach ($l in @(Get-WinEvent -ListLog * -ErrorAction SilentlyContinue | Where-Object { $_.LogName -match 'Thunderbolt|USB4|Dell|DisplayLink' })) {
        $defs += @{ Log = $l.LogName }
    }

    $start = (Get-Date).AddMinutes(-$LookbackMinutes)
    foreach ($d in $defs) {
        $info = Get-WinEvent -ListLog $d.Log -ErrorAction SilentlyContinue
        if (-not $info) { Write-Log INFO "event log not present: $($d.Log)"; continue }
        if (-not $info.IsEnabled) { Write-Log INFO "event log disabled (skipped): $($d.Log)"; continue }

        $lastId = 0
        $first = Get-WinEvent -FilterHashtable @{ LogName = $d.Log; StartTime = $start } -Oldest -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($first) { $lastId = [long]$first.RecordId - 1 }
        else {
            $newest = Get-WinEvent -LogName $d.Log -MaxEvents 1 -ErrorAction SilentlyContinue
            if ($newest) { $lastId = [long]$newest.RecordId }
        }
        [void]$script:EvtSources.Add([pscustomobject]@{ Log = $d.Log; Ids = $d.Ids; Filter = $d.Filter; LastId = $lastId })
        Write-Log INFO "watching event log: $($d.Log)"
    }
}

function Format-WinEvent($e) {
    $lvl = switch ([int]$e.Level) { 1 { 'CRIT' } 2 { 'ERROR' } 3 { 'WARN' } 5 { 'VERB' } default { 'INFO' } }
    $msg = $null
    try {
        if ($e.LogName -eq 'Security' -and $e.Id -eq 4624) {
            $p = $e.Properties
            $msg = 'LOGON type {0}: {1}\{2} (LogonId 0x{3:X})' -f $p[8].Value, $p[6].Value, $p[5].Value, $p[7].Value
        } elseif ($e.LogName -eq 'Security' -and $e.Id -eq 4634) {
            $p = $e.Properties
            $msg = 'LOGOFF type {0}: {1}\{2}' -f $p[4].Value, $p[2].Value, $p[1].Value
        }
    } catch {}
    if (-not $msg) { try { $msg = $e.Message } catch {} }
    if (-not $msg) { $msg = 'data: ' + (@($e.Properties | ForEach-Object { [string]$_.Value }) -join ' | ') }
    $logShort = $e.LogName -replace '^Microsoft-Windows-', ''
    '{0:HH:mm:ss.fff} {1} | {2} | id={3} {4} | {5}' -f $e.TimeCreated, $logShort, $e.ProviderName, $e.Id, $lvl, (Get-Condensed $msg 500)
}

function Invoke-EventTriggers($e) {
    if (((Get-Date) - $e.TimeCreated).TotalMinutes -gt 3) { return }   # history from the lookback does not trigger series
    $p = $e.ProviderName; $id = $e.Id
    if ($p -eq 'Microsoft-Windows-Kernel-Power' -and $id -in 42, 506) { Write-Log POWER ">>> Kernel-Power $id : system entered sleep / modern standby at $($e.TimeCreated.ToString('HH:mm:ss.fff'))" }
    if ($p -eq 'Microsoft-Windows-Kernel-Power' -and $id -in 107, 507) { Start-Series 'RESUME' "Kernel-Power $id" }
    if ($p -eq 'Microsoft-Windows-Power-Troubleshooter' -and $id -eq 1) { Start-Series 'RESUME' 'Power-Troubleshooter 1' }
    if ($e.LogName -eq 'Security' -and $id -in 4624, 4801) { Start-Series 'LOGON' "Security $id" }
    if ($e.LogName -like '*LocalSessionManager*' -and $id -in 21, 25) { Start-Series 'LOGON' "LocalSessionManager $id" }
    if ($p -eq 'Microsoft-Windows-Winlogon' -and $id -eq 7001) { Start-Series 'LOGON' 'Winlogon 7001' }
}

function Read-EventSources {
    foreach ($src in $script:EvtSources) {
        $cond = "EventRecordID > $($src.LastId)"
        if ($src.Ids) { $cond += ' and (' + ((@($src.Ids | ForEach-Object { "EventID=$_" })) -join ' or ') + ')' }
        $events = @(Get-WinEvent -LogName $src.Log -FilterXPath "*[System[$cond]]" -Oldest -MaxEvents 500 -ErrorAction SilentlyContinue)
        foreach ($e in $events) {
            if ([long]$e.RecordId -gt $src.LastId) { $src.LastId = [long]$e.RecordId }
            $keep = $true
            if ($src.Filter) { try { $keep = [bool](& $src.Filter $e) } catch { $keep = $true } }
            if (-not $keep) { continue }
            Write-Log EVT (Format-WinEvent $e)
            Invoke-EventTriggers $e
        }
    }
}

#endregion

#region WMI subscriptions -----------------------------------------------------------------------

function Register-WmiSubscriptions {
    $queries = [ordered]@{
        DM_Power     = 'SELECT * FROM Win32_PowerManagementEvent'
        DM_DevChange = 'SELECT * FROM Win32_DeviceChangeEvent'
        DM_Svc       = "SELECT * FROM __InstanceModificationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_Service' AND TargetInstance.State <> PreviousInstance.State"
        DM_ProcStart = 'SELECT * FROM Win32_ProcessStartTrace'
        DM_ProcStop  = 'SELECT * FROM Win32_ProcessStopTrace'
    }
    foreach ($k in $queries.Keys) {
        try {
            Register-CimIndicationEvent -Query $queries[$k] -SourceIdentifier $k -ErrorAction Stop | Out-Null
            Write-Log INFO "WMI subscription active: $k"
        } catch {
            if ($k -eq 'DM_Svc') {
                try {
                    Register-CimIndicationEvent -Query "SELECT * FROM __InstanceModificationEvent WITHIN 2 WHERE TargetInstance ISA 'Win32_Service'" -SourceIdentifier $k -ErrorAction Stop | Out-Null
                    Write-Log INFO "WMI subscription active: $k (unfiltered)"
                    continue
                } catch {}
            }
            Write-Log WARN "WMI subscription FAILED: $k - $($_.Exception.Message)"
        }
    }
}

function Get-ProcessNameById([int]$ProcessId) {
    try { (Get-Process -Id $ProcessId -ErrorAction Stop).ProcessName } catch { '?' }
}

function Receive-WmiEvents {
    foreach ($ev in @(Get-Event -ErrorAction SilentlyContinue)) {
        try {
            $ne = $ev.SourceEventArgs.NewEvent
            $inWindow = (Get-Date) -lt $script:WindowUntil
            switch ($ev.SourceIdentifier) {
                'DM_Power' {
                    $t = [int]$ne.EventType
                    $desc = switch ($t) { 4 { 'ENTERING SUSPEND (sleep)' } 7 { 'RESUME from suspend' } 10 { 'power status change (AC / battery)' } 11 { 'OEM event' } 18 { 'RESUME automatic (wake)' } default { 'other' } }
                    Write-Log POWER ("Win32_PowerManagementEvent type {0} = {1} (received {2:HH:mm:ss.fff})" -f $t, $desc, $ev.TimeGenerated)
                    if ($t -eq 4) {
                        Write-Log SUSPEND '==================== SYSTEM GOING TO SLEEP ===================='
                        $snap = Get-SystemSnapshot
                        Write-SnapshotSummary $snap 'SUSPEND'
                        Compare-Snapshot $script:LastSnap $snap 'SUSPEND vs previous snapshot' -IncludeProcesses
                        $script:LastSnap = $snap
                        if ($script:SessUser -and -not $script:SessLock) { $script:RefSnap = $snap; Write-Log SNAP 'healthy reference updated (taken at suspend)' }
                    } elseif ($t -in 7, 18) {
                        Start-Series 'RESUME' "Win32_PowerManagementEvent $t"
                    } elseif ($t -eq 10) {
                        $b = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
                        if ($b) { Write-Log POWER "battery status=$($b.BatteryStatus) (2 = on AC / dock power) charge=$($b.EstimatedChargeRemaining)%" }
                    }
                }
                'DM_DevChange' {
                    $t = [int]$ne.EventType
                    if (-not $script:DevDirtyAt -or $t -ne 1) {
                        $desc = switch ($t) { 1 { 'configuration changed' } 2 { 'device arrival' } 3 { 'device removal' } 4 { 'docking' } default { 'other' } }
                        Write-Log PNP "Win32_DeviceChangeEvent type $t = $desc"
                    }
                    $script:DevDirtyAt = Get-Date
                }
                'DM_Svc' {
                    $ti = $ne.TargetInstance; $pi = $ne.PreviousInstance
                    if ($ti.State -ne $pi.State) {
                        Write-Log SVC ('{0} ({1}): {2} -> {3} [StartMode={4}, PID={5}]' -f $ti.Name, $ti.DisplayName, $pi.State, $ti.State, $ti.StartMode, $ti.ProcessId)
                    }
                }
                'DM_ProcStart' {
                    if ($inWindow -or $ne.ProcessName -match $InterestingProcRegex) {
                        Write-Log PROC ('START {0} pid={1} parent={2}({3}) session={4}' -f $ne.ProcessName, $ne.ProcessID, (Get-ProcessNameById $ne.ParentProcessID), $ne.ParentProcessID, $ne.SessionID)
                    }
                }
                'DM_ProcStop' {
                    if ($inWindow -or $ne.ProcessName -match $InterestingProcRegex) {
                        Write-Log PROC ('STOP  {0} pid={1} exit=0x{2:X}' -f $ne.ProcessName, $ne.ProcessID, [uint32]$ne.ExitStatus)
                    }
                }
            }
        } catch {
            Write-Log WARN "error handling $($ev.SourceIdentifier): $($_.Exception.Message)"
        }
        Remove-Event -EventIdentifier $ev.EventIdentifier -ErrorAction SilentlyContinue
    }
}

#endregion

#region Configuration dump ----------------------------------------------------------------------

function Write-RegistryDump([string]$Path) {
    if (-not (Test-Path $Path)) { Write-Log CONFIG "reg $Path : (not present)"; return }
    $keys = @(Get-Item $Path) + @(Get-ChildItem $Path -Recurse -ErrorAction SilentlyContinue)
    foreach ($k in $keys) {
        $vals = @($k.GetValueNames())
        if (-not $vals.Count) { continue }
        foreach ($v in $vals) {
            $name = if ($v) { $v } else { '(default)' }
            Write-Log CONFIG ('reg {0} : {1} = {2}' -f ($k.Name -replace '^HKEY_LOCAL_MACHINE', 'HKLM'), $name, (Get-Condensed (@($k.GetValue($v)) -join ',') 200))
        }
    }
}

function Get-RegValue([string]$Path, [string]$Name) {
    try { (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { $null }
}

function Get-KernelDmaProtection {
    # Best effort: NtQuerySystemInformation(SystemDmaGuardPolicyInformation = 202)
    try {
        if (-not ('DockMon.NtInfo' -as [type])) {
            Add-Type -Namespace DockMon -Name NtInfo -MemberDefinition '[DllImport("ntdll.dll")] public static extern int NtQuerySystemInformation(int SystemInformationClass, byte[] SystemInformation, int SystemInformationLength, out int ReturnLength);' -ErrorAction Stop
        }
        $buf = New-Object byte[] 1
        $ret = 0
        if ([DockMon.NtInfo]::NtQuerySystemInformation(202, $buf, 1, [ref]$ret) -eq 0) { return [bool]$buf[0] }
    } catch {}
    $null
}

function Write-ConfigDump {
    Write-Log CONFIG '---------------- configuration dump ----------------'
    try {
        $cs = Get-CimInstance Win32_ComputerSystem; $bios = Get-CimInstance Win32_BIOS; $os = Get-CimInstance Win32_OperatingSystem
        $ubr = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'UBR'
        $disp = Get-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'DisplayVersion'
        Write-Log CONFIG "computer: $($cs.Manufacturer) $($cs.Model) | BIOS $($bios.SMBIOSBIOSVersion) ($($bios.ReleaseDate))"
        Write-Log CONFIG "OS: $($os.Caption) $disp build $($os.BuildNumber).$ubr | last boot $($os.LastBootUpTime)"
    } catch {}

    $dma = Get-KernelDmaProtection
    Write-Log CONFIG "Kernel DMA Protection (DMA guard) active: $(if ($null -eq $dma) { 'unknown - check msinfo32' } else { $dma })"

    Write-CommandOutput CONFIG 'powercfg /a:' { powercfg.exe /a }
    Write-CommandOutput CONFIG 'powercfg active scheme:' { powercfg.exe /getactivescheme }
    Write-CommandOutput CONFIG 'powercfg USB settings:' { powercfg.exe /q SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 }
    Write-CommandOutput CONFIG 'powercfg PCIe settings:' { powercfg.exe /q SCHEME_CURRENT 501a4d13-42af-4429-9fd1-a8218c268e20 }
    Write-CommandOutput CONFIG 'powercfg wake armed devices:' { powercfg.exe /devicequery wake_armed }

    $regPaths = @(
        'HKLM:\SOFTWARE\Policies\Microsoft\FVE',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Kernel DMA Protection',
        'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DmaGuard',
        'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DataProtection',
        'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\BitLocker',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall',
        'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeviceInstallation',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Device Control',
        'HKLM:\SOFTWARE\Policies\Microsoft\Power\PowerSettings',
        'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Power',
        'HKLM:\SYSTEM\CurrentControlSet\Services\USB',
        'HKLM:\SYSTEM\CurrentControlSet\Services\USBHUB3\Parameters'
    )
    foreach ($p in $regPaths) { Write-RegistryDump $p }

    foreach ($n in 'CsEnabled', 'PlatformAoAcOverride', 'HibernateEnabled') {
        Write-Log CONFIG "reg HKLM\SYSTEM\CurrentControlSet\Control\Power : $n = $(Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' $n)"
    }
    Write-Log CONFIG "reg ...\Session Manager\Power : HiberbootEnabled (fast startup) = $(Get-RegValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled')"

    # Known policies that block Thunderbolt/USB4 devices until the user unlocks / logs on
    if ((Get-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\FVE' 'DisableExternalDMAUnderLock') -eq 1) {
        Write-Log WARN "POLICY: BitLocker 'Disable new DMA devices when this computer is locked' (DisableExternalDMAUnderLock=1) is ENABLED. Thunderbolt/USB4 DMA devices (like the WD19TBS) are blocked while locked and re-enabled only after unlock/logon - matches the symptom."
    }
    if ((Get-RegValue 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DataProtection' 'AllowDirectMemoryAccess') -eq 0) {
        Write-Log WARN 'POLICY: MDM DataProtection/AllowDirectMemoryAccess = 0 (DMA blocked while locked).'
    }
    foreach ($p in 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Kernel DMA Protection', 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DmaGuard') {
        $v = Get-RegValue $p 'DeviceEnumerationPolicy'
        if ($null -ne $v) {
            $txt = switch ([int]$v) { 0 { 'Block all (non-DMA-remapping devices never start)' } 1 { 'Only after logon / screen unlock' } 2 { 'Allow all' } default { '?' } }
            Write-Log WARN "POLICY: Kernel DMA Protection DeviceEnumerationPolicy = $v ($txt) at $p"
        }
    }
    if (Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions') {
        Write-Log WARN 'POLICY: device installation restrictions are configured (see reg dump above).'
    }

    # Per-device power management ("allow the computer to turn off this device" / wake)
    $wake = @{}
    foreach ($w in @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceWakeEnable -ErrorAction SilentlyContinue)) {
        $wake[($w.InstanceName -replace '_\d+$', '')] = $w.Enable
    }
    foreach ($p in @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction SilentlyContinue)) {
        $id = $p.InstanceName -replace '_\d+$', ''
        $d = $script:DevCache[$id]
        if ($d -and (($d.Class -in 'USB', 'Net', 'HIDClass', 'Keyboard', 'Mouse', 'Media', 'System') -or (Test-DockRelated $d))) {
            $wk = if ($wake.ContainsKey($id)) { $wake[$id] } else { 'n/a' }
            Write-Log CONFIG ("device power mgmt: allowTurnOff={0} wake={1} : {2} [{3}] | {4}" -f $p.Enable, $wk, $d.Name, $d.Class, $id)
        }
    }

    foreach ($s in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)thunder|tbt|dell|displaylink|realtek|rtk|usb|synaptics' -or $_.DisplayName -match '(?i)thunderbolt|dell|displaylink|realtek|usb|dock' })) {
        Write-Log CONFIG "dock-related service: $($s.Name) ($($s.DisplayName)) state=$($s.State) start=$($s.StartMode) path=$(Get-Condensed $s.PathName 150)"
    }

    foreach ($d in @($script:DevCache.Values | Where-Object { Test-DockRelated $_ } | Sort-Object Class, Name)) {
        Write-Log CONFIG "dock-related device: $(Format-Device $d)"
    }
    Write-Log CONFIG '---------------- end of configuration dump ----------------'
}

#endregion

#region Main modes ------------------------------------------------------------------------------

function Start-Monitor {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\DockMonitor_Run')
    $owned = $false
    try { $owned = $mutex.WaitOne(0) }
    catch [System.Threading.AbandonedMutexException] { $owned = $true }
    catch { $owned = $false }
    if (-not $owned) { Write-Warning 'Another DockMonitor instance is already running (scheduled task?). Use -Uninstall first or stop it.'; return }

    try {
        New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
        Remove-OldLogs
        $script:LastCleanup = (Get-Date).Date

        $script:Pending     = New-Object System.Collections.ArrayList
        $script:LastSeries  = @{}
        $script:WindowUntil = [datetime]::MinValue
        $script:DevDirtyAt  = $null
        $script:SessUser    = Get-ConsoleUser
        $script:SessLock    = Test-LockScreen

        Write-Log INFO ('==================== DockMonitor started: PID {0}, account {1}, PowerShell {2}, interactive={3} ====================' -f `
            $PID, [Security.Principal.WindowsIdentity]::GetCurrent().Name, $PSVersionTable.PSVersion, $script:Interactive)
        Write-Log SESSION "initial state: console user='$($script:SessUser)' lockScreen=$($script:SessLock)"

        $script:DevCache = Get-DeviceTable
        Write-ConfigDump
        Register-WmiSubscriptions
        Initialize-EventSources

        $script:LastSnap = Get-SystemSnapshot
        Write-SnapshotSummary $script:LastSnap 'baseline'
        if ($script:SessUser -and -not $script:SessLock) {
            $script:RefSnap = $script:LastSnap
            Write-Log SNAP 'healthy reference = baseline'
        } else {
            $script:RefSnap = $null
            Write-Log SNAP 'no healthy reference yet (nobody logged on or screen locked) - will be taken after logon'
        }

        $gapThreshold = [Math]::Max(30, $PollSeconds * 10)
        $nextPeriodic = (Get-Date).AddMinutes($PeriodicSnapshotMinutes)
        $lastTick = Get-Date

        while ($true) {
            $now = Get-Date
            $gap = ($now - $lastTick).TotalSeconds
            if ($gap -gt $gapThreshold) {
                Write-Log POWER ('monitoring loop was frozen for {0:N0}s ({1:HH:mm:ss} -> {2:HH:mm:ss}) - system was most likely asleep / hibernated' -f $gap, $lastTick, $now)
                Start-Series 'RESUME' 'loop time gap'
            }

            Receive-WmiEvents
            Read-EventSources
            Update-SessionState
            if ($script:DevDirtyAt -and ((Get-Date) - $script:DevDirtyAt).TotalSeconds -ge 1.5) { Update-DeviceCache }
            Invoke-PendingSnapshots

            if ((Get-Date) -ge $nextPeriodic) {
                if ($script:Pending.Count -eq 0) { Invoke-PeriodicSnapshot }
                $nextPeriodic = (Get-Date).AddMinutes($PeriodicSnapshotMinutes)
            }
            if ((Get-Date).Date -ne $script:LastCleanup) { Remove-OldLogs; $script:LastCleanup = (Get-Date).Date }

            $lastTick = Get-Date
            Wait-Event -Timeout $PollSeconds | Out-Null
        }
    } finally {
        Get-EventSubscriber -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -like 'DM_*' } | Unregister-Event -ErrorAction SilentlyContinue
        Write-Log INFO 'DockMonitor stopped.'
        try { $mutex.ReleaseMutex() } catch {}
    }
}

function Install-Monitor {
    New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
    $dest = Join-Path $LogRoot 'DockMonitor.ps1'
    if ($PSCommandPath -ne $dest) { Copy-Item -Path $PSCommandPath -Destination $dest -Force }

    if ($EnableDiagnosticLogs) {
        & wevtutil.exe sl 'Microsoft-Windows-DriverFrameworks-UserMode/Operational' /e:true
        & auditpol.exe /set /subcategory:'{0CCE9248-69AE-11D9-BED3-505054503030}' /success:enable | Out-Null   # Plug and Play Events
        & auditpol.exe /set /subcategory:'{0CCE921C-69AE-11D9-BED3-505054503030}' /success:enable | Out-Null   # Other Logon/Logoff Events (lock/unlock)
        Write-Host 'Diagnostic logs / audit subcategories enabled (company GPO may revert the audit settings).'
    }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest`" -Run -LogRoot `"$LogRoot`" -PollSeconds $PollSeconds -PeriodicSnapshotMinutes $PeriodicSnapshotMinutes -RetentionDays $RetentionDays"
    $action    = New-ScheduledTaskAction -Execute $psExe -Argument $arguments
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
                    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description 'Dell WD19TBS dock sleep/resume/logon diagnostic logger' -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 3
    $info = Get-ScheduledTask -TaskName $TaskName
    Write-Host "Scheduled task '$TaskName' registered and started (state: $($info.State))."
    Write-Host "Logs: $LogRoot\DockMonitor_<date>.log"
}

function Uninstall-Monitor {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Scheduled task '$TaskName' removed."
    }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'DockMonitor\.ps1' -and $_.CommandLine -match '-Run' } |
        ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null; Write-Host "Stopped monitor process $($_.ProcessId)." }
    Write-Host "Logs kept in $LogRoot"
}

function Invoke-CollectReports {
    $out = Join-Path $LogRoot ('Reports_{0}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $out -Force | Out-Null
    Write-Host "Collecting reports into $out ..."

    powercfg.exe /a                               > (Join-Path $out 'powercfg_a.txt') 2>&1
    powercfg.exe /lastwake                        > (Join-Path $out 'powercfg_lastwake.txt') 2>&1
    powercfg.exe /requests                        > (Join-Path $out 'powercfg_requests.txt') 2>&1
    powercfg.exe /devicequery wake_armed          > (Join-Path $out 'powercfg_wake_armed.txt') 2>&1
    powercfg.exe /qh SCHEME_CURRENT               > (Join-Path $out 'powercfg_current_scheme.txt') 2>&1
    powercfg.exe /sleepstudy /output (Join-Path $out 'sleepstudy.html') /duration $ReportDays 2>&1 | Out-Null
    powercfg.exe /systemsleepdiagnostics /output (Join-Path $out 'systemsleepdiagnostics.html') 2>&1 | Out-Null
    pnputil.exe /enum-devices /problem            > (Join-Path $out 'pnputil_problem_devices.txt') 2>&1
    gpresult.exe /scope computer /h (Join-Path $out 'gpresult_computer.html') /f 2>&1 | Out-Null

    Get-PnpDevice -ErrorAction SilentlyContinue | Select-Object Status, Class, FriendlyName, InstanceId, Present, Problem |
        Export-Csv (Join-Path $out 'pnp_devices.csv') -NoTypeInformation
    Get-CimInstance Win32_Service | Select-Object Name, DisplayName, State, StartMode, PathName |
        Export-Csv (Join-Path $out 'services.csv') -NoTypeInformation

    $ms = [int64]$ReportDays * 86400000
    $logs = @('System', 'Application', 'Security',
        'Microsoft-Windows-Kernel-PnP/Configuration', 'Microsoft-Windows-Kernel-PnP/Device Management',
        'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational', 'Microsoft-Windows-Winlogon/Operational',
        'Microsoft-Windows-GroupPolicy/Operational', 'Microsoft-Windows-DriverFrameworks-UserMode/Operational',
        'Microsoft-Windows-DeviceSetupManager/Admin')
    foreach ($l in $logs) {
        if (-not (Get-WinEvent -ListLog $l -ErrorAction SilentlyContinue)) { continue }
        $file = Join-Path $out (($l -replace '[\\/:*?"<>| ]', '_') + '.evtx')
        & wevtutil.exe epl $l $file "/q:*[System[TimeCreated[timediff(@SystemTime) <= $ms]]]" 2>&1 | Out-Null
    }

    Get-ChildItem -Path $LogRoot -Filter 'DockMonitor_*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-$ReportDays) } |
        Copy-Item -Destination $out -ErrorAction SilentlyContinue

    $zip = "$out.zip"
    Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip -Force
    Write-Host "Done: $zip"
}

#endregion

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Error 'DockMonitor must run elevated (Administrator or SYSTEM).'; exit 1 }

$script:Interactive = [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost'

switch ($PSCmdlet.ParameterSetName) {
    'Install'   { Install-Monitor }
    'Uninstall' { Uninstall-Monitor }
    'Reports'   { Invoke-CollectReports }
    default     { Start-Monitor }
}
