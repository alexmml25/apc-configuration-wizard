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
| Automated tests | 123 Pester tests, all passing on macOS (PowerShell 7). Not yet run on the VM (Windows PowerShell 5.1). |
| Test mode (sandbox) | VM re-run 2026-09-30 after the fixes: Steps 1, 3, 8, 9 and 10 complete with no FAIL. The only warnings are driver `.dll` files not found and instrument shares not reachable from the test VM. |
| Real run on a VM | Not done yet. |
| Sites | MPR (Humacao) has instrument defaults. MCR, MFW and MWR use generic defaults. MFW and MWR have no Site DB server set. |

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
  - This replaces the earlier `10`/`11` + 2-digit rule. Existing `11xx` numbers change; accepted.
- **DLL** in the `[RS232]` line is always the Site DB `f_dllname`. There is no default.
- **Driver files:**
  - Only the per-device `.ini` is renamed: `<dll>_CNC{n}.ini` → `<dll>_<DeviceNr>.ini`. Its contents are never changed.
  - CNCnetPDM **creates** `<dll>_<DeviceNr>.dll` itself when the service starts.
  - Step 8 restarts the service and checks each `.dll` was created, waiting up to `DriverDllWaitSeconds`, 30 s.
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
- **Folders:** Step 10 creates local data folders, and any Error or Broadcast path entered. It never creates instrument source shares; it only checks them.

### Testing
- **Pester tests** are in `tests/`. Run them with `.\tests\Run-Tests.ps1`. They are safe on the VM: they use a temp folder and never touch services.
  The sample config files live in `tests/fixtures/` as test data only. The root sample files are kept out of commits.
- **Test mode** (wizard checkbox):
  - copies installed configs to `C:\APC_Config\Sandbox\<date-time>\` and edits only the copies.
  - skips Steps 2, 4-7, 11 and 12, and doesn't restart services.
  - creates no folders outside the sandbox.
- **Checklist template:** `templates/D01555624_A_EN.docx` is the checklist Step 13 fills in.

---

## Open items

- [ ] Run the Pester tests on the VM (Windows PowerShell 5.1) for the first time.
- [ ] Decide whether Step 10 should create an **Error path** that is on a share (today it creates it if the drive exists).
- [ ] MFW and MWR: Site DB host and credentials are missing in the manifest `SiteServers`.
- [ ] MCR, MFW and MWR instrument defaults (source shares) are not known yet. Add them to the manifest `DataApps.SiteDefaults` when available.
- [ ] Verify the deviceWise REST API paths used by Steps 4-7 against the installed version (`/api-docs`).
- [ ] Real run on a VM, then Part 3 of the test checklist.
- [ ] Merge `config-files-rework` into `main` once the VM tests pass.

---

## Log

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
