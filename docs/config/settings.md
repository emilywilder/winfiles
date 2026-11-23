# Settings and policies

Registry settings and policies. Each setting's reason is the comment beside it in its document; this doc covers what's where, and where a setting deliberately differs from its source.

| Document | Entry | What |
|---|---|---|
| `modules/system/settings.dsc.yaml` | system | machine-wide settings: the file system, Widgets, Explorer policies, Sudo for Windows, Developer Mode, UTF-8 as the system code page, `msstore` made explicit, Microsoft Update |
| `modules/home/settings.dsc.yaml` | home | the user's File Explorer, taskbar, Search, theme and title bar |
| `modules/system/policies.dsc.yaml` | system | Brave's and Edge's machine policies |

Several values in a document go in one `Microsoft.Windows/RegistryList`, which also creates their keys. Trade-off: a drifted value reports the whole list as false, so finding which one means reading `actualState`. Revisit if that gets in the way.

Many settings are taken from Microsoft's [WindowsDeveloperConfig](https://github.com/microsoft/WindowsDeveloperConfig), pinned at `e4921dde0704380e8a61eef367cf0347b192bbdb`, and say so in their comments.

## Drift from upstream

### Web results in Start: `DisableSearchBoxSuggestions`

Checked 2026-11-15.

- **winfiles:** `HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer`, DWord 1, in `modules/system/settings.dsc.yaml`. Applies to every account on the machine.
- **Upstream:** `HKCU\SOFTWARE\Policies\Microsoft\Windows\Explorer`, DWord 1, written from an elevated process ([`steps/registry-taskbar-search.ps1`](https://github.com/microsoft/WindowsDeveloperConfig/blob/e4921dde0704380e8a61eef367cf0347b192bbdb/src/windows-dev-config/steps/registry-taskbar-search.ps1#L37), step `WebSearchOff`). HKCU is where the ADMX defines this policy, for users only. `dev-config.ps1` relaunches itself elevated (`Invoke-DevConfigElevate`) unless it already is, and then writes `HKCU:\` directly, so the value lands in the hive of whichever account the elevated process runs as.
- **Why they differ:** an unelevated process can only read `HKCU\Software\Policies`, so the unelevated home configuration failed with "Registry error" on a new install (test VM, 2026-11-15).
- **Evidence:** with only the HKLM value set, Start's search showed no web results (test VM, build 26300, 2026-11-15). Nothing upstream or in Microsoft's documentation says Windows reads the HKLM value.
- **Not taken:** upstream's pattern, the HKCU value set from the elevated system configuration. Under gsudo that's the same user's hive, so it would work on an administrator account, but it puts one user's state in the system configuration, and an over-the-shoulder elevation with another account's credentials would write that account's hive instead.
- **Revisit:** if one account should keep web results, or if a Windows update stops honouring the HKLM value. `winfiles.ps1 check` wouldn't notice the second, since the value would still be there; Start would show web results again.
