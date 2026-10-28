# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Personal Windows 11 configuration management (a counterpart to the user's Linux/macOS dotfiles). It's a work in progress. There is no build and no test suite. "Testing" a change means running DSC `test`/`get` against the live machine.

## Commands

Bootstrap on a fresh Windows 11 install (`dsc-install` runs under Windows PowerShell 5.1, so pwsh isn't needed yet):

```powershell
winget install jdx.mise; mise trust; mise install            # mise.toml provides just
mise exec -- just dsc-install                                # winget/msstore first, GitHub zip fallback (-FromGitHub)
dsc config set --file .\dsc\powershell\pwsh.dsc.yaml         # PowerShell 7, modules, profile redirection
```

mise (per-directory tools, like direnv): `mise.toml` holds the tools for the repo. `mise.dsc.toml` adds the GitHub release of DSC only when that environment is selected (`mise -E dsc exec -- pwsh`, `just dsc-export-github`, and `just dsc-github`, which is `just dsc` with that release). This is because the Store package's `dism_dsc` can't export, and refuses to run at all ("not supported when installed via Appx"). Keep DSC out of `mise.toml`, otherwise `scripts/Install-Dsc.ps1` finds it and skips.

DSC (v3, `dsc` CLI). Run it through `just dsc` (`scripts/Invoke-Dsc.ps1`), which passes arguments to `dsc` after setting `DSC_RESOURCE_PATH` for that process only. The path covers DSC's install folder, App Installer's, `dsc/resources` (the `Winfiles/*` resources) and pwsh's folder, because `tryWhich` conditions search `DSC_RESOURCE_PATH`. This is how `Winfiles/*` resources are found. With the Store DSC 3.2.3 it also skips scanning all of `PATH` in every `dsc` process, which takes about 4.5s each time. DSC 3.3.0 (`just dsc-github`) saves no time this way: the discovery extensions in its folder (`Microsoft.Windows.Appx/Discover`, `Microsoft.PowerShell/Discover`) still find resources in Store packages and PowerShell modules, whatever `DSC_RESOURCE_PATH` says:

```powershell
just dsc config test --file dsc/winfiles.dsc.yaml            # whole composition; reports per-resource _inDesiredState
just dsc config test --file dsc/policies/brave.dsc.yaml      # one document on its own
just dsc config get  --file <doc>                            # current state
just dsc config set  --file <doc>                            # apply (HKLM resources need an elevated shell)
```

Run `test` before `set` and check the result. `set` changes the real machine: it installs packages, writes the registry, and rewrites profile stubs (keeping `.bak` copies).

just (the root `justfile` loads modules `system`, `scoop`, `winget` and `powershell`; recipes are `[windows]` only and run in pwsh):

```powershell
just                  # list recipes
just install          # powershell::install scoop::import winget::install
just winget::update   # re-export winget/winget.json, then strip JetBrains.IntelliJIDEA (installed via Toolbox)
just scoop::export    # re-export scoop/scoop.json (needs jq)
just system::setup    # system-wide tweaks (asks for confirmation, uses sudo)
```

## Architecture

There are two generations of tooling side by side:

- **Legacy, just-driven:** `winget/winget.json` and `scoop/scoop.json` are exported package lists that get reimported. `powershell.just` installs modules through `Install-Module` and copies a profile from `powershell/.config/powershell/`, but that directory isn't in this repo. The root `modules.dsc.yml` is an earlier, monolithic DSC attempt.
- **Current, DSC v3 under `dsc/`:** `dsc/winfiles.dsc.yaml` is the entry point. It composes the documents under `dsc/` with `Microsoft.DSC/Include`. `configurationFile` paths resolve relative to the folder of the top-level document (the one passed to `--file`), so the composition works from any working directory. In DSC 3.2.3 this also applies to nested Includes: they resolve from the top-level document's folder, not from the including file. Avoid nesting: each Include starts another `dsc` process. Add a new area as its own document under `dsc/<area>/` and include it from `winfiles.dsc.yaml`. `dsc/templates/` is reference material and is deliberately left out of the composition.
- **Packages:** `dsc/packages/winget.dsc.yaml` is a single document with one `Winfiles/WinGetPackageList` resource per category (libraries, runtimes, development, gaming, utilities, internet, productivity, media). Comments inside each list group the packages by purpose. Each resource checks its list with a single listing of installed packages, and it only installs: removing an id doesn't uninstall the package. To add a package, add its id under the right comment. A package that needs per-package options (`version`, `useLatest`) has to be a `Microsoft.WinGet/Package` resource instead. Packages that are managed elsewhere are left out: PowerShell and Oh My Posh (`pwsh.dsc.yaml`), DSC itself (`scripts/Install-Dsc.ps1`), and IntelliJ IDEA (JetBrains Toolbox).
- **WSL:** `dsc/wsl/wsl.dsc.yaml` writes `~/.wslconfig` and `~/.wslgconfig` from inline content (a script, since there's no built-in file resource; the content starts with a `Managed by winfiles` comment because DSC parses a string starting with `[` as an expression). It also installs NixOS-WSL with `Winfiles/WslDistribution` and makes it the default. It does only the Windows side: everything inside the distro (`wsl.*` options, `/etc/wsl.conf`, users) belongs to the NixOS configuration. The resource reads state from the `HKCU\...\Lxss` registration, never unregisters or moves a distribution, and `location` only applies at install time. `Microsoft.Windows/OptionalFeatureList` (VirtualMachinePlatform) is left out because it needs elevation even for `get`. Instead, before installing, the resource checks through CIM that the feature is enabled and that WSL is 2.4.4 or later, and exits with 3 if not. `dsc/wsl/features.dsc.yaml` enables the feature from an elevated shell, through `just dsc-github`, because the Store package's `dism_dsc` refuses to run. It isn't included in `winfiles.dsc.yaml` yet, and its header explains how to wire it in and make it a dependency of the WSL Include.
- **Custom resources:** these live in `dsc/resources/` as `*.dsc.resource.json` manifests plus scripts. `just dsc` makes them discoverable.

DSC document conventions (copy them from existing documents):

- Each document has the `$schema` (2023/08 document.json) and `metadata.winget.processor.identifier: dscv3` header, which keeps it usable with `winget configure`.
- Configurable paths and keys go in `parameters` with a `defaultValue`. Paths are stored with `%VAR%` placeholders and expanded inside scripts with `[Environment]::ExpandEnvironmentVariables`.
- Each resource has a `metadata.description`, and ordering is set with `dependsOn: "[resourceId('<type>', '<name>')]"`.
- Prefer DSC built-in resources (`Microsoft.Windows/Registry`, `Microsoft.WinGet/Package`, `Microsoft.DSC/Include`, ...) over scripts. Use `Microsoft.DSC.Transitional/PowerShellScript` only when no built-in can do the job, or one is broken. In that case, add a comment saying which built-in was ruled out and why. Pass the script's data through `input`, and make `getScript`/`testScript`/`setScript` idempotent (`testScript` returns a bool).

How `dsc/powershell/pwsh.dsc.yaml` works (this is the non-obvious part):

- PowerShell's CurrentUser install scope always writes to `Documents\PowerShell\{Modules,Scripts}`. The document points `PSModulePath` (in `powershell.config.json`) at `~/.local/share/powershell/Modules` and replaces both Documents folders with junctions to `~/.local/share/powershell/{Modules,Scripts}`, migrating existing contents and keeping clashes in `.bak` folders.
- Modules are installed with `Save-PSResource` into that path, not through `PSResourceList`.
- `$PROFILE` can't be relocated, so the default profile files become stubs (they start with `# Managed by winfiles (...)`) that repoint `$PROFILE` and dot-source `~/.config/powershell/`. `testScript` compares the stub text exactly, so editing the stub makes `test` report false until the next `set`.
- `Microsoft.PowerShell/Profile` is avoided because its `get` is broken in DSC 3.2.3.

## Constraints

- winfiles must never modify the persistent `PATH`. The pwsh profile (kept outside this repo) owns `PATH`, including the junctioned Scripts folder. Changing `PATH` for a single process inside a recipe is fine.
- Commit messages use conventional commits plus gitmoji, scoped by area, for example `feat(dsc): ✨ ...`, `refactor(dsc): ♻️ ...`, `chore: 📝 ...`.
- Untracked scratch files in the root (`current*.yaml`, `current.dyff`, `steps.md`, `New-Profile.ps1`) are the user's working notes and exports. Leave them alone and don't commit them.
