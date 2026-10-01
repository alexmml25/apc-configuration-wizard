# APC Configuration Wizard - Project Log

A running record of where the wizard stands, the decisions behind it, and what changed when.
Add a dated entry to the **Log** whenever something is changed or tested, and update **Status** and
**Open items** to match. Newest entries go at the top.

- **What it is:** a PowerShell/WPF wizard that automates *D01555607 APC System Configuration* on an
  APC VM (13 steps) and fills the *D01555624 Configuration Verification Checklist*.
- **Repo:** `alexmml25/apc-configuration-wizard`. Current work is on branch `config-files-rework`, not yet merged to `main`.
- **Test plan:** [`docs/VM-Test-Checklist.md`](VM-Test-Checklist.md)

---

## Status (2026-09-30)

| Area | State |
|---|---|
| Steps 1-13 | All written. Steps 3, 8, 9 and 10 rebuilt against the real config files (Sept 2026). |
| Automated tests | 205 Pester tests, all passing on macOS (PowerShell 7). Not yet run on the VM (Windows PowerShell 5.1). |
| Test mode (sandbox) | VM re-run 2026-09-30 after the fixes: Steps 1, 3, 8, 9 and 10 complete with no FAIL. The only warnings are driver `.dll` files not found and instrument shares not reachable from the test VM. |
| Real run on a VM | First real run on the test VM 2026-09-30 (Reviewed steps only): Steps 1, 3, 8, 9 and 10 wrote the real files, and CNCnetPDM created the `.dll` files. The device connection check needs follow-up (see Open items). |
| deviceWise (Steps 4-7, 12 export) | **Cannot work as written.** The gateway has no HTTP/REST API; the modules call endpoints that don't exist. Proposed: guided manual steps (see Open items). |
| Remote run | Not supported. Every step assumes it runs on the target VM (localhost DB/deviceWise, `C:\` paths, HKLM, local services). Run it on the VM itself, e.g. over RDP. |
| UI | **Step-by-step wizard applied** (2026-09-30): configuration type first, Back/Next, step list on the left, draft-only Verification page. Types available: Initial System Configuration, System Component Configuration, Configuration Update, Verification. Restore and System Update / Import show "Not available yet". Not yet run on the VM. Prototype: https://claude.ai/artifact/TbK5BLeegzRbyjcGmPy7F4 |
| Sites | **MCR and MPR only** (MFW and MWR dropped 2026-09-30). MPR (Humacao) has instrument defaults; MCR uses generic defaults. |

---

## Decisions

Rules the wizard follows, confirmed with the APC engineer. The file where each rule lives is in brackets.

### General
- **CNC n = DOC instance n.** Only machines assigned to a DOC instance are configured, as CNC1-CNC3.
  This applies in Steps 3, 7, 8, 9 and 13. *(modules/Common.ps1 `Get-AssignedCNCs`)*
- **Machine name** everywhere (CNCnetPDM, deviceWise mapping, DOC `DBId`) is the Site DB `f_cnc_asset`
  exactly as stored, e.g. `Citizen 01`. Spaces are fine, and no `Site_Model_n` naming is needed.
- **Site DB:** a production Site DB holds only its own site's machines, so there is no site filter on the query.

### SINC (Step 3)
- The folders are `C:\Program Files\deviceWISE\Gateway\staging\SINC\CNC{n}\Processing|DoneSuccess|DoneError`,
  one set per DOC instance (9 folders for 3 CNCs), as in the SOP. They are no longer named after machines.

### CNCnetPDM (Step 8)
- **Device Nr** = family digit + machine number as 3 digits. CNCnetPDM accepts only 4 digits. *(manifest `CNCnetPDM.DeviceNrRules`)*

  | Digit | Family | Example |
  |---|---|---|
  | 1 | CITIZEN_L20X_IV | Citizen 01 → 1001 |
  | 2 | CITIZEN_L20E_IV | Citizen 68 → 2068 |
  | 3 | CITIZEN_M32_IV | Citizen 28 → 3028 |
  | 4 | CITIZEN_L20E_V | Citizen 100 → 4100 |
  | 5 | CITIZEN_M32_V | Citizen 83 → 5083 |
  | 6 | CITIZEN_L12 | L12 machine 5 → 6005 |

  - The machine number is the trailing number of the machine name, 1-999.
  - A missing number, a number above 999, or an unknown family stops Step 8 before any file changes.
  - Device Nr only has to be unique among the 3 CNCs on one VM. The rule is standardised in case instances are merged later.
- **Machine names:** at most **15 characters** (manifest `MaxMachineNameLength`). CNCnetPDM stores only the first 15. `log_admin` showed `200/4010/1;Citizen L320EA` for `Citizen L320EA 10`, while `Humacao_L20X_13` (15) is kept whole. A cut name no longer matches deviceWise / DOC and can collide with another machine, so Step 1 warns and Step 8 stops.
  - This replaces the earlier `10`/`11` + 2-digit rule. Existing `11xx` numbers change; accepted.
- **DLL** in the `[RS232]` line is always the Site DB `f_dllname`. There is no default.
- **Driver files:**
  - Only the per-device `.ini` is renamed: `<dll>_CNC{n}.ini` → `<dll>_<DeviceNr>.ini`. Its contents are never changed.
  - CNCnetPDM **creates** `<dll>_<DeviceNr>.dll` itself when the service starts.
  - Step 8 restarts the service and checks each `.dll` was created, waiting up to `DriverDllWaitSeconds`, 30 s.
- **Connection check after the restart:**
  - Step 8 reads each device's own log, `log_<DeviceNr>_<yyMMdd>.txt`, in the `[Protokoll] PFAD` folder. It reads only lines written after the restart, for up to `ConnectWaitSeconds` (60 s).
  - The latest `Success … controller` line counts as connected (PASS).
  - The latest `Not connected` / `initialization failed` / `Error(s) reported` line, or no result at all, is a WARN. The WARN includes that log line and whether `IP:683` answers.
  - In test mode there is no restart, so no `.dll` is created.
- **License:** `[GENERAL] License = ...`. The wizard uses the default perpetual key from the manifest,
  unless "Use default perpetual license" is unticked and another key is entered. *(manifest `CNCnetPDM.DefaultLicense`)*
- **`[RS232]` line format:**
  `n = DeviceNr;19200;8;N;1;Machine;IP;683;0;localhost;n;0;none;none;0;<dll>`.
  PLC Addr is `0`, which matches the real files; the SOP says `none`.
- **melcfg.ini:** one `[MachineNN]` section per CNC with `Device=TCPn`, and `TCPn = IP,683` under `[HOSTS]`.

### DOC (Step 9)
- **File locations** as found on the APC VM:
  - `C:\Medtronic\DOC-{n}\DOC_II\`: DocDb.xml, DOC_II.xml
  - `...\DOC_II\Plugins\`: **PartLookup.xml**. The SOP says `DOC_II\`; the VM wins.
  - `...\DOC_II\Plugins\IQS\`: SpcDb.xml, IqsDocSpcDataCollector.xml
- **`CSVFileOutputPath`** = `...\staging\SINC\CNC{n}\{AF}-{AN}-{BN}-{PF}-{PN}-{PSN} {DS} {TS}.csv`, using the SOP pattern.
- **Iqs asset:**
  - `DBId` = machine name.
  - `Name` = `Primary [machine]`.
  - `Family` = the Site DB asset family, e.g. `CITIZEN_L20X_IV`, not "Citizen L20X".
- **`SourceDataInclusionList`:** `1ST_/SPC_/VER_<NAME>_<SITE> : <NAME>` for each instrument ticked for that CNC.
  NAME is CMM1, CTSCAN1, BENCH, or CONTRACER1-3.
- **Connection strings** (DocDb, SpcDb, PartLookup) are verified only, never changed, as the SOP says.
- **`PartLookup LoadMatrixRevision`** = `MAX`.

### Data applications (Step 10)
- **Config locations:**
  - `C:\Medtronic\File Manager\DataCollector_FileManager.exe.config`
  - `C:\Medtronic\Data Collector\DataCollector.exe.config`
  - `C:\Medtronic\Data Analyzer\DataAnalyzer.exe.config`
- **Instrument selection:** the engineer ticks which instruments each CNC uses in the wizard, and enters Qty, Source, Error and Broadcast paths.
  MPR defaults come from the Humacao example.
- **Block copying:** blocks are copied from the *installed* configs only. There are no fallback template files in the repo.
- **File Manager:**
  - one `CNCn.Asset` block per CNC, with `CheckMismatchData=true`.
  - one `<PathN>` per instrument, with `EndFileString=NA`.
- **Data Collector:**
  - `CheckPath` = the File Manager `NewPath`, always, so the two stay aligned.
  - `ArchivePath` = `CheckPath\Backup`.
  - `BroadcastFilePaths\Path1` = the broadcast path or `NA`, with `BroadcastFile=true` only when a path is set.
- **Data Analyzer:**
  - the site code in the `Opc_*Process` patterns.
  - `Opc_CNCAssets`, `Opc_DOCCHMIs` and `Opc_DataAnalyzers` sized to the CNC count.
- **800xA (2026-09-30, from `kits/800xA/HANDOFF.md`):**
  - The proven kit (`Backup-800xA.ps1`, `GPWrite3.vbs`, `Invoke-800xAGP.ps1`, `GPExplore.vbs`) ships **unchanged** in `kits/800xA`.
  - Git never converts its line endings (`.gitattributes`), and the wizard checks it against `SHA256SUMS.txt` before every use.
  - Everything runs 32-bit through the SysWOW64 `powershell.exe` / `cscript.exe` (manifest `ABB800xA`) and is gated on exit codes.
  - **Step 11** writes `ABB800xA.Properties` first: read, skip if already set, write, read back.
    - Before/after values go to `800xA_changes_<ts>.log`. It stops at the first failure.
    - It refuses quotes, `SourceCode`, `TriggerText` and `ActionTrig_*`. Tokens: `{COMPUTERNAME} {SITE} {CNCn} {DEVICENRn}`.
  - **Step 12** runs the 800xA Full backup first (`-Start -Confirmed`) and logs the backup name. The user decided there is no separate pre-change backup step; the backup is part of Step 12.
- **Step 12 backups (2026-09-30):**
  - Everything goes to **`C:\APC_Config\Backups\<yyyyMMdd-HHmmss>\`** (manifest `Backup.Root`), next to the wizard's Reports and Logs.
  - Contents: `800xA\<backup name>` (copied from `C:\BACKUP`, plus the kit log) and `Medtronic\`.
  - `C:\Medtronic` is copied without `CNCNetPDM\log`, `DataCollector_Data` and `Backup` (`Backup.MedtronicExcludeDirs`).
  - CNCnetPDM is copied separately only when it is installed outside `C:\Medtronic`.
  - The network backup share is no longer used.
- **App account (2026-09-30):** the applications run as the site service account `ENT\SVC-APC-<site>` (manifest `AppAccount`), one per site.
  - Step 3 grants it **Modify** on each `SINC\CNC{n}`, where DOC writes its CSVs.
  - Step 10 grants it Modify on every local folder it creates or configures. Grants use `icacls (OI)(CI)M`, so subfolders inherit them.
  - Test mode grants nothing. Step 13 checks the account has Modify on those folders.
- **Network paths as administrator:** the wizard runs elevated, and on the APC VM an elevated session cannot see into the shares the apps use (`Test-Path` is `False` as admin and `True` as `SVC-APC-MPR`). So for UNC paths the wizard only checks that the server answers on port 445, reports the folder as not verifiable from the wizard, and asks you to confirm in File Manager.
- **Folders (revised 2026-09-30):**
  - Folders on the VM's **local disks** (C:, D:) are created if missing. That includes instrument **source** and **Error** folders; for example, Humacao's `D:\…_Measurement_Reports\CSVCLC` are local folders on the APC VM.
  - Folders on a **network share** (UNC `\\server\share` or a mapped drive) are never created, only checked, with a WARN.
  - Use **UNC paths** for shares, not mapped drive letters. Mapped drives are per user, and File Manager does not see a drive mapped in the wizard's elevated session.

### Testing
- **Launching:** double-click `Start-Wizard.cmd` to run the wizard, and `Run-Tests.cmd` to run the tests. The launcher elevates, unblocks the scripts and keeps its window open after an error.
- **Run modes** (wizard **Run mode** selector; manifest `RunModes`):

  | Mode | What runs |
  |---|---|
  | **Reviewed steps only** (default) | A real run of `RunModes.ReviewedSteps` (1, 3, 8, 9, 10, 13). The other steps are skipped. |
  | **Full run** | All 13 steps. |
  | **Test mode** | Sandbox copies only; skips `TestMode.SkipSteps`. |

  Real runs ask for confirmation first. When a step is reviewed, add it to `ReviewedSteps`.
- **Pester tests** are in `tests/`. Run them with `.\tests\Run-Tests.ps1` or `Run-Tests.cmd`. They are safe on the VM: they use a temp folder and never touch services.
  The sample config files live in `tests/fixtures/` as test data only. The root sample files are kept out of commits.
- **Test mode:**
  - copies installed configs to `C:\APC_Config\Sandbox\<date-time>\` and edits only the copies.
  - skips Steps 2, 4-7, 11 and 12, and doesn't restart services.
  - creates no folders outside the sandbox.
- **Checklist template:** `templates/D01555624_A_EN.docx` is the checklist Step 13 fills in.

---

## Open items

- [ ] Run the Pester tests on the VM (Windows PowerShell 5.1) for the first time.
- [ ] MCR instrument defaults (source shares) are not known yet. Add them to the manifest `DataApps.SiteDefaults` when available.
- [x] ~~Verify the deviceWise REST API paths used by Steps 4-7 against the installed version.~~ Done 2026-09-30: there is no REST API (see Log).
- [ ] **Decide the deviceWise approach.** Proposed: Steps 4-7 become a guided pause like Step 11. The wizard shows a checklist with this VM's values filled in (CNCAsset/CNCType, EMAIL_TO, CNC_ASSET_Management and CNC_Settings rows, CNCnetPDM path and CNC path mapping, import file paths, License Manager host, OPC UA endpoint settings), waits for Continue, then checks what it can without the API (dwcore/dwts running, port 48020 listening, SINC folders, CNCnetPDM). The rest becomes manual sign-off items in the Step 13 report. The fake REST calls are removed. About 1 day.
- [ ] Move Step 7 (deviceWise CNCnetPDM integration) after Step 8 (CNCnetPDM), as in the SOP. Today "Connected" cannot pass on the first run.
- [x] ~~Step 12 backup reads `$Manifest.BackupShare`~~: fixed 2026-09-30, it now reads `APC.BackupShare`.
- [ ] deviceWise backup is not automated (no API). Step 12 now shows a WARN reminder to back up in Workbench.
- [ ] Ask Telit support (support-devicewise@telit.com) whether Gateway 23.04 has a supported way to script configuration (CLI, full-config import, local API).
- [ ] **Step 11 (CHMI): fill in `ABB800xA.Properties`** in the manifest with the real General Properties. Find each ItemID with `kits\800xA\GPExplore.vbs`; Access must be `RW`. The write mechanism is in place, but the list is empty.
- [ ] Test Steps 11 and 12 (800xA) on a non-production node, then do one real run and review `800xA_changes_*.log` and `Backup800xA_*.log`. Bool writes are not yet verified on 800xA.
- [ ] 800xA backups are never purged (`PurgeCount = -1`): `C:\BACKUP` grows by about 110 MB per run of Step 12, and each run also copies the backup into `C:\APC_Config\Backups\<ts>`. Decide on clean-up.
- [ ] Step 11 properties: find the ItemIDs with `GPExplore.vbs`, e.g. the BENCH CSV path used by CHMI and whether Shift change verification is enabled. Then fill in `ABB800xA.Properties`.
- [ ] Check the manifest Site DB host: `SiteServers.MPR/MCR.Host` is `sjum1cappd0017`, which is also the APC VM the deviceWise scans ran on. Confirm this is intended.
- [ ] Finish Part 3 of the test checklist after the first reviewed-steps run: restart File Manager, Data Collector and Data Analyzer, check the DOC indicators, and test file routing.
- [ ] Device 1001 (Citizen 01) **is connected**: its log shows `Parts_Machined Command incorrect, deactivated / Part_Required …`, so the controller answers but rejects those two counter commands. Check the counter commands (ParameterNumber 8300/8304) in `citizenm_1001.ini` for this controller.
- [ ] **Shorten machine names longer than 15 characters in the Site DB / ACW**, e.g. `Citizen L320EA 1`–`27` (16–17 characters) → `Citizen L320 1`–`27`. CNCnetPDM keeps only 15 characters, so the wizard now stops on longer names.
- [ ] Device 4001 (L320EA 1, `_V`): `INIT Error(-2113798123)` although port 683 answers. Is the `melcfg.ini` `Controller=M7NX` (copied to every MachineNN) right for V-series machines, or does it depend on the family?
- [ ] **Try the new wizard window on the VM** (it cannot be opened on macOS): Part 2 and 3.2 of the test checklist. Check Back/Next, the step list, the Site DB load on Next, the Machines table (Device Nr / DLL), the Run page, and the draft checklist (Reason ticked, Change ID).
- [ ] **Configuration types still to build:**
  - **Configuration Restore:** list the backups for this VM on the backup share and restore the chosen components. No restore code exists; the card is disabled.
  - **System Update / Import:** backup, then import an approved package (CHMI / APC UI). No import code exists; the card is disabled.
  - **Configuration Update:** today it works like System Component Configuration (runs the picked steps with the values entered in the wizard). Reading the current values from the VM first is not built yet.
- [ ] **Confirm:** Verification ticks "Other: Verification only (no changes)" in D01555624 by default (the user can pick another reason on the Verification page).
- [ ] **To decide:** whether the Change ID is required for every type except Initial (today the wizard only shows a hint), and whether step 12 (backup) should always run for partial runs (today it does, unless the run mode skips it).
- [ ] Merge `config-files-rework` into `main` once the VM tests pass.

---

## Log

### 2026-09-30 - App icon
- `APC Configuration Manager Icon.png` (user's icon, scaled from 1254 px to 256 px) is in the header's right corner, opposite the APC logo, clipped to its circle. It is also the window and taskbar icon.

### 2026-09-30 - Step 12: one local timestamped backup folder
- **User decisions:** all backups go to a timestamped folder next to the wizard's Reports (`C:\APC_Config\Backups\<ts>`); CNCnetPDM is not copied twice, since it is under `C:\Medtronic`; deviceWise is not doable yet.
- **Step 12 rewritten:**
  - 800xA Full backup first, then copied into the backup folder together with its log.
  - `C:\Medtronic` is copied without logs, measurement data and old backups.
  - A WARN reminds to back up deviceWise manually.
  - The made-up deviceWise REST export is removed.
- **Tests:** Step 12 is tested with a fake 800xA kit and a robocopy stand-in.

### 2026-09-30 - Step-by-step wizard applied to the code
- **`APC_ConfigWizard.ps1` rewritten** to match the approved prototype. The step runner, Site DB fetch, sandbox/test mode and all step modules are unchanged.
  - **Layout:** 1000x720 window, header with the type/site chip, step list on the left (finished pages can be clicked), Back/Next footer.
  - **Pages by type:**
    - Initial: Type → Sign in & site → Machines & DOC → SINC & CNCnetPDM → Data applications → Review & run → Run → Verification.
    - Component / Update: Type → Sign in → Components → Machines & DOC → (SINC & CNCnetPDM if deviceWise or CNCnetPDM is picked) → (Data applications if picked) → Review → Run → Verification. Runs Step 1, the picked steps, 12 and 13.
    - Verification: Type → Sign in → Machines & DOC → Review → Run → Verification. Runs Steps 1 and 13 only, has no run-mode choice and no "Confirm real run" prompt. Machines & DOC is included because Step 13 needs to know which machine is CNC1-3; this page was not in the prototype.
  - **Sign in → Next** checks the domain login and loads the Site DB machines; the old "Proceed" button is gone.
  - **Machines & DOC** shows each machine's family, Device Nr and DLL (red "Error" with the reason when Step 8 would stop).
  - **Component passwords** are only required when Step 2 (apcuser) or Step 4 (MedtronicSU) will actually run.
  - **Review & run:** summary, run mode (Reviewed / Full / Test), the steps that will run (skipped ones struck through), and "Start from step" under Advanced.
  - **Run:** only the type's steps are listed; the progress bar counts the steps that run; the log is behind "Show log". Re-run buttons now reuse the run's state (they used a state without the machines before).
  - **Verification page:** results counts from Step 13, reason choice (Verification type only), Change ID, "Generate draft checklist" (runs Step 13 again with the Change ID and reason) and "Open draft" (the .docx).
- **Fixed on the way:** the old Post-Configuration buttons called `Invoke-ConfigVerification` and `Invoke-GenerateReport`, which do not exist. Reviewer name/role/decision are removed.
- **Step 13 (`modules/13-Verification.ps1`):**
  - D01555624 row "Reason for Configuration": ticks the box for `State.ConfigReason` (0-5; 5 = Other, with `ConfigReasonOther` written after "Other:").
  - Row "Related Change Management Record": writes `Change ID: <State.ChangeID>`.
  - HTML report is titled "(draft)" and its signature lines are replaced by a note that review and QA sign the checklist independently.
- **Tests:** new window tests (page panels, type cards, component boxes, step rows, ASCII-only source) and D01555624 tests (each reason, Other text, Change ID, nothing ticked when not given). Full suite passing on macOS.

### 2026-09-30 - 800xA property writes (Step 11) and Full backup (Step 12)
- Built from the handoff package `ClaudeCode-800xA-Handoff.zip` (HANDOFF.md). The kit is copied unchanged to `kits/800xA` and its hashes match `SHA256SUMS.txt`.
- **Step 12:** the made-up `ABB.AfwAsynchBackup` COM backup is replaced by `Backup-800xA.ps1 -Start -Confirmed` in 32-bit PowerShell. It runs first in the step and records the exit code, backup name and folder (`State.Backup800xA`). The `APC.BackupShare` key bug is fixed.
- **Step 11:** `Invoke-800xAPropertyStep` writes the manifest property list through `Invoke-800xAGP` (32-bit cscript), logs before/after values, and stops at the first failure. The list is empty until the real properties are known.
- **Tests:** 174 passing. They use a fake kit with the same interface, plus a checksum check of the real kit.

### 2026-09-30 - App account permissions; share checks as administrator
- **Findings:**
  - `Test-Path` on `\\sjum1bfile05\…\CSVCLC` is `False` in an administrator session and `True` in the normal `SVC-APC-MPR` session.
  - The apps run as `ENT\SVC-APC-MPR`, one account per site.
- **Share checks:** UNC paths are now checked by server reachability only, and reported as "cannot be checked as administrator – confirm in File Manager" rather than as missing. This also removes the 2-minute wait.
- **Permissions:** Steps 3 and 10 grant `ENT\SVC-APC-<site>` Modify on the folders they create or configure, except in test mode. Step 13 checks it.
- **Tests:** 151 passing.

### 2026-09-30 - CNCnetPDM cuts machine names to 15 characters
- `log_admin` stored `Citizen L320EA` for device 4010 (`Citizen L320EA 10`).
- Names longer than 15 characters are now an error in `Get-CNCDeviceInfo`: Step 1 warns and Step 8 stops before changing files (`4526a02`). The fix belongs in the Site DB / ACW.
- **Share check:** `Test-NetConnection sjum1bfile05 -Port 445` succeeds and `Test-Path` on the UNC path is `True` in a normal session. The wizard's earlier "not reachable" still needs to be tested in an administrator session.
- **Tests:** 146 passing.

### 2026-09-30 - Applications open after the real run; idle device counts as connected
- **The applications open with the wizard's config:** File Manager (all sources found, CTSCAN via the UNC path), Data Collector, Data Analyzer and DOC.
- **CNCnetControl:** 4010 (L320EA 10) and 1001 (Citizen 01) Connected, 2068 Disconnected (network).
- **Step 8:** 4010 was a false WARN; a connected idle device logs nothing. No error lines plus port 683 answering now counts as connected (PASS).
- **Tests:** 144 passing.

### 2026-09-30 - Second real run: connection check and share timeouts refined
- **Step 8, Citizen 01 (1001):** the log line `Parts_Machined Command incorrect, deactivated` was counted as not connected. That line means the controller answered, so it is now **PASS**, with a separate **WARN** listing the deactivated commands and the driver `.ini` to check. Only `Not connected`, `initialization failed` and `INIT Error` count as not connected.
- **Step 10:** the unreachable share `\\sjum1bfile05` made the step hang for about 2 minutes. UNC paths now get a quick SMB (port 445) check first (`Test-ShareServerReachable`, about 1.5 s), which warns immediately. Step 13 uses the same check for File Manager sources.
- **Step 10:** created the local `D:\CMM_…\CSVCLC` and `D:\Contracer_…\CSVCLC` source folders on the real run, as intended.
- **Tests:** 143 passing.

### 2026-09-30 - UI prototype: Verification type, draft-only checklist
- **"Other" removed** from the wizard's types and replaced by **Verification**: a read-only check (Step 1 + Step 13) with no changes to the VM, for checking an existing system or troubleshooting. Its path is Type → Sign in → Review → Run → Draft checklist. It has no run-mode choice, because nothing is changed.
- **The last page is now "Draft checklist"** instead of "Verify & report":
  - Reviewer name, role and decision are removed; review and QA are independent and don't sign in the wizard.
  - The page shows the verification results and the Reason for Configuration box that will be ticked.
  - It shows the Change ID and who ran the wizard and when, and states that signatures are left blank.
  - Buttons: Generate draft checklist and Open draft.
- **Open question:** Verification is not one of the D01555624 reasons. The prototype ticks "Other: Verification only (no changes)".
- **Follow-up the same day:** the Draft checklist page was trimmed to just the Change ID (pre-filled from the type page, editable).
  - The reason is not shown, because the type already gives it. The exception is **Verification**: there the user picks the reason, with "Other: Verification only (no changes)" as the default.
  - "Performed by" is not shown, because it comes from the sign-in. "Signatures" is removed.
- **Second follow-up:**
  - The last page is renamed from "Draft checklist" to **Verification**.
  - The Change ID is asked for **only on that last page**. It was removed from the type page and from the Review summary.

### 2026-09-30 - UI prototype: step-by-step wizard with configuration types
- **Asked for:** replace the long scrolling page with a step-by-step wizard (Back/Next), and add a configuration type choice. Today the wizard only does a full initial configuration. The user asked for the prototype only for now; no code has changed.
- **Canvas:** https://claude.ai/artifact/TbK5BLeegzRbyjcGmPy7F4 (private).
  - Page **As-is:** the current window, copied from the XAML.
  - Page **Proposed:** a clickable wizard, 1000×720, with a step list on the left and Back/Next at the bottom.
- **Configuration types** are the six "Reason for Configuration" options in the D01555624 checklist (Initial System Configuration, Configuration Restore, System Component Configuration, Configuration Update, System Update / Import, Other). The type chosen decides the pages:

  | Type | Pages |
  |---|---|
  | Initial System Configuration | Type → Sign in & site → Machines & DOC → SINC & CNCnetPDM → Data applications → Review & run → Run → Verify & report (all 13 steps) |
  | System Component Configuration, Configuration Update, Other | Type → Sign in → Components (pick) → only the pages those components need → Review → Run → Report. Runs step 1, the picked steps, 12 and 13. |
  | Configuration Restore | Type → Sign in → Backup to restore → Review → Run → Report |
  | System Update / Import | Type → Sign in → Update package → Review → Run → Report |

- **Other changes in the prototype:**
  - The type page takes a Change ID. "Other" requires a justification.
  - DOC assignment is a table showing family, Device Nr and DLL.
  - Error and broadcast paths for each instrument are behind "More paths".
  - Run mode is chosen on the Review page, which also lists the steps that will run and which are skipped.
  - The log is behind "Show log".
  - Verify & report shows the Reason for Configuration box already ticked.
- The MPR CTSCAN paths in the prototype follow the new UNC default.

### 2026-09-30 - MPR CTSCAN default is now the UNC path
- At Humacao, Z: is mapped one level deeper: `\\sjum1bfile05\CMMprograms\REPORTS`, so `Z:\CTScan_Inspection\CSVCLC` is the same folder as the UNC path. The user confirmed this.
- The MPR CTSCAN defaults are now `\\sjum1bfile05\CMMprograms\REPORTS\CTScan_Inspection\CSVCLC` and `…\CSVCLCError`. They work regardless of drive mapping.

### 2026-09-30 - File Manager test: source folders; local vs network
- **What happened:** File Manager started, but reported that the CMM and CONTRACER sources `D:\…\CSVCLC` and the CTSCAN source `Z:\CTScan_Inspection\CSVCLC` do not exist on the test VM. BENCH worked.
- **The user confirmed** the `D:` report folders are local on the APC VM. Step 10 now creates missing folders on local fixed disks, and only checks network paths (`Test-LocalFixedPath`).
- **Z:** is `\\sjum1bfile05\CMMprograms` on the test VM, and the folder there is `REPORTS\CTScan_Inspection`. Mapping a drive from the wizard is not recommended: the wizard runs elevated, so the mapping is invisible to File Manager. Use UNC paths instead.
- **Tests:** 140 passing.

### 2026-09-30 - First real run (Reviewed steps only) on the test VM
- **Machines:** CNC1 Citizen 01 (1001), CNC2 Citizen L320EA 1 (4001), CNC3 Citizen 68 (2068).
- **Step 3:** the 9 SINC folders already existed.
- **Step 8:**
  - wrote the ini, license, RS232 and melcfg entries and renamed the `.ini` files.
  - restarted the service, and **all three `.dll` files were created**.
  - connection check: 1001 had no log result (port answers), 4001 had `INIT Error` (port answers), and 2068 was `Not connected` (port does not answer, so the network).
- **Steps 9 and 10:** all PASS on the real files.
- **Side effects:** Step 10 created `D:\CMM_Measurement_Reports\CSVCLCError` and `D:\Contracer_Measurement_Reports\CSVCLCError` on this VM, because the MPR default Error paths point at D:.
- **Fixed:** Step 10 checked a source folder before creating it, so BENCH, whose source is its local folder, warned wrongly. It now creates the local folders first.

### 2026-09-30 - deviceWise investigation: no API for Steps 4-7
- **Question:** can the deviceWise steps (4-7) actually run, and can the wizard be run from another VM?
- **Remote run:** not as written. See Status. Running the wizard on the VM over RDP needs no changes.
- **Code review of Steps 4-7 and 12** (local copy of the repo) found problems independent of the API:
  - `System.Web` and `System.Net.Http` are never loaded, so the URL encoding and file uploads fail on Windows PowerShell 5.1.
  - `$token` is never set in Step 4 (strict mode error), so every tag import fails.
  - Step 7 sends one request per machine to the same `CNCX_Paths` object, so each overwrites the last.
  - Some checks record PASS without checking the response (e.g. "OPC UA endpoint started").
- **deviceWise on SJUM1CAPPD0017** (Workbench 23.04 / 23.04.08, desktop app):
  - Services: `dwcore` (`Gateway\dwcore\dwcore.exe`) and `dwts` (`Gateway\dwjava\dwts.exe`).
  - `dwcore` listens only on **4011** (127.0.0.1), **4012** (0.0.0.0, secure) and **48020** (OPC UA). From `dwcore.properties`: `listener.1=Local/127.0.0.1:4011`, `listener.2=Private/0.0.0.0:4012/SECURE`.
  - Nothing answers HTTP/HTTPS on 8080/8090/8100/8001/443. The `/api/v2/...` paths the modules use do not exist.
  - Packages installed on the gateway: CNCnetPDM, FileWatcher, Lua, OPC UA client, OPC UA server v3, Simulation, TR50.
- **Workbench jars examined** with read-only scripts, to find how Workbench talks to the gateway:
  - `Workbench\wbench\jars\dwjavaapi.jar` is the CloudLINK tunnel and M2M Portal (cloud) client. It has no gateway administration.
  - `Workbench\wbench\jars\dwtr50.jar` is the TR50 client for Telit's cloud portal (`session.*`, `thing.*`, `trigger.*`). It reaches a gateway only through the cloud, which needs a portal account and a cloud-connected gateway.
  - `Workbench\wbench\dwWorkbench.jar` (4.9 MB, 2133 classes) is Workbench itself. It is **obfuscated** (packages named `if`, `int`, `OoOO…`). Its readable strings have portal commands, status counters, UI and permission names, and trigger action names. There are **no** named commands for variables, triggers, projects, local DB, packages or users. So the 4011/4012 protocol is binary and hidden in the obfuscated code.
- **Conclusion:** rebuilding that protocol would be fragile across upgrades and would probably break the licence terms. Steps 4-7 can't be automated with what is installed. Next step: the guided mode in Open items, pending a decision.
- **New read-only tools** in `tools/`, kept in case a later deviceWise version adds an API:
  - `Discover-DeviceWiseApi.ps1`: services, ports, HTTP probes and config.
  - `Export-DwJavaApi.ps1`: classes, methods and strings of a jar.
  - `Find-DwGatewayClient.ps1`: jar and package scan.
  - All three write to `C:\APC_Config\Logs`. On the VM they are in `D:\APC_Config\tools`.

### 2026-09-30 - Run modes, one-click launcher, MFW/MWR dropped
- **Run mode selector** replaces the Test mode checkbox. The modes are Reviewed steps only (the default), Full run and Test mode. Real runs ask for confirmation.
- **`Start-Wizard.cmd`** is a one-click launcher: it elevates, unblocks the scripts and keeps its window open after an error. **`Run-Tests.cmd`** runs the tests.
- **Sites:** MFW and MWR were removed from the manifest (`Sites`, `SiteServers`, `SiteOpcProcessCodes`), the headless runner prompt and Step 13 site names.
- **Tests:** 133 passing.

### 2026-09-30 - Step 8 checks each device connects after the service restart
- **Log format** from the production Humacao VM (SJUM7AAPPS0066):
  - There is one log per device per day: `log_<DeviceNr>_<yyMMdd>.txt`.
  - Success lines read `Success writing command: <…> to controller`.
  - Failure lines read `Error(s) reported by device N: … Not connected(-2113798134)` or `Device N initialization failed: <dll>`.
  - The admin log (`200/<DeviceNr>/1;<name>`) is only written while CNCnetControl is open, so it is not used.
- **Step 8 now:**
  - notes the size of each device log before the restart.
  - polls the new lines for up to 60 s.
  - reports PASS/WARN per CNC, with the last error line and a port-683 check.
  - skips all of this in test mode.
- **Tests:** 126 passing. The service stub writes success or not-connected log lines, and test copies of CNCnetPDM.ini point PFAD at the test folder, so real logs are never read.

### 2026-09-30 - Driver files: rename .ini only, check the service creates the .dll
- The VM has `citizenm.dll`, `mitsubishim.dll` and `<dll>_CNC1-3.ini` only. The user confirmed CNCnetPDM creates `<dll>_<DeviceNr>.dll` when the service starts after the `.ini` rename.
- **Step 8:** renames only the `.ini`, and warns if it is missing. After the restart it checks each `<dll>_<DeviceNr>.dll` appears.
- **Step 13 item 6:** checks that both the `.ini` and the `.dll` exist for each CNC.
- **Tests:** 123 passing. The service stub now creates the `.dll` the way CNCnetPDM does.

### 2026-09-30 - Second VM test-mode run: clean
- Mixed families assigned: CNC1 Citizen 08 (L20X_IV), CNC2 Citizen L320EA 12 (L20E_V), CNC3 Citizen 68 (L20E_IV).
- **Results:**
  - Device Nrs were 1008, 4012 and 2068; the DLLs came from the Site DB.
  - Step 1 now numbers every machine, including Citizen 100-300 (4100-4300).
  - The sandbox copied 28 files with none missing. Steps 3, 8, 9 and 10 finished with no FAIL.
- **Warnings to follow up:**
  - There are no `citizenm_CNC{n}.dll` / `mitsubishim_CNC{n}.dll` files to rename, but the matching `.ini` files exist and were renamed.
  - The instrument shares (D:, Z:) are not reachable from the test VM. This is expected.
- Step 13: the deviceWise and TSDB checks fail as expected, because those steps are skipped in test mode.

### 2026-09-30 - First VM test-mode run and fixes
- **Getting it running:** the branch was cloned to the VM (`D:\APC_Config\Wizard`). The window crashed on **Configure**.
  - Added error reporting so crashes inside window events show the real line (`2dba7a5`).
  - The cause was the older "Start from step" code: `1..0` counts down, so it marked a "Step 0". Fixed (`a27009a`).
- **Test-mode run results:**
  - Sandbox copy, skipped steps, and Step 3 (9 SINC folders) all worked.
  - Step 8 wrote correct Device Nrs, license, RS232 and melcfg entries.
  - Step 9 and Step 10 were correct except for two files not found.
- **File locations on the VM** differed from the SOP and manifest. The wizard now uses them (`bda0d16`):
  - File Manager config in `C:\Medtronic\File Manager\`.
  - PartLookup.xml in `DOC_II\Plugins\`.
- **Device Nr rule** redesigned to family digit + 3 digits, and the DLL is now taken from the Site DB (`77e10a2`).
  The old rule gave no number to Citizen 100-300 and duplicated numbers between two `_V` lines.
- **Confirmed:** the machine name stays the Site DB `f_cnc_asset`, and no site filter is needed on the Site DB query.
- **Tests:** 120 passing (macOS).

### 2026-09-26 - Tests, test mode, checklist
- Added the Pester suite, test mode, `docs/VM-Test-Checklist.md`, and test fixtures (`e283f55`).
- **Bug found by the tests:** DOC folder and file path keys clashed (`IQS`/`Iqs`; PowerShell keys ignore case). Fixed.
- Moved the D01555624 template to `templates/`. Removed the repo fallback copies for the data-app configs (`ef6e0b0`).

### 2026-09-25 / 26 - Config files rework (`c8e49df`)
- The user supplied the real default config files and Humacao (MPR) examples: data apps, CNCnetPDM/melcfg, and the DOC XMLs.
- **What was wrong:** Steps 8, 9 and 10 had been written against guessed file layouts. They reported PASS without changing the real files.
- **Rebuilt against the real files:**
  - Step 10 now produces the Humacao Data Collector file.
  - Step 8 now produces the Humacao CNCnetPDM.ini and melcfg.ini.
  - Step 9 follows the SOP and the rules above.
- **Wizard:**
  - new Data Applications card: instruments per CNC, with paths.
  - new CNCnetPDM license card: default key, or enter one.
- **Step 3** now creates `SINC\CNC{n}` folders. **Step 7** maps only DOC-assigned machines.
- **Other fixes:**
  - syntax errors that stopped Steps 1 and 2 from loading.
  - wrong function names in the headless runner `APC_Config.ps1`.
  - Step 13 checks now match the rebuilt files.

### 2026-06-08 - Initial build
- All 13 modules, the GUI wizard, the headless runner and the manifest were written (`ea8b0bf` … `4f5f424`).
- GUI fixes and features were added along the way: the two-step Setup → Configuration Options flow, DOC machine drop-downs, and "Start from step".
