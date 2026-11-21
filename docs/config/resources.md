# Custom resources

The `Winfiles/*` resources live in `dsc/resources/` as `*.dsc.resource.json` manifests plus scripts, and `just dsc` makes them discoverable ([dev/tooling.md](../dev/tooling.md#just-dsc)). How they're tested is in [dev/resource-tests.md](../dev/resource-tests.md).

| Resource | What |
|---|---|
| `Winfiles.WinGet/Package` | `Microsoft.WinGet/Package` plus a stop-gap `_scope` ([winget.md](winget.md#winfileswingetpackage)) |
| `Winfiles/Scoop`, `Winfiles/ScoopPackageList` | Scoop and its buckets and apps ([scoop.md](scoop.md)) |
| `Winfiles/Wsl`, `Winfiles/WslDistribution` | WSL and distributions ([wsl.md](wsl.md)) |
| `Winfiles/FileContentList` | whole text files from inline content, keeping a `.bak` of a file it replaces. `specialFolder` reaches folders that can be redirected, such as `MyDocuments` (OneDrive on iris), which `%USERPROFILE%` can't |
| `Winfiles/ComputerName` | the computer's name ([computer-name.md](computer-name.md)) |

## Conventions

- **Common code.** Each script dot-sources `common.ps1`, which sets the preferences and provides `Read-ResourceInput` and `Write-ResourceMessage`.
- **No `[CmdletBinding()]` or `[Parameter()]`,** so `$input` can hold the JSON from stdin.
- **Errors.** DSC logs plain stderr lines only at `trace`, so a failure has to go through `Write-ResourceMessage error`. Each script declares its own `trap` for uncaught errors, because a trap only covers the scope that declares it, even when dot-sourced.
- **Lists.** A list resource keeps an item that fails in its `missing` property and still exits 0, because DSC stops the whole configuration when a resource exits non-zero.
- **Tools' output.** Output from Scoop and `wsl.exe` stays plain, so see it with `-l trace`. Trade-off: a failure names the package but not the tool's own explanation, which keeps a normal run readable. Revisit if failures keep needing `trace`.
