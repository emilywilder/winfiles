# Drift from upstream

Where a winfiles setting was taken from another project and is now done differently on purpose. Each entry
names the upstream file at a pinned commit, what each side does, the evidence, and when to revisit. A plain
"taken from" with no difference stays as a comment beside the setting and isn't listed here.

## Sources

| Source | Pinned at | Used for |
| --- | --- | --- |
| [microsoft/WindowsDeveloperConfig](https://github.com/microsoft/WindowsDeveloperConfig) | `e4921dde0704380e8a61eef367cf0347b192bbdb` | Taskbar, Start, Search, Explorer and Widgets registry settings in `dsc/modules/{home,system}/settings.dsc.yaml` |

## Entries

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
