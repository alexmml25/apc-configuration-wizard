# VM Test Checklist - APC Configuration Wizard

Use this for the first runs of the wizard on an APC VM. Work through the parts in order:
automated tests, then a **test mode** run (changes only sandbox copies), then the real run.

Tick each box as you go. If a result differs from what is described, stop and note the step,
the log line and the file involved.

---

## Part 1 - Automated tests on the VM

These use the sample files in `tests\fixtures` and a temporary folder. They do not touch the
installed applications, services, the Site DB or deviceWise.

1. [ ] Copy the wizard folder to the VM (e.g. `C:\APC_Config\Wizard`).
2. [ ] Open PowerShell **as Administrator** in that folder and run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
   ```
   The first run installs Pester 5 for your user, which needs access to the PowerShell Gallery.
   If the VM has no internet access, copy the Pester module folder from another machine into
   `Documents\WindowsPowerShell\Modules\Pester`.
3. [ ] The summary line at the end shows `Failed: 0`.

---

## Part 2 - Test mode run (sandbox)

Test mode copies the installed config files into `C:\APC_Config\Sandbox\<date-time>\` and runs
Steps 1, 3, 8, 9, 10 and 13 against the copies. Steps 2, 4, 5, 6, 7, 11 and 12 (database,
deviceWise, CHMI, backup) are skipped, and the CNCnetPDM service is not restarted.

### 2.1 Start

1. [ ] Right-click `APC_ConfigWizard.ps1` → **Run with PowerShell** (as Administrator).
2. [ ] Fill in Setup (site, Site DB, passwords) and click **Proceed to Configuration Options**.
   The Site DB machines load.
3. [ ] **DOC Configuration:** set the DOC instance count and pick the machine for each DOC instance.
   DOC 1 = CNC1, DOC 2 = CNC2, DOC 3 = CNC3.
4. [ ] **CNCnetPDM Configuration:** leave **Use default perpetual license** ticked (or untick and paste a new key).
5. [ ] **Data Applications - Instruments:** check that the site defaults loaded. For each instrument:
   - [ ] **Qty** is correct (CONTRACER is usually 3).
   - [ ] **Used by** is ticked only for the CNCs that use it.
   - [ ] **Source path** is the instrument's shared folder.
   - [ ] **Error path** (blank = local DoneError folder) and **Broadcast (MES)** (blank = NA) are correct.
6. [ ] Tick **Test mode** and click **Configure**.

### 2.2 What you should see

- [ ] The window title ends with `[TEST MODE]`.
- [ ] The log starts with `TEST MODE - sandbox: C:\APC_Config\Sandbox\...`, the number of files copied, and any files not found.
- [ ] Steps 2, 4, 5, 6, 7, 11 and 12 show **Skipped**.
- [ ] Steps 1, 3, 8, 9 and 10 show **Complete** with no `[FAIL]` lines in the log.
- [ ] Step 13 runs. Checks for skipped parts (deviceWise, TSDB, CHMI, services) are expected to fail in test mode.

### 2.3 Check the sandbox files

Open `C:\APC_Config\Sandbox\<date-time>\` and check each folder.

**SINC** (Step 3)
- [ ] `SINC\CNC1`, `CNC2`, `CNC3` (one per DOC instance), each with `Processing`, `DoneSuccess`, `DoneError`.
- [ ] No folders named after machines.

**CNCnetPDM** (Step 8)
- [ ] `CNCnetPDM.ini` `[GENERAL]` has `License = <expected key>`.
- [ ] `[RS232]` has one line per CNC and no other active lines, e.g.
  `1 = 1001;19200;8;N;1;<machine>;<IP>;683;0;localhost;1;0;none;none;0;citizenm.dll`
  - Device Nr = family digit + machine number as 3 digits. Digits: L20X_IV `1`, L20E_IV `2`, M32_IV `3`,
    L20E_V `4`, M32_V `5`, L12 `6`. Example: CITIZEN_L20E_V "Citizen 100" → `4100`.
  - DLL = the machine's DLL name in the Site DB (`f_dllname`).
- [ ] `melcfg.ini` has `[Machine01]`… one per CNC with `Device=TCP1`…, and `[HOSTS]` has `TCP1 = <IP>,683`….
- [ ] Driver ini files renamed: `citizenm_CNC1.ini` → `citizenm_<DeviceNr>.ini` (same for `mitsubishim_`).
  The per-device `.dll` is created by CNCnetPDM when the service starts. It is not created in test mode.

**DOC-n\DOC_II** (Step 9)
- [ ] `DOC_II.xml` `CSVFileOutputPath` =
  `C:\Program Files\deviceWISE\Gateway\staging\SINC\CNC<n>\{AF}-{AN}-{BN}-{PF}-{PN}-{PSN} {DS} {TS}.csv`
- [ ] `Plugins\IQS\IqsDocSpcDataCollector.xml`:
  - [ ] `DBId` = machine name, `Name` = `Primary [<machine>]`, `Family` = asset family (e.g. `CITIZEN_L20X_IV`).
  - [ ] `SourceDataInclusionList` = `1ST_/SPC_/VER_<instrument>_<site> : <instrument>` for the instruments ticked for that CNC only.
- [ ] `Plugins\PartLookup.xml` `LoadMatrixRevision` = `MAX`.
- [ ] Connection strings in `DocDb.xml`, `SpcDb.xml`, `PartLookup.xml` are unchanged.

**DataApps** (Step 10)
- [ ] `DataCollector_FileManager.exe.config`:
  - [ ] one `CNCn.Asset` per CNC with `CheckMismatchData` = `true`.
  - [ ] one `<PathN>` per instrument (CONTRACER1-3), with your source `Path`, `NewPath` under the data root, `ErrorPath`, `EndFileString` = `NA`.
- [ ] `DataCollector.exe.config`:
  - [ ] one `CNCn.<TYPE>` block per ticked instrument per CNC.
  - [ ] `CheckPath` = the File Manager `NewPath`, `ArchivePath` = `CheckPath\Backup`.
  - [ ] `BroadcastFilePaths\Path1` = broadcast path or `NA`, with `BroadcastFile` `true` only when a path is set.
- [ ] `DataAnalyzer.exe.config`:
  - [ ] `Opc_FirstRunProcess` / `Opc_VerificationProcess` / `Opc_ProductionProcess` end in `_<site>$`.
  - [ ] `Opc_CNCAssets` = `CNC1|CNC2|…` for the DOC count.

**Installed files untouched**
- [ ] The real files still have their old "Date modified" and contents:
  `C:\Medtronic\CNCNetPDM\CNCnetPDM.ini`, `C:\Medtronic\DOC-1\DOC_II\DOC_II.xml`, `C:\Medtronic\Data Collector\DataCollector.exe.config`.
- [ ] No new folders on the instrument shares or `D:\` from the wizard.

When the sandbox looks right, delete it or keep it for comparison.

---

## Part 3 - Real run

1. [ ] Close the wizard, start it again, and fill in the same values. Leave **Test mode** unticked.
2. [ ] Click **Configure** and let all 13 steps run. For Step 11 (CHMI), complete the manual steps when it pauses.
3. [ ] Check the same items as in 2.3, now in the real locations:
   - SINC folders: `C:\Program Files\deviceWISE\Gateway\staging\SINC\`
   - CNCnetPDM: `C:\Medtronic\CNCNetPDM\`
   - DOC: `C:\Medtronic\DOC-<n>\DOC_II\`, `...\Plugins\` and `...\Plugins\IQS\`
   - Data apps: `C:\Medtronic\File Manager\`, `C:\Medtronic\Data Collector\`, `C:\Medtronic\Data Analyzer\`
4. [ ] Each edited file has a `.<date-time>.bak` copy next to it.

### 3.1 Application checks (manual)

- [ ] **CNCnetPDM Workbench:** the service is running, the license is accepted, and Machine Status is green for each CNC once the network is connected.
- [ ] `C:\Medtronic\CNCNetPDM\` has `<dll>_<DeviceNr>.dll` next to each `<dll>_<DeviceNr>.ini`; Step 8 also checks this.
- [ ] **deviceWise:** the CNCnetPDM instance shows Connected, and `CNC1_Path`… are mapped to the right machines.
- [ ] **DOC (each instance):** DOC DB, SPC and OPC indicators are green.
- [ ] **File Manager, Data Collector, Data Analyzer:** each starts without errors.
- [ ] **File routing:**
  - [ ] Drop a test file in an instrument's source share.
  - [ ] The file reaches the File Manager `NewPath`.
  - [ ] The Data Collector picks it up and archives it to `Backup`.
- [ ] **Step 13 report:** open the filled D01555624 document. Automated items should be Pass; complete the blank manual items and sign off.

---

## Undoing a run

- Restore any file from its `.<date-time>.bak` copy (remove the suffix), then restart the application or service.
- Driver files: rename `<dll>_<DeviceNr>.dll` / `.ini` back to `<dll>_CNC<n>.dll` / `.ini`.
- SINC folders: delete `SINC\CNC<n>` folders that are not needed.
