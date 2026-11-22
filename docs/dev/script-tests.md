# Script tests

How the Pester tests in `tests/scripts/` run the scripts, and what each test file covers. The fakes and what isn't tested are in [testing.md](testing.md).

`Invoke-Script` runs each script in a child pwsh, with `USERPROFILE` (which pwsh's `$HOME` follows) pointed into `TestDrive:` wherever the script writes under `~`, so no test writes the real `run.log`. Scripts that run under Windows PowerShell 5.1 are tested under 5.1. Trade-off: a test that calls the fake `dsc` costs about 2s, for running the scripts' real path to dsc.

| Test file | What it covers, beyond the obvious |
|---|---|
| `ConvertTo-FlatConfiguration` | each refusal; the tag order, `-Batch`, `-First` and the aggregate, with the real `yq` on small documents. It also flattens every entry in `dsc/`, so a name used twice across modules fails here rather than at the start of an install, and checks that a home entry with a distribution has `Winfiles/Wsl` in its host's system entry. `just flatten` is tested only for its failure, since a flat copy goes to the real `~/.local/state` |
| `Invoke-Configuration` | the batches it runs and in which order; a resource reporting `_restartRequired` pulled into a first `restart` batch, and none when nothing reports one; 194 logged as a stop for a restart; a failed discovery stopping the run before anything is applied; the one total of a `test` |
| `Set-RestartStage`, `Find-RestartResource` | the dsc operations and their order, what it tells the person, failures and refusals; the `winfiles-restart:` lines, a resource inside an Include result, an empty answer, a failed test |
| `Test-Winfiles` (also `Set-Winfiles`) | a small flat document answered by the fake `dsc`; refusing a document with an Include; `-TotalsFile`; the `apply` phase for a batch name |
| `dsclog` | `Get-ResourceResult`, `Get-RestartReport` and `Get-ResourceProblem` on each result shape DSC 3.3.0 gives |
| `restart` | the pending-restart reasons, faking only the servicing key and the computer's two names |
| `Justfile` | reads the real justfile with `just --dry-run` (the order, one `Invoke-AsAdmin.ps1` call, no recipe calling gsudo), and runs a justfile of the same shape with the real helper to show 3010, 194, 1 and 0 come out of the outer `just` unchanged |
| `Invoke-As` | `Invoke-AsAdmin.ps1` and `Invoke-AsUser.ps1` with the fake gsudo, and `privilege.ps1` through them |
| `install.cmd` | the real `install.cmd`, with this machine's mise and just, but only with a host that has no configuration, so `just install` stops in `require` before UAC or any change: its arguments, exit code, working folder and clean environment, and that it writes and then removes the RunOnce entry |
| `Invoke-Install`, `Resume-Winfiles` | copies run under 5.1, with a fake `Start-Clean.ps1` or `install.cmd` and their own RunOnce and restart-pending keys under HKCU (`-RunOnceKey`, `-RebootPendingKey`), and a `TcpListener` for winget's source (`-SourceHost`, `-SourcePort`, `-WaitSeconds`). One test chains the real two scripts through two restarts, deleting the RunOnce value between runs as Windows does. All check their `[resume]` lines |
| `Invoke-Clean`, `Start-Clean`, `miseignore` | commands under the real mise; the version check under 5.1; `Start-Clean.ps1` under 5.1 with and without mise on `PATH`; the mise configuration to ignore under pwsh and 5.1, and against this machine's `mise config ls --json` |
| `Initialize-Winfiles`, `bootstrap.cmd` | the bootstrap's checks and what it prints, not its installs; the App Installer retry's failure path (a fake winget that always answers `0x8A15000F`), skipped elevated; `bootstrap.cmd` from a copy of the repo without `mise.toml`; CRLF and a `.gitattributes` entry for every root `.cmd` |
| `Get-ManualInstaller` | the real Uninstall keys, read only, with a program installed on the machine and ones that can't be; downloads recorded by the fake winget |
| `Watch-TestVmLog` | the watch scriptblock, taken from the script's AST and run under `powershell.exe` against scratch logs ([reference](../reference/test-vm.md#following-logs-in-the-vm)) |
| `Help` | that Get-Help reads every script's synopsis |
| `Invoke-Lint` | the real PSScriptAnalyzer on small scripts in `TestDrive:` (a finding named by file, line and rule; the layout rules only for a test file; the 115-character limit), and on the whole repo, which has to have no findings |
