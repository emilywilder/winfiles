# Resource tests

How the Pester tests in `tests/resources/` run the `Winfiles/*` resources. The fakes and what isn't tested are in [testing.md](testing.md); the resources themselves are in [config/resources.md](../config/resources.md).

`Invoke-Resource` (`tests/resources/Resource.ps1`) runs a resource as DSC does: a child pwsh started with the command from its manifest, in `dsc/resources`, with the instance on stdin. So the tests cover the manifest and the real stdin, stderr and exit codes.

`Winfiles.Wsl/Wsl`, `Winfiles.Wsl/Distribution` and `Winfiles/ComputerName` are the exception. They name their registry keys, CIM classes, `wsl.exe` and `whoami.exe` themselves, which a child process can't be pointed away from, so `Invoke-ResourceScript` runs their scripts in the test's process with Pester mocks. The fake machine is still real where it can be:
- Default mocks of `Test-Path`, `Get-ItemProperty` and `Get-ChildItem` rewrite the `Lxss` and `RebootPending` paths to Pester's `TestRegistry:`. They're defaults that call the cmdlet through its CommandInfo, because Pester 6 has no fallthrough for a mock whose filters don't match.
- The fake `wsl.exe` registers what it installs there, and `Winfiles.Wsl/Wsl` runs against a fake WSL held in a hashtable that `--install` and `--update` change.
- Sources are files in `TestDrive:`.

A resource that reports `_restartRequired` has its entries checked against DSC's own schema (`Assert-RestartRequiredSchema`, from `dsc schema -t restart-required`), because DSC 3.3.0 only logs a warning for an entry that doesn't fit, and the restart then goes unreported ([reference](../reference/dsc.md#where-restartrequired-lands)). That test needs the pinned `dsc` on `PATH`, so it fails, rather than skips, outside `winfiles.ps1 test`.

`Winfiles.Scoop/Scoop`'s install tests run only unelevated, and its test of refusing elevation runs only elevated, so an elevated `winfiles.ps1 test` skips the rest.

- Trade-off: about 0.6s per test for a child pwsh ([benchmarks](../benchmarks.md#tests)), for tests that also cover the manifest. Revisit if the suite gets slow enough to skip.
- Trade-off: the in-process tests take about 0.1s each, but don't cover the manifest. Revisit if those scripts gain seams a child process could use.
