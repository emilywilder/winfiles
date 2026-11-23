# Testing

What `winfiles.ps1 test` covers, the fakes it runs against, and what isn't tested. Timings are in [benchmarks.md](../benchmarks.md#tests).

| Doc | What |
|---|---|
| [resource-tests.md](resource-tests.md) | how `tests/resources/` runs the `Winfiles/*` resources |
| [script-tests.md](script-tests.md) | how `tests/scripts/` runs the scripts, and what each test file covers |
| [test-vm.md](test-vm.md) | clean installs in a Hyper-V VM |
| [demos-and-surveys.md](demos-and-surveys.md) | things run by hand against the real tools |

## The Pester tests

`winfiles.ps1 test [paths]` (`scripts/Invoke-Test.ps1`, through `Invoke-Clean.ps1`) runs the Pester tests in `tests/`: `tests/resources/` for the `Winfiles/*` resources, and `tests/scripts/` for the scripts. Working on one area, run only its files: `winfiles.ps1 test tests/scripts/Invoke-Install.Tests.ps1`. Pester is a module, which mise can't install, so the script pins its version (6.2.0), saves it to `~/.cache/winfiles/modules` on first use, and imports it from there.

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

## Not tested

- **Scripts that need a test VM or elevation:** `New-TestVm.ps1`, `Copy-RepoToTestVm.ps1`, `Enter-TestVm.ps1`, `testvm.ps1`.
- **Small scripts:** `Export-DscResource.ps1` (a nice-to-have), `Show-ScoopNote.ps1`, and `Invoke-Test.ps1` (which runs the suite itself).
- **The restart gate:** the end of `Set-RestartStage.ps1`, and the check after each batch. What Windows says about a pending restart is the real machine's, which a child process can't mock. A way to test it is in [run/restarts.md](../run/restarts.md#not-done-yet).
- **The optional features for real,** which need an elevated shell even for `test`.
- **The bootstrap's installs,** including the success path of its App Installer retry, which goes on to change the machine ([run/bootstrap.md](../run/bootstrap.md#not-done-yet)).
- **Missing mise:** `Start-Clean.ps1`'s and `Invoke-Clean.ps1`'s missing-mise exits, since the registry's `PATH`, and the environment Windows builds, can't be faked.
- **What only a real restart shows:** that the RunOnce entry fires at the next sign-in, that its `cmd /c start` window stays open, and that the restart's exit code reaches `Invoke-Install.ps1` through `winfiles.ps1`, `mise exec`, `Invoke-Clean.ps1` and `Start-Clean.ps1`. Full runs in the test VM have shown all three ([reference](../reference/test-vm.md#what-full-runs-have-confirmed)).
- **That a flat copy gives the same results as its entry.** It's compared by hand with `winfiles.ps1 dsc config test --file dsc/<entry>`.
