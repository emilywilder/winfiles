# Drift from upstream

Where a winfiles setting was taken from another project and is now done differently on purpose. Each entry
names the upstream file at a pinned commit, what each side does, the evidence, and when to revisit. A plain
"taken from" with no difference stays as a comment beside the setting and isn't listed here.

## Sources

| Source | Pinned at | Used for |
| --- | --- | --- |
| [PowerShell/DSC#828](https://github.com/PowerShell/DSC/issues/828) | read 2026-11-17 (an issue, not code) | `_scope` on `Winfiles.WinGet/Package` (`dsc/resources/wingetpackage.*`) |
| [microsoft/WindowsDeveloperConfig](https://github.com/microsoft/WindowsDeveloperConfig) | `e4921dde0704380e8a61eef367cf0347b192bbdb` | Taskbar, Start, Search, Explorer and Widgets registry settings in `dsc/modules/{home,system}/settings.dsc.yaml` |

## Entries

### Install scope: `Winfiles.WinGet/Package`'s `_scope` (2026-11-17)

- **winfiles:** `Winfiles.WinGet/Package` (`dsc/resources/wingetpackage.*`) takes `Microsoft.WinGet/Package`'s
  properties plus `_scope: User | Machine`. With `_scope`, `set` installs a missing package with
  `winget install --exact --scope user|machine`, then hands the instance without `_scope` to
  `winget dscv3 package --set`. `get` and `test` pass straight through to `winget dscv3 package` and ignore the
  scope a package is installed in.
- **Upstream:** [PowerShell/DSC#828](https://github.com/PowerShell/DSC/issues/828) proposes a canonical `_scope`
  property (open when read on 2026-11-17, no linked PR or milestone). On 2025-08-20 the DSC working group agreed on
  the values `User` and `Machine`. The default was asked about and never answered. App Installer's
  `Microsoft.WinGet/Package` (winget 1.29.380) has neither `_scope` nor `scope`, so it installs in whichever scope
  winget picks.
- **Why they differ:** without a scope, winget picked gh's machine-wide MSI on every path, which raises a UAC
  prompt in the unelevated `just home` (`surveys/winget-paths`, test VM, 2026-11-17). Until then the home lists
  set `scope: User` on `Winfiles/WinGetPackageList`. A global `installBehavior` scope in winget's `settings.json`
  was ruled out, since the elevated `just system` reads the same file.
- **Kept in step:** the values are the working group's, and the other properties are exactly upstream's, so moving
  to the official resource is meant to be a change of `type:` only.
- **Revisit:** when `just dsc resource schema --resource Microsoft.WinGet/Package` shows `_scope`, after an App
  Installer update. Check the semantics before swapping: upstream's `test` may count a package installed in the
  other scope as drift, or `_scope` may get a default, where this resource ignores the scope in `test`.

### Web results in Start: `DisableSearchBoxSuggestions` (2026-11-15)

- **winfiles:** `HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer`, DWord 1, in the system configuration's
  System Settings (`dsc/modules/system/settings.dsc.yaml`). Applies to every account on the machine.
- **Upstream:** `HKCU\SOFTWARE\Policies\Microsoft\Windows\Explorer`, DWord 1, written from an elevated process
  ([`steps/registry-taskbar-search.ps1`](https://github.com/microsoft/WindowsDeveloperConfig/blob/e4921dde0704380e8a61eef367cf0347b192bbdb/src/windows-dev-config/steps/registry-taskbar-search.ps1#L37),
  step `WebSearchOff`). HKCU is where the ADMX defines this policy, for users only.
- **Why they differ:** an unelevated process can only read `HKCU\Software\Policies`, so the unelevated home
  configuration failed with "Registry error" on a new install (test VM, 2026-11-15). Upstream never makes the
  write unelevated: `dev-config.ps1` calls `Invoke-DevConfigElevate` (`steps/_elevation.ps1`), which relaunches
  the script with `Start-Process -Verb RunAs` unless it's already an administrator, and stops with `-NoElevate`
  in an unelevated shell. `Set-DevConfigRegistryValue` (`steps/_registry.ps1`) then writes `HKCU:\` directly,
  so the value lands in the hive of whichever account the elevated process runs as. `WebSearchOff` isn't
  `BestEffort`, so a failed write stops upstream's run.
- **Evidence for winfiles' choice:** with only the HKLM value set, Start's search showed no web results (test VM,
  build 26300, 2026-11-15). Nothing upstream or in Microsoft's documentation says Windows reads the HKLM value.
- **Alternative not taken:** upstream's pattern, the HKCU value set from the elevated system configuration.
  Under gsudo that's the same user's hive, so it would work on an administrator account. It was ruled out
  because it puts one user's state in the system configuration, which blurs the system/home split, and an
  over-the-shoulder elevation with another account's credentials would write that account's hive instead
  (upstream doesn't handle that case either).
- **Revisit:** if one account should keep web results, or if a Windows update stops honouring the HKLM value.
  `just check` wouldn't notice the second, since the value would still be there; Start would show web results
  again.
