# DockMonitor – diagnostic Dell WD19TBS după sleep / resume / logon

Script PowerShell care loghează tot ce se întâmplă în sistem în legătură cu dock-ul Dell WD19TBS (Thunderbolt). Urmărește intrarea în sleep, revenirea din sleep, blocarea ecranului, deblocarea și logon-ul. Scopul e să afli de ce perifericele de pe dock nu funcționează după sleep pe imaginea Windows a companiei, deși pe un Windows vanilla funcționează. Simptomul: perifericele revin abia după ce userul se loghează.

- **Script:** `DockMonitor.ps1`
- **Compatibil:** Windows PowerShell 5.1 (Windows 10/11), nu e nevoie de PowerShell 7
- **Rulează:** ca Administrator sau ca SYSTEM (prin scheduled task)
- **Loguri:** `C:\ProgramData\DockMonitor\DockMonitor_YYYY-MM-DD.log` (câte un fișier pe zi, păstrate 14 zile)

---

## 1. Utilizare

Toate comenzile se rulează din **PowerShell ca Administrator**, din folderul scriptului.

### Instalare (recomandat)

```powershell
.\DockMonitor.ps1 -Install
```

- Copiază scriptul în `C:\ProgramData\DockMonitor\`.
- Creează scheduled task-ul **`DockMonitor`**, care rulează ca **SYSTEM**:
  - pornește la boot;
  - rulează pe baterie, fără limită de timp;
  - dacă se oprește, repornește automat (de până la 10 ori, la 1 minut).
- Pornește monitorizarea imediat.

Pentru că rulează ca SYSTEM de la boot, prinde **și ce se întâmplă pe ecranul de lock și în timpul logon-ului**, nu doar după ce userul e logat.

### Instalare cu loguri de diagnostic suplimentare

```powershell
.\DockMonitor.ps1 -Install -EnableDiagnosticLogs
```

Pe lângă instalarea normală:
- activează log-ul `Microsoft-Windows-DriverFrameworks-UserMode/Operational` (încărcarea și pornirea driverelor USB/HID în user mode);
- activează auditul **Plug and Play Events**, care generează în Security log evenimentele 6416 (device nou) și 6423/6424 (device blocat de policy);
- activează auditul **Other Logon/Logoff Events**, care generează evenimentele 4800/4801 (lock/unlock).

> GPO-ul firmei poate suprascrie setările de audit la următorul refresh de policy.

### Rulare manuală (test, fără instalare)

```powershell
.\DockMonitor.ps1 -Run
```

Rulează în consola curentă și afișează liniile și pe ecran. Se oprește cu **Ctrl+C**. Poate rula o singură instanță odată, așa că dacă task-ul e instalat și pornit, fă întâi `-Uninstall`.

### Colectare rapoarte (de trimis la IT)

```powershell
.\DockMonitor.ps1 -CollectReports            # ultimele 3 zile
.\DockMonitor.ps1 -CollectReports -ReportDays 7
```

Creează `C:\ProgramData\DockMonitor\Reports_<data>.zip` cu:

| Fișier | Conținut |
|---|---|
| `sleepstudy.html` | `powercfg /sleepstudy` – sesiunile de sleep / modern standby și ce a consumat |
| `systemsleepdiagnostics.html` | `powercfg /systemsleepdiagnostics` – tranzițiile de sleep, cu detalii |
| `powercfg_*.txt` | stările de sleep suportate (`/a`), ultimul wake, power requests, device-urile care pot trezi sistemul, schema curentă |
| `pnputil_problem_devices.txt` | device-urile cu probleme |
| `pnp_devices.csv` | toate device-urile (inclusiv cele care nu mai sunt prezente) |
| `services.csv` | toate serviciile, cu stare și tip de pornire |
| `gpresult_computer.html` | politicile GPO aplicate pe computer |
| `*.evtx` | exporturi de event log-uri: System, Application, Security, Kernel-PnP, LocalSessionManager, Winlogon, GroupPolicy, DriverFrameworks, DeviceSetupManager |
| `DockMonitor_*.log` | logurile scriptului din perioada aleasă |

### Dezinstalare

```powershell
.\DockMonitor.ps1 -Uninstall
```

Șterge scheduled task-ul și oprește procesul. **Logurile rămân** în `C:\ProgramData\DockMonitor`.

### Parametri opționali

| Parametru | Implicit | Descriere |
|---|---|---|
| `-LogRoot` | `C:\ProgramData\DockMonitor` | folderul pentru loguri |
| `-PollSeconds` | `2` | intervalul buclei principale (event log-uri, sesiune) |
| `-PeriodicSnapshotMinutes` | `5` | la câte minute se face un snapshot periodic |
| `-LookbackMinutes` | `10` | câte minute de istoric din event log-uri citește la pornire |
| `-RetentionDays` | `14` | după câte zile se șterg logurile vechi |
| `-ReportDays` | `3` | câte zile de evenimente include `-CollectReports` |

---

## 2. Ce monitorizează

### Surse în timp real

| Sursă | Ce prinde |
|---|---|
| WMI `Win32_PowerManagementEvent` | intrarea în sleep (4), resume (7), wake automat (18), schimbarea AC/baterie (10) |
| WMI `Win32_DeviceChangeEvent` | orice apariție sau dispariție de device. La fiecare eveniment, scriptul compară lista completă de device-uri cu cea de dinainte |
| WMI `Win32_Service` (modificare) | **orice serviciu care își schimbă starea** (Running → Stopped etc.), cu tipul de pornire și PID-ul |
| WMI `Win32_ProcessStartTrace` / `StopTrace` | procesele care pornesc sau se opresc |
| Detectarea „pauzelor” din buclă | dacă bucla a stat înghețată peste 30 s, sistemul a fost în sleep. E o detecție de rezervă, pentru cazul în care evenimentul WMI nu vine |
| Starea sesiunii (la fiecare 2 s) | userul logat la consolă și dacă e afișat ecranul de lock (`LogonUI.exe`) |

### Event log-uri citite

| Log | Filtru |
|---|---|
| System | Kernel-Power, Power-Troubleshooter, Kernel-PnP, Service Control Manager (fără 7036, care e deja acoperit de WMI), Winlogon, UserModePowerService, USBHUB3/USBXHCI/UCSI, Display, NDIS, DHCP, plus **orice warning sau eroare** (fără DCOM 10016) |
| Application | erori și evenimente critice, Winlogon, User Profile, Group Policy, warning-uri de la Dell / Intel / Thunderbolt / Realtek / DisplayLink |
| Security | 4624/4634 (logon/logoff interactiv), 4647, 4800–4803 (lock/unlock, screensaver), 6416 și 6419–6424 (device nou sau **blocat de policy**) |
| Kernel-PnP/Configuration, Kernel-PnP/Device Management | instalarea și pornirea device-urilor, cu erori |
| DeviceSetupManager/Admin | instalarea driverelor |
| TerminalServices-LocalSessionManager/Operational | logon (21), logoff (23), disconnect (24), reconnect (25) |
| Winlogon/Operational | notificările Winlogon (inclusiv subscriberii terți) |
| User Profile Service/Operational | încărcarea profilului |
| GroupPolicy/Operational | începutul și sfârșitul procesării GPO, extensiile (CSE) rulate, erori |
| DeviceManagement-Enterprise-Diagnostics-Provider/Admin | erorile și warning-urile Intune/MDM |
| DriverFrameworks-UserMode/Operational | doar dacă e activat (vezi `-EnableDiagnosticLogs`) |
| Loguri de vendor | orice log al cărui nume conține Thunderbolt / USB4 / Dell / DisplayLink |

### Seriile de snapshot-uri

Un snapshot conține toate device-urile (cu status și cod de eroare), toate serviciile, procesele, adaptoarele de rețea, monitoarele și starea sesiunii.

| Declanșator | Snapshot-uri la |
|---|---|
| **RESUME** (WMI, Kernel-Power 107/507, Power-Troubleshooter 1 sau pauza din buclă) | +0, +5, +15, +30, +60, +120, +300 s |
| **LOGON** (dispare ecranul de lock, apare userul, Security 4624/4801, LSM 21/25, Winlogon 7001) | +0, +5, +15, +30, +60, +120, +300 s |
| **LOCK** (apare `LogonUI.exe`) | +0, +10, +30 s |
| **SUSPEND** (WMI tip 4) | imediat |
| Periodic | la fiecare 5 minute |

Fiecare snapshot dintr-o serie e comparat cu:
1. **snapshot-ul anterior**, ca să vezi ce s-a schimbat de la ultimul pas;
2. **referința „healthy”**, adică ultima stare bună: user logat, ecran deblocat, fără resume sau logon în desfășurare. Referința se actualizează la snapshot-urile periodice și la suspend.

Comparația cu referința **răspunde direct la întrebarea „ce rămâne oprit sau nefuncțional după sleep până la logon”**.

### Dump de configurație (o dată, la pornire)

- modelul laptopului, versiunea BIOS, versiunea și build-ul de Windows, ultimul boot;
- dacă **Kernel DMA Protection** e activ (citit prin `NtQuerySystemInformation`);
- `powercfg /a`, schema activă, setările USB (selective suspend, USB 3 Link Power Management, hub timeout), setările PCIe (ASPM), device-urile care pot trezi sistemul;
- registry:
  - `HKLM\SOFTWARE\Policies\Microsoft\FVE` (BitLocker)
  - `HKLM\SOFTWARE\Policies\Microsoft\Windows\Kernel DMA Protection`
  - `HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\DmaGuard`, `DataProtection`, `BitLocker`, `DeviceInstallation`, `Power`
  - `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall`
  - `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Device Control`
  - `HKLM\SOFTWARE\Policies\Microsoft\Power\PowerSettings`
  - `HKLM\SYSTEM\CurrentControlSet\Services\USB`, `USBHUB3\Parameters`
  - `HKLM\SYSTEM\CurrentControlSet\Control\Power` (CsEnabled, PlatformAoAcOverride, HibernateEnabled), HiberbootEnabled (fast startup)
- pentru fiecare device USB/HID/Net/dock: **„Allow the computer to turn off this device”** și „wake”;
- serviciile legate de dock (Thunderbolt, Dell, DisplayLink, Realtek, USB);
- lista device-urilor de pe dock.

**Avertismente automate (`WARN POLICY`)** apar dacă scriptul găsește:
- `DisableExternalDMAUnderLock = 1` (BitLocker);
- `AllowDirectMemoryAccess = 0` (MDM);
- `DeviceEnumerationPolicy` configurat (Kernel DMA Protection);
- restricții de instalare a device-urilor.

---

## 3. Cum citești logul

Format:
```
2026-10-01 09:15:02.341 [TAG    ] mesaj
```

| Tag | Semnificație |
|---|---|
| `INFO` | pornire/oprire, ce log-uri și abonamente sunt active |
| `CONFIG` | dump-ul de configurație |
| `POWER` | evenimente de power: sleep, resume, AC/baterie, pauza din buclă |
| `SUSPEND` / `RESUME` / `LOGON` / `LOCK` | începutul unei serii (linie cu `=====`) și informațiile adunate atunci |
| `SESSION` | schimbarea userului de la consolă, apariția și dispariția ecranului de lock |
| `SVC` | un serviciu și-a schimbat starea (în timp real) |
| `PROC` | `START` sau `STOP` de proces (cu procesul părinte și codul de ieșire) |
| `PNP` | `[+DEV]` device apărut, `[-DEV]` device dispărut, `[~DEV]` status sau eroare schimbate (în timp real) |
| `EVT` | eveniment din event log: `ora | log | provider | id | nivel | mesaj` |
| `SNAP` | rezumatul unui snapshot |
| `DIFF` | diferențe între snapshot-uri (`[+/-/~DEV]`, `[+/-/~SVC]`, `[~NET]`, `[+/-/~MON]`, `[+/-PROC]`, `[~SESSION]`) |
| `WARN` | probleme detectate (politici, erori de abonare) |

Device-urile marcate cu **`<DOCK>`** sunt cele care par de pe dock: nume Dell / WD19 / Thunderbolt / USB4 / Realtek USB / hub-uri USB / Type-C / UCSI, sau ID-uri `VID_413C` (Dell), `VID_0BDA` (Realtek), `VID_8087` (Intel TBT), `VID_2109` (VIA hub).

### Exemplu de linie SNAP

```
[SNAP   ] [RESUME +15s] user='DOMAIN\user' lockScreen=True | dockDevices=4 (errors=1) | keyboards=1 mice=1 audioEndpoints=1 | monitors active=1/3 | problemDevices=1 | autoServicesNotRunning=6
[SNAP   ] [RESUME +15s]   problem device: Realtek USB GbE Family Controller [Net] status=Error err=43 (stopped, reported problems) <DOCK> | USB\VID_0BDA&PID_8153\...
```

### Ce cauți în log

1. **`WARN POLICY`** de la pornire. Dacă apare, ai probabil cauza (vezi secțiunea 4).
2. Secvența **`SUSPEND` → `RESUME` → `LOCK` → `LOGON`** și momentul exact în care apar `[+DEV] ... <DOCK>`:
   - dacă device-urile de pe dock **apar abia la `LOGON +0s/+5s`** și nu la `RESUME`, Windows le ține blocate până la unlock, deci e o politică;
   - dacă apar la `RESUME`, dar cu `err=` (43, 10, 31...), e o problemă de driver sau de power management.
3. Liniile **`DIFF [... vs HEALTHY reference]`** din seria RESUME: arată ce lipsește sau ce servicii sunt oprite față de starea bună.
4. **`SVC`** și **`PROC`** între resume și logon: servicii oprite sau pornite de agenți ai firmei (security, Intune, VPN, scripturi GPO).
5. **`EVT`** cu Security **6423/6424** (device blocat de policy), Kernel-PnP 400/410/411/420/430 sau erori USBHUB3/USBXHCI.

---

## 4. Ipoteza principală

Simptomul („perifericele merg doar după ce userul se loghează” + „doar pe imaginea de firmă”) se potrivește cu **protecția împotriva atacurilor DMA pe Thunderbolt**. WD19TBS e conectat prin Thunderbolt, deci tot ce e în dock (USB, rețea, audio) e văzut de Windows ca un dispozitiv extern cu acces DMA.

| Politică | Unde | Efect |
|---|---|---|
| **BitLocker: „Disable new DMA devices when this computer is locked”** | GPO: Computer Configuration → Administrative Templates → Windows Components → BitLocker Drive Encryption. Registry: `HKLM\SOFTWARE\Policies\Microsoft\FVE\DisableExternalDMAUnderLock = 1` | Cât timp ecranul e blocat, device-urile Thunderbolt/DMA nu sunt pornite. Pornesc **abia după unlock sau logon**. Face parte din **Microsoft Security Baseline**, deci e foarte des întâlnită pe imaginile de firmă. |
| **MDM DataProtection/AllowDirectMemoryAccess = 0** | Intune | Același efect, configurat prin MDM. |
| **Kernel DMA Protection – DeviceEnumerationPolicy** | GPO: System → Kernel DMA Protection. Intune: DmaGuard | 0 = blochează tot, 1 = doar după logon/unlock (implicit), 2 = permite tot. Afectează device-urile cu drivere care nu suportă DMA remapping. |
| **Device Installation Restrictions / Defender Device Control** | GPO / Intune | Pot bloca device-uri după ID sau clasă (vezi Security 6423/6424). |

Dacă scriptul confirmă una dintre politici, **soluția e o excepție sau o modificare de politică discutată cu echipa de Security/Intune**, nu o problemă de dock, de firmware sau de driver. Exemple: dezactivarea `DisableExternalDMAUnderLock` pe un grup de laptopuri, sau acceptarea comportamentului.

### Alte cauze posibile (dacă nu e o politică)

- **USB selective suspend** sau „Allow the computer to turn off this device” activ pe hub-urile sau NIC-ul dock-ului (vezi `CONFIG device power mgmt` și `powercfg USB settings`);
- **Modern Standby (S0)** față de S3: pe imaginea de firmă poate fi forțat altul (`powercfg /a`, `PlatformAoAcOverride`);
- drivere Thunderbolt, Realtek USB sau audio diferite față de laptopul vanilla (compară liniile `dock-related device` și `dock-related service`);
- agenți ai firmei (EDR, VPN, device control) care opresc sau pornesc servicii la resume (vezi `SVC` / `PROC`);
- un script GPO sau Intune de la logon care „repară” ceva (vezi `PROC START` cu `gpscript`, `powershell`, `AgentExecutor`).

---

## 5. Pași recomandați

1. `.\DockMonitor.ps1 -Install` (eventual cu `-EnableDiagnosticLogs`).
2. Verifică imediat în logul zilei liniile `CONFIG` și `WARN POLICY`.
3. Reprodu problema de 1–2 ori: laptopul în dock → sleep (sau închizi capacul) → aștepți câteva minute → trezești laptopul → **aștepți 30–60 s pe ecranul de lock fără să te loghezi** → te loghezi.
4. Notează orele aproximative, ca să găsești ușor secțiunile `RESUME` și `LOGON` în log.
5. `.\DockMonitor.ps1 -CollectReports` și trimiți zip-ul sau logul pentru analiză.
6. Când ai terminat: `.\DockMonitor.ps1 -Uninstall`.

---

## 6. Limitări și observații

- Trebuie rulat **elevat**. Fără drepturi de admin, Security și unele log-uri nu pot fi citite.
- Pe laptopurile de firmă, **execution policy impus prin GPO (AllSigned), AppLocker / WDAC sau Constrained Language Mode** pot bloca scriptul. `-ExecutionPolicy Bypass` din task nu trece peste politicile setate prin GPO. Ai nevoie de acordul sau ajutorul IT.
- Verificarea Kernel DMA Protection e best effort. Dacă afișează `unknown`, uită-te în `msinfo32` → „Kernel DMA Protection”.
- Lock/unlock e detectat prin `LogonUI.exe`, deci funcționează și fără auditul 4800/4801.
- Consumul de resurse e mic: o buclă la 2 s, un snapshot complet (~2 s) doar în timpul seriilor și o dată la 5 minute, iar WMI verifică serviciile la 2 s.
- La Modern Standby procesele SYSTEM pot rula în continuare, așa că detecția prin pauza din buclă poate să nu se declanșeze. Resume-ul e prins oricum din Kernel-Power 506/507 și din WMI.
- Testat: parsarea în PowerShell 5.1, snapshot-urile, citirea event log-urilor, query-urile WMI și verificarea DMA, pe Windows 11, fără admin. **Netestat:** `-Install` și un ciclu real de sleep/resume pe laptopul cu problema.
