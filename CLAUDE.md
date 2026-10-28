# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Personal Windows 11 configuration management (a counterpart to the user's Linux/macOS dotfiles). It's a work in progress. There is no build and no test suite. "Testing" a change means running DSC `test`/`get` against the live machine.

## Commands

Bootstrap on a fresh Windows 11 install, from an unelevated terminal:

```powershell
winget install jdx.mise; mise trust; mise install            # mise.toml provides just, pwsh, gsudo and DSC
mise exec -- just install                                    # everything below, in order; rerun after the restart it asks for
```

`just install` runs these, in this order. Each one skips what's already done (`wsl-install` runs under Windows PowerShell 5.1):

```powershell
gsudo --direct mise exec -- just wsl-install dsc-set-machine # private recipe `elevated`: one UAC prompt, same console
                                                             #   wsl-install: wsl --install --no-distribution; exits 3010 until you restart
                                                             #   dsc-set-machine: just dsc config set --file dsc/winfiles.machine.dsc.yaml
mise exec -- just dsc config set --file dsc/winfiles.user.dsc.yaml   # unelevated; installs Scoop itself first
```

The elevated steps come first and share one gsudo call, so each run asks for UAC once, at the start, and the restart comes while someone is watching. Run on its own, `just wsl-install` elevates itself in a separate window instead. Nothing after the UAC prompt needs attention. gsudo's credential cache (`gsudo cache on`) isn't used: just runs each recipe line in its own process, and the cache's per-process scope hasn't been checked against that.

mise (per-directory tools, like direnv): `mise.toml` holds the tools for the repo. Its pwsh is there because DSC needs pwsh before `pwsh.dsc.yaml` installs it: `scripts/Invoke-Dsc.ps1` runs under it, and `PowerShellScript` and the `Winfiles/*` resources are only discovered when `tryWhich('pwsh')` finds it. Inside the repo (under `mise exec` or `mise activate`) `pwsh` is mise's, not the winget one.

DSC also comes from `mise.toml`: the GitHub release, pinned (currently 3.3.0) because this file documents version-specific behaviour. Before bumping it, re-check that behaviour and re-time a whole-composition `test`. Its `postinstall` deletes DSC's two discovery extensions (`Microsoft.Windows.Appx/Discover` and `Microsoft.PowerShell/Discover`), because DSC's settings have no switch for them: `dsc.settings.json` only covers `resourcePath` and `tracing`. The hook only runs when a version is installed, so after changing it run `mise install --force github:PowerShell/DSC`. `scripts/Invoke-Dsc.ps1` warns when the extensions are back.

Using mise's DSC rather than the Store package is a trade-off, not a rule. It was measured on 2026-10-28; reconsider it when either version changes:

- **Speed:** with the extensions, each `dsc` process spent about 0.8s in the PowerShell one, which found nothing, and about 2.5s in the Appx one. Every Include starts another `dsc` process, so this repeats. A whole-composition `test` took about 34s under mise's 3.3.0 without extensions, about 41s under the Store 3.2.3, and about 91s under 3.3.0 with them.
- **Maintenance:** there is one way to install DSC, with no Store install script, second mise environment or duplicate `*-github` recipes. The version is pinned in the repo instead of updated by the Store. The Store package's `dism_dsc` also refuses to run ("not supported when installed via Appx").
- **Clarity:** only one version needs documenting. With the extensions, a run could also mix in resources from another installed DSC: the Appx extension found the Store DSC's own `Include`, `PowerShellScript` and `Registry`.
- **Cost:** resources that exist only inside Store packages aren't discovered, so `just dsc-export` no longer exports `OhMyPosh/*`. winfiles' documents use none of them, and export is a nice-to-have of uncertain use, outside the project's main focus, so this weighs little. A machine may still have the Store DSC (`9NVTPZWRC6KQ`) installed. It isn't on `DSC_RESOURCE_PATH`, and under `mise exec` mise's `dsc` comes first on `PATH`.

DSC (v3, `dsc` CLI). Run it through `just dsc` (`scripts/Invoke-Dsc.ps1`), which passes arguments to `dsc` after setting `DSC_RESOURCE_PATH` for that process only. The path covers DSC's install folder, App Installer's (`Microsoft.WinGet/*`) and `dsc/resources` (the `Winfiles/*` resources). This is how `Winfiles/*` resources are found, and it stops every `dsc` process from scanning all of `PATH` for manifests. `tryWhich` conditions, such as `pwsh` and `sshd`, still search `PATH`. `just dsc-export` (`scripts/Export-DscResource.ps1`) runs `dsc` the same way. It writes the current state of every exportable resource to `exports/`. It's a nice-to-have, not part of applying the configuration, so don't let it drive design decisions:

```powershell
just dsc config test --file dsc/winfiles.dsc.yaml            # whole composition; reports per-resource _inDesiredState
just dsc config test --file dsc/winfiles.user.dsc.yaml       # one half (or winfiles.machine.dsc.yaml)
just dsc config test --file dsc/policies/brave.dsc.yaml      # one document on its own
just dsc config get  --file <doc>                            # current state
just dsc config set  --file <doc>                            # apply (HKLM resources need an elevated shell)
```

Run `test` before `set` and check the result. `set` changes the real machine: it installs packages, writes the registry, and rewrites profile stubs (keeping `.bak` copies).

just (recipes are `[windows]` only and run in pwsh, except the bootstrap recipes, which run as Windows PowerShell 5.1 scripts):

```powershell
just                  # list recipes
just install          # clean install to dsc/winfiles.dsc.yaml (see above)
just wsl-install      # install WSL (scripts/Install-Wsl.ps1); skips if it's already set up
```

## Architecture

There are two generations of tooling side by side:

- **Legacy, just-driven:** the root `justfile` no longer loads these modules (`system.just`, `scoop/`, `winget/`, `powershell.just`). `winget/winget.json` and `scoop/scoop.json` are exported package lists that get reimported. `powershell.just` installs modules through `Install-Module` and copies a profile from `powershell/.config/powershell/`, but that directory isn't in this repo. The root `modules.dsc.yml` is an earlier, monolithic DSC attempt.
- **Current, DSC v3 under `dsc/`:** `dsc/winfiles.dsc.yaml` is the entry point for the whole state. It includes two halves, split by the privileges `set` needs. `winfiles.machine.dsc.yaml` (PowerShell, winget packages, Brave policies) needs an elevated shell. `winfiles.user.dsc.yaml` (Scoop packages, WSL) runs unelevated. The halves compose the documents under `dsc/` with `Microsoft.DSC/Include`. `just install` applies the halves separately, so ordering between them lives in the justfile, while `dependsOn` orders things inside each half. A `dependsOn` can't cross from one half to the other. Use the entry point for `test` and `get`. A `set` of it runs everything elevated, Scoop and WSL included.
  `configurationFile` paths resolve relative to the folder of the top-level document (the one passed to `--file`), so the composition works from any working directory. In DSC 3.3.0 (and 3.2.3) this also applies to nested Includes: they resolve from the top-level document's folder, not from the including file. The halves sit in `dsc/` next to the entry point, so their paths resolve the same way whether they run on their own or nested. Each Include starts another `dsc` process, but nesting the halves cost no measurable time (whole-composition `test` about 35s nested or flat, measured 2026-10-28).
  Add a new area as its own document under `dsc/<area>/` and include it from the half that matches what its `set` needs. A document that needs elevation for any of its resources goes in the machine half. `dsc/templates/` is reference material and is deliberately left out of the composition.
- **Packages:** `dsc/packages/winget.dsc.yaml` is a single document with one `Winfiles/WinGetPackageList` resource per category (libraries, runtimes, development, gaming, utilities, internet, productivity, media). Comments inside each list group the packages by purpose. Each resource checks its list with a single listing of installed packages, and it only installs: removing an id doesn't uninstall the package. To add a package, add its id under the right comment. A package that needs per-package options (`version`, `useLatest`) has to be a `Microsoft.WinGet/Package` resource instead. Packages that are managed elsewhere are left out: PowerShell and Oh My Posh (`pwsh.dsc.yaml`), DSC itself (`mise.toml`), WSL (`scripts/Install-Wsl.ps1`), IntelliJ IDEA (JetBrains Toolbox), and Python and Meld (`scoop.dsc.yaml`).
- **Scoop:** `dsc/packages/scoop.dsc.yaml` follows the same pattern with `Winfiles/ScoopPackageList`. Entries are `name` or `bucket/name`, and the `buckets` parameter (name → repository URL) is passed to every list except `Core`. State comes from reading `apps/<name>/current/scoop-install.json` (`install.json` from older Scoop versions) and `buckets/<name>` under the Scoop root, not from running Scoop. `set` adds missing buckets, then makes one `scoop install` call for the missing apps. `Core` installs git with no buckets, and the other lists depend on it, because adding any bucket other than `main` needs git. Scoop itself is installed by a separate resource, `Winfiles/Scoop`, the first in the document. `Core` depends on it, and the other lists follow through `Core`. Its `set` downloads and runs Scoop's own installer, and its only job is installing Scoop; buckets and apps stay with `Winfiles/ScoopPackageList`. The installer refuses an elevated shell, so the resource's `set` exits with 3 there instead of trying. That's why Scoop lives in the user half, and why a `set` of the whole `winfiles.dsc.yaml`, which runs elevated, fails on a machine without Scoop. If Scoop is still missing when a list's `set` runs, that list exits with 3 too. Both resources look up the Scoop root with `Get-ScoopRoot` from `dsc/resources/scooproot.ps1` (`$env:SCOOP`, then `root_path` in Scoop's config, then `~\scoop`), which their scripts dot-source. Don't rely on the legacy just modules (`scoop/`, `winget/`, `powershell.just`, `system.just`) or their exported lists in new code. Read them only to gather information.
- **WSL:** `dsc/wsl/wsl.dsc.yaml` writes `~/.wslconfig` and `~/.wslgconfig` from inline content (a script, since there's no built-in file resource; the content starts with a `Managed by winfiles` comment because DSC parses a string starting with `[` as an expression). It also installs NixOS-WSL with `Winfiles/WslDistribution` and makes it the default. It does only the Windows side: everything inside the distro (`wsl.*` options, `/etc/wsl.conf`, users) belongs to the NixOS configuration. The resource reads state from the `HKCU\...\Lxss` registration, never unregisters or moves a distribution, and `location` only applies at install time. WSL itself is installed before DSC runs, by `just wsl-install` (`scripts/Install-Wsl.ps1`, Windows PowerShell 5.1). It runs `wsl --install --no-distribution`, which installs the WSL package and also enables VirtualMachinePlatform. The winget `Microsoft.WSL` package doesn't enable the feature. Enabling it needs a restart, which would interrupt a `dsc` run, and `Microsoft.Windows/OptionalFeatureList` needs elevation even for `get`. The script skips when WSL is already set up and elevates through UAC otherwise. Before installing a distribution, the resource checks through CIM that the feature is enabled and that WSL is 2.4.4 or later, and exits with 3 if not. The script uses the same check, so keep the two in step.
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
- `Microsoft.PowerShell/Profile` is avoided because its `get` is broken (`JSON: EOF while parsing a value`). It ships with PowerShell, not DSC, and fails under both DSC 3.2.3 and 3.3.0.

## Constraints

- winfiles must never modify the persistent `PATH`. The pwsh profile (kept outside this repo) owns `PATH`, including the junctioned Scripts folder. Changing `PATH` for a single process inside a recipe is fine. A tool that winfiles drives may change the persistent `PATH` only if the user has approved that tool. So far Scoop (its installer, and manifests with `env_add_path` such as nodejs and python) and winget (package installs and uninstalls) are approved. Ask before relying on any other tool doing it.
- Commit messages use conventional commits plus gitmoji, scoped by area, for example `feat(dsc): ✨ ...`, `refactor(dsc): ♻️ ...`, `chore: 📝 ...`.
- Untracked scratch files in the root (`current*.yaml`, `current.dyff`, `steps.md`, `New-Profile.ps1`) are the user's working notes and exports. Leave them alone and don't commit them.
