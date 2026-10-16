# 800xA integration handoff: pre-change backup + property writes

Goal: add two proven capabilities to the existing PowerShell config wizard that configures the APC apps outside 800xA.

1. **Pre-change 800xA Full backup** before any update or config change (use as-is).
2. **Write 800xA object/General Properties** (the proven method; the actual properties will differ from the POC ones).

Everything below was proven on node SJUM1CAPPD0017 on 2026-09-30. Treat the included scripts as the reference implementation; wrap them, don't rewrite their internals.

## Environment and hard constraints

- ABB Compact HMI 6.1.1-1 (800xA 6.1 base), Windows Server (build 20348).
- No Python, no internet on the node. Only built-in Windows PowerShell 5.1 and `cscript.exe`.
- **Everything touching 800xA must run 32-bit**: `C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe` and `C:\Windows\SysWOW64\cscript.exe`. If the wizard runs 64-bit, call these as child processes and use `$LASTEXITCODE`.
- Runs as an account with 800xA permissions (tested as `ENT\SVC-APC-MPR`). Not yet tested from a service/non-interactive context.
- Files must be copied to the node as files. Pasting script text through the remote session strips `$` characters and silently corrupts scripts. Verify with `certutil -hashfile <file> SHA256` against `SHA256SUMS.txt`.

## Part 1: Pre-change backup (`Backup-800xA.ps1`, use as-is)

Mechanism (undocumented ABB interface, bound exactly from its own type description):

- `ABB.ABBSystems` COM → `.DefaultSystem.Object('[Maintenance Structure]Backup Definitions/Full backup')` → `.Aspect('Backup Definition').InterfaceDisp('IBackupDefASO')`.
- IDispatch cannot pass ABB ID structs, so the script declares the dual interface in C# via `Add-Type` (IID `04ed4420-15e8-4722-834c-89c0f7e94c8f`) with methods in exact vtable order and calls it from a C# helper class. **Do not reorder, add or remove methods in that interface declaration**; a wrong slot could call `ClearServices` or `SetPurgeCount` and alter the backup definition.
- Sequence: `PrepareStartBackup("", out aspectId, out objectId)` creates the entry `Full backup; <yyyy-mm-dd>; <hh-mm>`, then `StartBackup(ref objectId)`.
- Completion: read `<provider path>\<entry name>\Backup.log` for `Backup completed.` and `Errors: n, Warnings: m`. The provider's "running" flag stays 0 and is not usable.
- The entry list is read with `GPWrite3.vbs`, which must sit next to the script.
- Proven twice: about 85–90 s, 45 files, about 110 MB, Errors 0 / Warnings 0.

Usage from the wizard:

```powershell
$ps32 = "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
& $ps32 -NoProfile -ExecutionPolicy Bypass -File "$kit\Backup-800xA.ps1" -Start -Confirmed -MinFreeMB 2048
if ($LASTEXITCODE -ne 0) { throw "800xA backup failed (exit $LASTEXITCODE) - see Backup800xA_*.log" }
```

Parameters: `-Start` (without it: read-only report), `-Confirmed` (skip the YES prompt; the wizard does its own confirmation), `-MinFreeMB` (default 2048), `-TimeoutMin` (default 90), `-PollSec` (default 15), `-DefPath`, `-LogFile`.

Exit codes: `0` OK · `1` could not start · `2` not confirmed · `4` no entry/log within timeout · `5` completed with errors · `6` not enough free disk.

Never call anything on `IBackupDefASO` except the getters, `PrepareStartBackup` and `StartBackup`.

Note: the Backup Definition has no purge configured (`PurgeCount = -1`), so `C:\BACKUP` grows about 110 MB per backup.

## Part 2: Writing 800xA properties (method applies to any property)

Mechanism: local OPC DA, server `ABB.AfwOpcDaSurrogate.1`, via the OPC Automation wrapper (`OPC.Automation`, already registered). PowerShell's COM adapter fails on the OPC objects, so all OPC calls go through `GPWrite3.vbs` under 32-bit `cscript`; PowerShell wraps it with `Invoke-800xAGP.ps1`, which handles the 32-bit call itself.

```powershell
. "$kit\Invoke-800xAGP.ps1"
$r = Invoke-800xAGP -ItemId 'Cell_1:URL1'                         # read
$r = Invoke-800xAGP -ItemId 'Cell_1:URL1' -Value 'C:\new\path.png' # write + read-back
if (-not $r.Success) { throw "800xA write failed: $($r.Error)" }
"$($r.ItemId): '$($r.Before)' -> '$($r.After)'"                     # log for audit
```

`GPWrite3.vbs` exit codes: `0` OK · `1` error (message names the failing step) · `3` write accepted but read-back differs.

**Finding the ItemID for a new property** (never hand-build IDs): run the read-only explorer and copy the `ItemID` column.

```
C:\Windows\SysWOW64\cscript.exe //nologo GPExplore.vbs /server:ABB.AfwOpcDaSurrogate.1 /path:"[Functional Structure]|Root|Medtronic|Cell_1" /depth:1 /out:"C:\Temp\cell1.csv"
```

- Browse path: structure name in brackets, then object names (the Plant Explorer name before the comma), separated by `|`.
- ItemID formats seen: `Cell_1:URL1` (object property), `Root/Medtronic/Cell_1/State_Machine:CurrentState` (full path), `{guid}{guid}:PartNumberTag` (aspect property).
- The `Access` column must be `RW`; `DataType` tells what to write.
- Short IDs like `Cell_1:URL1` assume a unique object name; prefer the full-path or GUID form when names may repeat.

Known limits: values containing `"` are not supported; writing `True`/`False` to Bool properties has not been verified yet (test once); each call takes about 1 s (new process + connect), so heavy batch use would need a batch mode in `GPWrite3.vbs`.

Never write: calculation `SourceCode` or `TriggerText`, `ActionTrig_*` order flags, or anything that drives the process.

## Suggested tasks for the wizard

1. Add a "Pre-change backup" step that calls `Backup-800xA.ps1 -Start -Confirmed` and blocks the change unless the exit code is 0; record the backup name from its log.
2. Add a property-write step driven by a config list (ItemID, value, expected type), using `Invoke-800xAGP`, logging before/after values, and failing on any non-success.
3. Ship the four script files with the wizard in one folder and check them against `SHA256SUMS.txt`.
4. Test on a non-production node first, then do one real run and review the logs.

## Files in this package

| File | Role |
|---|---|
| `Backup-800xA.ps1` | Full backup: report (default) or `-Start`; completion from `Backup.log` |
| `GPWrite3.vbs` | OPC DA read/write/browse of one item (32-bit cscript) |
| `Invoke-800xAGP.ps1` | PowerShell wrapper around `GPWrite3.vbs`, returns Before/After/Success/Error |
| `GPExplore.vbs` | Read-only recursive dump of properties to CSV, to find ItemIDs, types and access |
| `SHA256SUMS.txt` | Hashes of the four scripts |
