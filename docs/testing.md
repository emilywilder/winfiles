# Testing

The Pester tests and their fakes, what isn't tested, `demos/`, `surveys/`, and the test VM. Facts about the VM are in [reference/test-vm.md](reference/test-vm.md), and test and install timings are in [benchmarks.md](benchmarks.md).

## The Pester tests

`just test [paths]` (`scripts/Invoke-Tests.ps1`, through `Invoke-Clean.ps1`) runs the Pester tests in `tests/`: `tests/resources/` for the `Winfiles/*` resources, and `tests/scripts/` for the scripts. Working on one area, run only its files: `just test tests/scripts/Invoke-Install.Tests.ps1`. Pester is a module, which mise can't install, so the script pins its version (6.2.0), saves it to `~/.cache/winfiles/modules` on first use, and imports it from there.

The tests cover what winfiles decides: which exit codes it uses, carrying on past a package that fails, the JSON and messages it writes, the order it runs things in. They don't cover how Windows, winget or an installer behaves, which is what the test VM has caught so far.

**Fakes, not mocks, where a child process can use them.** What a test talks to is replaced with files in `tests/fakes/`, put first on a child pwsh's `PATH` or pointed to by a variable. Keep the fakes basic: extend one when a test needs it, rather than modelling Windows.

| Fake | Stands in for | How |
|---|---|---|
| `bin/dsc.cmd` (`fake-dsc.ps1`) | dsc | answers each `--file` from canned JSON, by file name, in the shapes DSC 3.3.0 gives (a `set` Include included) |
| `bin/winget.cmd` (`fake-winget.ps1`) | winget | keeps installed ids in a state folder and answers `winget dscv3 package` as winget 1.29.380 did; records downloads without making them. It throws without its state folder |
| `bin/gsudo.cmd` (`fake-gsudo.ps1`) | gsudo | writes its arguments to a file and runs nothing. It's first on `PATH` as well as passed in through `WINFILES_GSUDO`, because a script that ignored the override once reached the real gsudo (2026-11-18) |
| `scoop.ps1` | Scoop | in a temporary Scoop root that `$env:SCOOP` points to; leaves the same files real Scoop does |
| `scoop-install.ps1` | Scoop's installer | served by `Start-FakeWebServer`, a `TcpListener` on a free loopback port (`Invoke-WebRequest` has no `file://`, and an `HttpListener` would need elevation) |

`Assert-FakeWinGetCliRuns` stops the winget tests if a child pwsh would find the real winget first, so a test can't install real packages. No test elevates: the scripts' tests set `WINFILES_ELEVATED=true` instead.

### Resources

`Invoke-Resource` (`tests/resources/Resource.ps1`) runs a resource as DSC does: a child pwsh started with the command from its manifest, in `dsc/resources`, with the instance on stdin. So the tests cover the manifest and the real stdin, stderr and exit codes.

`Winfiles/Wsl`, `Winfiles/WslDistribution` and `Winfiles/ComputerName` are the exception. They name their registry keys, CIM classes, `wsl.exe` and `whoami.exe` themselves, which a child process can't be pointed away from, so `Invoke-ResourceScript` runs their scripts in the test's process with Pester mocks. The fake machine is still real where it can be:
- Default mocks of `Test-Path`, `Get-ItemProperty` and `Get-ChildItem` rewrite the `Lxss` and `RebootPending` paths to Pester's `TestRegistry:`. They're defaults that call the cmdlet through its CommandInfo, because Pester 6 has no fallthrough for a mock whose filters don't match.
- The fake `wsl.exe` registers what it installs there, and `Winfiles/Wsl` runs against a fake WSL held in a hashtable that `--install` and `--update` change.
- Sources are files in `TestDrive:`.

A resource that reports `_restartRequired` has its entries checked against DSC's own schema (`Assert-RestartRequiredSchema`, from `dsc schema -t restart-required`), because DSC 3.3.0 only logs a warning for an entry that doesn't fit, and the restart then goes unreported ([reference](reference/dsc.md#where-restartrequired-lands)). That test needs the pinned `dsc` on `PATH`, so it fails, rather than skips, outside `just test`.

`Winfiles/Scoop`'s install tests run only unelevated, and its test of refusing elevation runs only elevated, so an elevated `just test` skips the rest.

- Trade-off: about 0.6s per test for a child pwsh ([benchmarks](benchmarks.md#tests)), for tests that also cover the manifest. Revisit if the suite gets slow enough to skip.
- Trade-off: the in-process tests take about 0.1s each, but don't cover the manifest. Revisit if those scripts gain seams a child process could use.

### Scripts

`Invoke-Script` runs each script in a child pwsh, with `USERPROFILE` (which pwsh's `$HOME` follows) pointed into `TestDrive:` wherever the script writes under `~`, so no test writes the real `run.log`. Scripts that run under Windows PowerShell 5.1 are tested under 5.1. Trade-off: a test that calls the fake `dsc` costs about 2s, for running the scripts' real path to dsc.

| Test file | What it covers, beyond the obvious |
|---|---|
| `ConvertTo-FlatConfiguration` | each refusal; the tag order, `-Batch`, `-First` and the aggregate, with the real `yq` on small documents. It also flattens every entry in `dsc/`, so a name used twice across modules fails here rather than at the start of an install, and checks that a home entry with a distribution has `Winfiles/Wsl` in its host's system entry. `just flatten` is tested only for its failure, since a flat copy goes to the real `~/.local/state` |
| `Invoke-Configuration` | the batches it runs and in which order; a resource reporting `_restartRequired` pulled into a first `restart` batch, and none when nothing reports one; 194 logged as a stop for a restart; a failed discovery stopping the run before anything is applied; the one total of a `test` |
| `Set-RestartStage`, `Find-RestartResources` | the dsc operations and their order, what it tells the person, failures and refusals; the `winfiles-restart:` lines, a resource inside an Include result, an empty answer, a failed test |
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
| `Watch-TestVmLog` | the watch scriptblock, taken from the script's AST and run under `powershell.exe` against scratch logs ([reference](reference/test-vm.md#following-logs-in-the-vm)) |
| `Help` | that Get-Help reads every script's synopsis |

### Not tested

- **Scripts that need a test VM or elevation:** `New-TestVm.ps1`, `Copy-RepoToTestVm.ps1`, `Enter-TestVm.ps1`, `testvm.ps1`.
- **Small scripts:** `Export-DscResource.ps1` (a nice-to-have), `Show-ScoopNotes.ps1`, and `Invoke-Tests.ps1` (which runs the suite itself).
- **The restart gate:** the end of `Set-RestartStage.ps1`, and the check after each batch. What Windows says about a pending restart is the real machine's, which a child process can't mock. A way back is in [optional-goals.md](optional-goals.md).
- **The optional features for real,** which need an elevated shell even for `test`.
- **The bootstrap's installs,** including the success path of its App Installer retry, which goes on to change the machine ([optional-goals.md](optional-goals.md)).
- **Missing mise:** `Start-Clean.ps1`'s and `Invoke-Clean.ps1`'s missing-mise exits, since the registry's `PATH`, and the environment Windows builds, can't be faked.
- **What only a real restart shows:** that the RunOnce entry fires at the next sign-in, that its `cmd /c start` window stays open, and that the restart's exit code reaches `Invoke-Install.ps1` through `just`, `mise exec`, `Invoke-Clean.ps1` and `Start-Clean.ps1`. Full runs in the test VM have shown all three ([reference](reference/test-vm.md#what-full-runs-have-confirmed)).
- **That a flat copy gives the same results as its entry.** It's compared by hand with `just dsc config test --file dsc/<entry>`.

## demos/

Things run by hand to watch how something behaves, with nothing to pass or fail. Their recipes are in `demos/justfile`: run `just <recipe>` from `demos/`, or `just -f demos/justfile <recipe>` from the root. `demos/dsc-messages/` (`just dsc-messages <doc> [dsc args]`) shows how DSC displays lines a resource writes to stderr (levels, live output, Include nesting), and its README records the results per DSC version. Its stand-in resource `Test/SlowList` is outside `dsc/resources`, so `just dsc` never discovers it.

## surveys/

Things run to find out how winget, DSC, installers or Windows really behave, measured to settle a question rather than assumed. They're kept out of `tests/` because they run against the real tools, usually attended in the test VM, and only when there's a question to answer. A survey may use Pester (through `Invoke-Tests.ps1`, from `surveys/justfile`) and assert what it recorded, so a rerun flags a change. Each survey's README records how to run it and what it found, with dates and versions; see `surveys/README.md`.

## The test VM

Clean installs are tested in a Hyper-V VM, not Windows Sandbox, which can't run WSL 2 ([reference](reference/test-vm.md#windows-sandbox)). `just test-vm <iso>` (`scripts/New-TestVm.ps1`) creates it, and doesn't start it. With `-Unattended` it skips Windows Setup and signs in automatically at every boot, so the install's restart needs no attention ([reference](reference/test-vm.md#automatic-sign-in-and-the-blank-password)). It prints the commands for taking a `clean` checkpoint and returning to it. Clean runs restore the `updated` checkpoint.

A test VM's computer name doesn't decide its configuration, so pass the host:
- **`vm`** has every shared module, and none of a real machine's hardware: `.\install.cmd vm`.
- **`vm-quick`** goes through every step of `just install` (features, WSL, both configurations, `check`, `post-install`) and every kind of resource, faster: `.\install.cmd vm-quick`. The shared modules that configure rather than install are included as they are. The package documents are replaced by a few small packages in `dsc/hosts/vm-quick/`, chosen so each package resource and the Scoop list still take their paths:
  - a `Microsoft.WinGet/Package` already installed (Edge), and one to install machine-wide (WinDirStat);
  - a `Winfiles.WinGet/Package` with `_scope: User` (gh);
  - a bare Scoop name and a `bucket/name`.

  Every Scoop bucket is still added. emily's WSL document there installs a pinned Alpine minirootfs instead of NixOS-WSL, and leaves out `~/.wslconfig` and `~/.wslgconfig`. Its `# post-install:` note is the reminder of what it leaves out.

  Trade-off: a package that only fails in the real lists, or a NixOS-WSL image problem, only shows up under `vm`, so run `vm` before relying on a change to either. Revisit if the two drift, for example when a shared module gains an install that `vm-quick` doesn't cover.

| Recipe | What |
|---|---|
| `just test-vm-copy [name]` | packs the repo with `git archive` and copies it in over PowerShell Direct. By default this is the working tree: commits plus uncommitted changes to tracked files, through `git stash create`. Untracked files are left out, so `git add` new files first. It replaces `~\src\winfiles` in the VM, so edits made inside the VM are lost |
| `just test-vm-unelevated <name> '<command>'` | starts a command unelevated, through a scheduled task in the VM for its user, and reads the output back as it runs, e.g. `'cmd /c .\install.cmd vm-quick'`. It needs someone signed in (a disconnected session counts); UAC prompts still show on the VM's desktop, and after the restart someone signs in and presses Enter. It exits 3010 when the VM stops answering, or when the restart stops the task |
| `just test-vm-run <name> '<command>'`, `just test-vm-shell [name]` | for reading results, e.g. `just test-vm-run <name> 'mise exec -- just check vm'`. PowerShell Direct runs elevated with no UAC, so never run `bootstrap.cmd` or `install.cmd` this way ([reference](reference/test-vm.md#powershell-direct)) |
| `just test-vm-log [name] [-All]` | follows `run.log` in the VM, showing its last `-Tail` lines first. `-All` also follows winget's `DiagOutputDir`, for the detail behind a failed package (`-All`, not `-Debug`, which is a PowerShell common parameter). It prints `-- no new lines for about Ns` every 30s, so quiet can be told from stuck, and reconnects after a guest restart. It asks for UAC, for `Get-VM` |

Run `bootstrap.cmd` and `install.cmd` in the VM's desktop, or through `just test-vm-unelevated`. That saves typing and returns the output, but isn't unattended. Trade-off: `test-vm-unelevated` needs someone signed in at the VM. Revisit if a run has to work with nobody signed in.

`run.log` shows what the scripts do, but not what Scoop and DSC do in between, so those parts of a run look idle. `Winfiles/Wsl` and `Winfiles.WinGet/Package` write their own lines there ([install.md](install.md#what-a-run-says)). Trade-off: `test-vm-log` shows winget's detail only with `-All`. Revisit if `-All` ends up being passed every time, or if the Scoop or DSC gap gets in the way.
