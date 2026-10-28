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

mise (per-directory tools, like direnv): `mise.toml` holds the tools for the repo. `mise.dsc.toml` adds the GitHub release of DSC only when that environment is selected (`mise -E dsc exec -- pwsh`, `just dsc-export-github`). This is because the Store package's `dism_dsc` can't export. Keep DSC out of `mise.toml`, otherwise `scripts/Install-Dsc.ps1` finds it and skips.

DSC (v3, `dsc` CLI):

```powershell
dsc config test --file .\dsc\winfiles.dsc.yaml               # whole composition; reports per-resource _inDesiredState
dsc config test --file .\dsc\policies\brave.dsc.yaml         # one document on its own
dsc config get  --file <doc>                                 # current state
dsc config set  --file <doc>                                 # apply (HKLM resources need an elevated shell)
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

- **Legacy, just-driven:** `winget/winget.json` and `scoop/scoop.json` are exported package lists that get reimported. `powershell.just` installs modules through `Install-Module` and copies a profile from `powershell/.config/powershell/`, but that directory isn't in this repo. The root `dsc.yaml` (a flat list of `Microsoft.WinGet/Package` resources) and `modules.dsc.yml` are earlier, monolithic DSC attempts.
- **Current, DSC v3 under `dsc/`:** `dsc/winfiles.dsc.yaml` is the entry point. It composes the documents under `dsc/` with `Microsoft.DSC/Include`. `configurationFile` paths resolve relative to the folder of the top-level document (the one passed to `--file`), so the composition works from any working directory. In DSC 3.2.3 this also applies to nested Includes: they resolve from the top-level document's folder, not from the including file. That's why the aggregators (`dsc/packages.dsc.yaml`) sit in `dsc/` next to `winfiles.dsc.yaml` and use `dsc/`-relative paths. Add a new area as its own document under `dsc/<area>/` and include it from `winfiles.dsc.yaml`. `dsc/templates/` is reference material and is deliberately left out of the composition.
- **Packages:** `dsc/packages.dsc.yaml` includes one aggregator per category, `dsc/packages/<category>.dsc.yaml` (libraries, runtimes, development, gaming, utilities, internet, productivity, media). Each aggregator sits next to its folder and includes the documents in it, and subfolders get their own aggregator (`runtimes/microsoft.dsc.yaml`). All of them use `dsc/`-relative paths. To add a package document, include it from its folder's aggregator. Packages that are managed elsewhere are left out: PowerShell and Oh My Posh (`pwsh.dsc.yaml`), DSC itself (`scripts/Install-Dsc.ps1`), and IntelliJ IDEA (JetBrains Toolbox).

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
