# Custom resources

The `Winfiles/*` resources live in `dsc/resources/` as `*.dsc.resource.json` manifests plus scripts, and `just dsc` makes them discoverable ([dev/tooling.md](../dev/tooling.md#just-dsc)). How to write one is in [dev/writing-resources.md](../dev/writing-resources.md), and how they're tested in [dev/resource-tests.md](../dev/resource-tests.md).

| Resource | What |
|---|---|
| `Winfiles.WinGet/Package` | `Microsoft.WinGet/Package` plus a stop-gap `_scope` ([winget.md](winget.md#winfileswingetpackage)) |
| `Winfiles/Scoop`, `Winfiles.Scoop/Bucket`, `Winfiles.Scoop/Package` | Scoop, a bucket, an app ([scoop.md](scoop.md)) |
| `Winfiles/Wsl`, `Winfiles/WslDistribution` | WSL and distributions ([wsl.md](wsl.md)) |
| `Winfiles/FileContentList` | whole text files from inline content, keeping a `.bak` of a file it replaces. `specialFolder` reaches folders that can be redirected, such as `MyDocuments` (OneDrive on iris), which `%USERPROFILE%` can't |
| `Winfiles/ComputerName` | the computer's name ([computer-name.md](computer-name.md)) |

## Conventions

- **Common code.** Each script dot-sources `common.ps1` in its `begin` block, which provides `Read-ResourceInput`, `Write-ResourceMessage`, `New-ResourceError` and `Exit-ResourceError`.
- **Input.** Each script is an advanced script: the operation is its first, positional parameter, and DSC's JSON arrives through a `ValueFromPipeline` parameter, since the manifest runs `$input | ./<script>.ps1 <operation>`. The `process` block collects the lines and the `end` block does the work.
- **Errors.** A failure throws `New-ResourceError` with the manifest's exit code for it; an unexpected error throws as it is, and exits 1. Each script declares its own `trap`, because a trap only covers the scope that declares it, even when dot-sourced, and the trap reports the error through `Exit-ResourceError`: as a JSON `error` line, since DSC shows neither plain stderr nor a failed resource's stderr ([reference](../reference/dsc.md#resource-messages-and-levels)). A failure writes no state.
- **Lists.** A list resource that can't apply an item fails, naming it, after applying the rest it can. DSC then stops the configuration there. `Winfiles/FileContentList` is the one list left; packages are a resource each.
- **`set` supports `-WhatIf`.** Each script has `SupportsShouldProcess`, and asks `ShouldProcess` before each change, so running it by hand with `-WhatIf` changes nothing. DSC never passes it.
- **Tools' output.** Output from Scoop and `wsl.exe` stays plain, so see it with `-l trace`. Trade-off: a failure names the package but not the tool's own explanation, which keeps a normal run readable. Revisit if failures keep needing `trace`.
