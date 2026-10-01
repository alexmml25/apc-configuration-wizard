# VM Test Checklist - APC Configuration Wizard

Use this for the first runs of the wizard on an APC VM. Work through the parts in order:
automated tests, then a **test mode** run (changes only sandbox copies), then the real run.

**Launching:** double-click **`Start-Wizard.cmd`** to start the wizard, and **`Run-Tests.cmd`** to run the tests.
Both sit in the wizard folder. The launcher asks for administrator rights and unblocks the scripts.
If the wizard stops with an error, its window stays open so you can read the message.
Run them from a local folder (e.g. `D:\APC_Config\Wizard`) rather than a network share, because
Windows does not show mapped drives to programs running as administrator.

Tick each box as you go. If a result differs from what is described, stop and note the step,
the log line and the file involved.

---

## Part 1 - Automated tests on the VM

These use the sample files in `tests\fixtures` and a temporary folder. They do not touch the
installed applications, services, the Site DB or deviceWise.

1. [ ] Copy the wizard folder to the VM (e.g. `C:\APC_Config\Wizard`).
2. [ ] Double-click **`Run-Tests.cmd`**. Alternatively, in PowerShell run
   `powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`.
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

The wizard is a step-by-step window: the step list is on the left, and **Back** / **Next** are at the bottom.

1. [ ] Double-click **`Start-Wizard.cmd`** and allow the administrator prompt.
2. [ ] **Configuration type:** pick **Initial System Configuration**, then **Next**.
   Configuration Restore and System Update / Import are greyed out ("Not available yet").
3. [ ] **Sign in & site:** enter your domain login, pick the site, and check the Site DB fields. Enter the
   component passwords (needed when step 2 or 4 runs). Click **Next**: your login is checked and the Site DB machines load.
4. [ ] **Machines & DOC:** set the DOC instance count and pick the machine for each DOC instance.
   DOC 1 = CNC1, DOC 2 = CNC2, DOC 3 = CNC3. Check the Family, Device Nr and DLL shown for each; a red **Error** means Step 8 would stop (hover for the reason).
5. [ ] **SINC & CNCnetPDM:** leave **Use default perpetual license** ticked (or untick and paste a new key).
6. [ ] **Data applications:** check that the site defaults loaded. For each instrument:
   - [ ] **Qty** is correct (CONTRACER is usually 3).
   - [ ] **Used by** is ticked only for the CNCs that use it.
   - [ ] **Source path** is the instrument's shared folder.
   - [ ] **More paths:** **Error path** (blank = local DoneError folder) and **Broadcast (MES)** (blank = NA) are correct.
7. [ ] **Review & run:** check the summary, set **Run mode** to **Test mode**, check the "Steps that will run" (skipped steps are struck through), and click **Start configuration**.

### 2.2 What you should see

- [ ] The window title ends with `[TEST MODE]`, and the **Run** page shows the progress bar and step list. **Back** and **Next** are disabled while it runs.
- [ ] **Show log** starts with the type and mode line, then `TEST MODE - sandbox: C:\APC_Config\Sandbox\...`, the number of files copied, and any files not found.
- [ ] Steps 2, 4, 5, 6, 7, 11 and 12 show **Skipped**.
- [ ] Steps 1, 3, 8, 9 and 10 show **Complete** with no `[FAIL]` lines in the log.
- [ ] Step 13 runs. Checks for skipped parts (deviceWise, TSDB, CHMI, services) are expected to fail in test mode.
- [ ] When the run ends, the title on the Run page says **Finished** and **Continue** is enabled.
- [ ] **Verification** page: the results line shows the passed / warnings / failed / manual counts. Enter a Change ID and click
  **Generate draft checklist**. **Open draft** opens `C:\APC_Config\Reports\D01555624_Filled_<date-time>.docx`:
  - [ ] "Reason for Configuration" has only **Initial System Configuration** ticked.
  - [ ] "Related Change Management Record" shows `Change ID: <what you entered>`.
  - [ ] The HTML report title says **(draft)** and has no signature lines.

### 2.3 Check the sandbox files

Open `C:\APC_Config\Sandbox\<date-time>\` and check each folder.

**SINC** (Step 3)
- [ ] `SINC\CNC1`, `CNC2`, `CNC3` (one per DOC instance), each with `Processing`, `DoneSuccess`, `DoneError`.
- [ ] No folders named after machines.
- [ ] Real run: `Access: CNC1` … PASS; `ENT\SVC-APC-<site>` has Modify on each `SINC\CNC{n}`.

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

**Permissions (real run only)**
- [ ] Step 10 shows `Access: <folder>` PASS for the local data folders and sources. In folder Properties → Security, `SVC-APC-<site>` has Modify.
- [ ] Network sources show "cannot be checked from the wizard (runs as administrator)". Confirm in File Manager's log that they are found.

**Installed files untouched**
- [ ] The real files still have their old "Date modified" and contents:
  `C:\Medtronic\CNCNetPDM\CNCnetPDM.ini`, `C:\Medtronic\DOC-1\DOC_II\DOC_II.xml`, `C:\Medtronic\Data Collector\DataCollector.exe.config`.
- [ ] No new folders on the instrument shares or `D:\` from the wizard.

When the sandbox looks right, delete it or keep it for comparison.

---

## Part 3 - Real run

1. [ ] Close the wizard, start it again (`Start-Wizard.cmd`), and fill in the same values.
2. [ ] On **Review & run**, choose the **Run mode**:
   - **Reviewed steps only** (the default): a real run of the steps reviewed so far (1, 3, 8, 9, 10, 13). The others show Skipped.
   - **Full run**: all 13 steps. Use it only once every step has been reviewed.
3. [ ] Click **Start configuration** and confirm the "Confirm real run" prompt. For Step 11 (CHMI), complete the manual steps when it pauses.
   The title shows `[REVIEWED STEPS ONLY]` for a reviewed-steps run.
4. [ ] Check the same items as in 2.3, now in the real locations:
   - SINC folders: `C:\Program Files\deviceWISE\Gateway\staging\SINC\`
   - CNCnetPDM: `C:\Medtronic\CNCNetPDM\`
   - DOC: `C:\Medtronic\DOC-<n>\DOC_II\`, `...\Plugins\` and `...\Plugins\IQS\`
   - Data apps: `C:\Medtronic\File Manager\`, `C:\Medtronic\Data Collector\`, `C:\Medtronic\Data Analyzer\`
5. [ ] Each edited file has a `.<date-time>.bak` copy next to it.

### 3.0 800xA (Steps 11 and 12, full run only)

Run these on a **non-production** node first. Steps 11 and 12 are not part of *Reviewed steps only* yet.

- [ ] **CHMI (800xA) page** (after Data applications): opening it takes a few seconds while it reads each cell.
  - **Current** shows each cell's `VerificationOnShift` from 800xA (on the MPR test VM: Cell_1 Both, Cell_2/3 Button), and **Set to** starts on the same value. "Unknown" means the read failed; you then have to pick a value.
  - **First shift starts at** shows 05:00 for MPR. It is enabled only when a cell is set to Both.
  - The CSV folders are `<data root>\BENCH` and `<data root>\100%`.
  - **Review & run** lists the trigger per CNC and marks changed ones "(changed)".
- [ ] **Step 11:** for each cell, the log shows `800xA property <ItemID>` with `'before' -> 'after'`, or `Already '<value>' - not written`.
  - The properties are `Root/Medtronic/Cell_n/Measurements:SampleCSV_Filepath`, `...:100pctCSV_Filepath`, `Cell_n:VerificationOnShift`, and `Cell_n:Shift1Hour` (only for cells set to Both).
  - Every change is also recorded in `C:\APC_Config\Logs\800xA_changes_<date-time>.log`.
  - Check one changed value in Plant Explorer (Cell_n > Verification GP, Measurements > Inspections GP). This is also the first real Bool write.
- [ ] **Step 12:** `800xA Full backup` PASS shows the backup name, e.g. `Full backup; 2026-09-30; 16-05`, with its folder under `C:\BACKUP`, file count, size, errors 0 and warnings 0.
  - The kit's full output is in `C:\APC_Config\Logs\Backup800xA_<date-time>.log`.
- [ ] If the log shows `800xA kit … SHA256 mismatch`, a file in `kits\800xA` was changed or damaged in the copy. Copy the kit again; do not edit it.

### 3.1 Application checks (manual)

- [ ] **CNCnetPDM Workbench:** the service is running, the license is accepted, and Machine Status is green for each CNC once the network is connected.
- [ ] `C:\Medtronic\CNCNetPDM\` has `<dll>_<DeviceNr>.dll` next to each `<dll>_<DeviceNr>.ini`; Step 8 also checks this.
- [ ] Step 8 log shows `CNCn device <DeviceNr> connected` = PASS for each CNC. A WARN shows the last line of `log\log_<DeviceNr>_<yyMMdd>.txt` and whether the machine answers on port 683.
- [ ] **deviceWise:** the CNCnetPDM instance shows Connected, and `CNC1_Path`… are mapped to the right machines.
- [ ] **DOC (each instance):** DOC DB, SPC and OPC indicators are green.
- [ ] **File Manager, Data Collector, Data Analyzer:** each starts without errors.
- [ ] **File routing:**
  - [ ] Drop a test file in an instrument's source share.
  - [ ] The file reaches the File Manager `NewPath`.
  - [ ] The Data Collector picks it up and archives it to `Backup`.
- [ ] **Draft checklist:** on the **Verification** page, enter the Change ID and click **Generate draft checklist**, then **Open draft**.
  Automated items should be Pass. The draft is not approved by the wizard: complete the blank manual items, then review and QA sign it independently.

### 3.2 Other configuration types

- [ ] **Verification** (read-only): pick it on the first page. The pages are Sign in & site → Machines & DOC → Review → Run → Verification.
  - [ ] Review shows the green **Read-only** note and no run-mode choice; the button says **Start verification** and there is no "Confirm real run" prompt.
  - [ ] Only Steps 1 and 13 are listed and run. No `.bak` files appear, and no installed file changes its "Date modified".
  - [ ] On the Verification page, **Reason for configuration** is shown, with **Other: Verification only (no changes)** selected. The draft ticks Other with that text.
- [ ] **System Component Configuration:** pick it, tick one component (e.g. **CNCnetPDM**) on the **Components** page.
  - [ ] Only the pages that component needs appear (CNCnetPDM: Machines & DOC, then SINC & CNCnetPDM).
  - [ ] Review lists Steps 1, 8, 12 and 13 (12 struck through in Reviewed steps only). Only those rows show on the Run page.
  - [ ] The draft ticks **System Component Configuration**.

---

## Undoing a run

- Restore any file from its `.<date-time>.bak` copy (remove the suffix), then restart the application or service.
- Driver files: rename `<dll>_<DeviceNr>.dll` / `.ini` back to `<dll>_CNC<n>.dll` / `.ini`.
- SINC folders: delete `SINC\CNC<n>` folders that are not needed.
