# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Personal Windows 11 configuration management (a counterpart to the user's Linux/macOS dotfiles). It's a work in progress. There is no build and no test suite. "Testing" a change means running DSC `test`/`get` against the live machine.

## Commands

Bootstrap on a fresh Windows 11 install, from an unelevated terminal in the repo:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Install-Winfiles.ps1   # rerun after the restart just install asks for
```

`scripts/Install-Winfiles.ps1` runs under Windows PowerShell 5.1, since nothing else is installed yet, and refuses an elevated shell. Each step skips what's already done:

```powershell
winget install --id jdx.mise --exact --source winget --accept-package-agreements   # unless mise is installed
$env:Path = <machine Path>;<user Path>                       # this process only, so mise is found without a new terminal
mise trust; mise install                                     # mise.toml provides just, pwsh, gsudo and DSC
mise exec -- just install                                    # everything below, in order; the script exits with its code
```

`--source winget` keeps winget away from the `msstore` source, which on a fresh install stops to ask you to accept its terms (and sends your region).
`--accept-package-agreements` accepts mise's licence without a prompt. winget still asks for UAC to install the Visual C++ runtime that `jdx.mise` depends on.
Reloading `PATH` from the registry only changes the script's own process, which the `PATH` constraint allows. It can't help in the middle of `just install`: a process started before Scoop was installed never sees its shims.

`just install` runs these, in this order. Each one skips what's already done:

```powershell
gsudo --direct mise exec -- just wsl-install dsc-set-machine # private recipe `elevated`: one UAC prompt, same console
                                                             #   wsl-install: wsl --install --no-distribution; exits 3010 while a restart is pending
                                                             #   dsc-set-machine: just dsc config set --file dsc/winfiles.machine.dsc.yaml
mise exec -- just dsc config set --file dsc/winfiles.user.dsc.yaml   # unelevated; installs Scoop itself first
```

The elevated steps come first and share one gsudo call, so each run asks for UAC once, at the start, and the restart comes while someone is watching. Run on its own, `just wsl-install` elevates itself in a separate window instead. Nothing after the UAC prompt needs attention. `wsl-install` and `elevated` are `[no-exit-message]`, so a stop for a restart shows only the script's warning, not just's red "recipe failed" lines; a `dsc-set-machine` failure is still reported by the inner just. gsudo's credential cache (`gsudo cache on`) isn't used: just runs each recipe line in its own process, and the cache's per-process scope hasn't been checked against that.

mise (per-directory tools, like direnv): `mise.toml` holds the tools for the repo. Its pwsh is there because DSC needs pwsh before `pwsh.dsc.yaml` installs it: `scripts/Invoke-Dsc.ps1` runs under it, and `PowerShellScript` and the `Winfiles/*` resources are only discovered when `tryWhich('pwsh')` finds it. Inside the repo (under `mise exec` or `mise activate`) `pwsh` is mise's, not the winget one.

DSC also comes from `mise.toml`: the GitHub release, pinned (currently 3.3.0) because this file documents version-specific behaviour. Before bumping it, re-check that behaviour and re-time a whole-composition `test`, and rerun `just dsc-messages` (see `tests/dsc-messages/README.md`). Its `postinstall` deletes DSC's two discovery extensions (`Microsoft.Windows.Appx/Discover` and `Microsoft.PowerShell/Discover`), because DSC's settings have no switch for them: `dsc.settings.json` only covers `resourcePath` and `tracing`. The hook only runs when a version is installed, so after changing it run `mise install --force github:PowerShell/DSC`. `scripts/Invoke-Dsc.ps1` warns when the extensions are back.

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

just (recipes are `[windows]` only and run in pwsh):

```powershell
just                  # list recipes
just install          # clean install to dsc/winfiles.dsc.yaml (see above)
just wsl-install      # install WSL (scripts/Install-Wsl.ps1); skips if it's already set up
just test-vm <iso>    # Hyper-V VM with nested virtualization for testing `just install` (scripts/New-TestVm.ps1); skips if it exists
just test-vm <iso> -Unattended   # the same, with Windows already applied and OOBE answered
just test-vm-copy [name]          # copy the working tree into a running test VM's ~\src\winfiles (scripts/Copy-RepoToTestVm.ps1)
just test-vm-shell [name]         # PowerShell Direct session in a running test VM (scripts/Enter-TestVm.ps1)
just test-vm-run <name> <command> # run one command there, in ~\src\winfiles, and pass on its exit code
just dsc-messages <doc> [dsc args]   # watch how dsc shows resource messages, using dummy documents in tests/dsc-messages
```

`tests/dsc-messages/` is a visual check, run by hand, of how DSC shows lines a resource writes to stderr (levels, live output, Include nesting). Its README records the results per DSC version. Its stand-in resource `Test/SlowList` is outside `dsc/resources`, so `just dsc` never discovers it.

Test a clean install in that VM, not in Windows Sandbox: the Sandbox doesn't expose virtualization to its guest, so WSL2 can't run there, and it has no Store or winget. The script creates the VM and doesn't start it. It fixes the screen at 1920×1080 for basic `vmconnect` sessions (the VM's own console); an enhanced session (Remote Desktop over VMBus, with a shared clipboard) sizes it to the window. It prints the `Checkpoint-VM` and `Restore-VMCheckpoint` commands for taking a `clean` checkpoint after Windows setup and returning to it. Without `-Unattended` the VM boots the ISO into Windows Setup. With it, Setup is skipped: the script applies `Windows 11 Pro` from the ISO to the VHDX, runs `bcdboot`, and writes `Windows\Panther\unattend.xml`, which answers OOBE, creates a local administrator named after you, and signs it in automatically at every boot, so the bootstrap's restart needs no attention. The administrator's password is blank, and the specialize pass sets `LimitBlankPasswordUse` to 0, which by default limits blank passwords to the console. So a basic session opens on the desktop, an enhanced session signs in with one click on **Sign in**, and PowerShell Direct needs no password; a restart comes back by itself in either session (checked 2026-10-29 on 26300). The VM's notes record the administrator (`Local administrator: <user> / `, with nothing after the slash), and `scripts/testvm.ps1` reads them for the PowerShell Direct scripts. Trade-off: a blank-password administrator that accepts remote sign-ins, acceptable only because the VM is a throwaway behind the Default Switch's NAT; never do this on a real machine. It replaced a generated password kept in the notes, which every sign-in through an enhanced session made you type. The VM has no sleep states (`powercfg /a`), so it never asks to sign in on wake. The computer name defaults to the VM name, and Setup rejects one longer than 15 characters at first boot, so the script checks it up front; pass `-ComputerName` for a longer `-Name`. The VM stays unactivated, which doesn't affect winfiles.
`just test-vm-copy` packs the repo with `git archive` (by default the working tree: commits plus uncommitted changes to tracked files, through `git stash create`; untracked files are left out) and copies it in over PowerShell Direct, signing in with the administrator from the VM's notes (`-Credential` for a VM installed by hand). It replaces `~\src\winfiles` in the VM, so edits made inside the VM are lost.
PowerShell Direct sessions run elevated with no UAC, so run the bootstrap in the VM's desktop, and keep `test-vm-shell` and `test-vm-run` for reading results, such as `just test-vm-run <name> 'mise exec -- just dsc config test --file dsc/winfiles.dsc.yaml'`. Under them, Scoop's installer would refuse to run and the gsudo prompt would never show.

## Architecture

The state is described with DSC v3, and the root `justfile` drives it. The earlier just modules, exported winget/Scoop package lists and monolithic `modules.dsc.yml` were removed; git history has them.

- **DSC v3 under `dsc/`:** `dsc/winfiles.dsc.yaml` is the entry point for the whole state. It includes two halves, split by the privileges `set` needs. `winfiles.machine.dsc.yaml` (PowerShell, winget packages, Brave policies) needs an elevated shell. `winfiles.user.dsc.yaml` (Scoop packages, WSL) runs unelevated. The halves compose the documents under `dsc/` with `Microsoft.DSC/Include`. `just install` applies the halves separately, so ordering between them lives in the justfile, while `dependsOn` orders things inside each half. A `dependsOn` can't cross from one half to the other. Use the entry point for `test` and `get`. A `set` of it runs everything elevated, Scoop and WSL included.
  `configurationFile` paths resolve relative to the folder of the top-level document (the one passed to `--file`), so the composition works from any working directory. In DSC 3.3.0 (and 3.2.3) this also applies to nested Includes: they resolve from the top-level document's folder, not from the including file. The halves sit in `dsc/` next to the entry point, so their paths resolve the same way whether they run on their own or nested. Each Include starts another `dsc` process, but nesting the halves cost no measurable time (whole-composition `test` about 35s nested or flat, measured 2026-10-28).
  Add a new area as its own document under `dsc/<area>/` and include it from the half that matches what its `set` needs. A document that needs elevation for any of its resources goes in the machine half. `dsc/templates/` is reference material and is deliberately left out of the composition.
- **Packages:** `dsc/packages/winget.dsc.yaml` is a single document with one `Winfiles/WinGetPackageList` resource per category (libraries, runtimes, development, gaming, utilities, internet, productivity, media). Comments inside each list group the packages by purpose. Each resource checks its list with a single listing of installed packages, and it only installs: removing an id doesn't uninstall the package. To add a package, add its id under the right comment. A package that needs per-package options (`version`, `useLatest`) has to be a `Microsoft.WinGet/Package` resource instead. Packages that are managed elsewhere are left out: PowerShell (`pwsh.dsc.yaml`), DSC itself (`mise.toml`), WSL (`scripts/Install-Wsl.ps1`), IntelliJ IDEA (JetBrains Toolbox), Python and Meld (`scoop.dsc.yaml`), Discord (`scoop.dsc.yaml`: winget's installer starts Discord, which asks for UAC mid-run), and, installed by hand: Battle.net (its winget installer requires an install location, which neither the list nor `Microsoft.WinGet/Package` can pass), iCUE (its silent install hangs without Corsair hardware, and its installer hands off and exits, so winget reports success early) and LyX (it needs TeX Live, which winfiles doesn't install, first). The header of `winget.dsc.yaml` has the details.
- **Scoop:** `dsc/packages/scoop.dsc.yaml` follows the same pattern with `Winfiles/ScoopPackageList`. Entries are `name` or `bucket/name`, and the `buckets` parameter (name → repository URL) is passed to every list except `Core`. State comes from reading `apps/<name>/current/scoop-install.json` (`install.json` from older Scoop versions) and `buckets/<name>` under the Scoop root, not from running Scoop. `set` adds missing buckets, then makes one `scoop install` call for the missing apps. `Core` installs git with no buckets, and the other lists depend on it, because adding any bucket other than `main` needs git. Scoop finds git through its shims, so before calling Scoop the list puts `<root>\shims` on `PATH` for its own process: the `dsc` process of a fresh `just install` started before Scoop's installer added them to the user `PATH`. Scoop itself is installed by a separate resource, `Winfiles/Scoop`, the first in the document. `Core` depends on it, and the other lists follow through `Core`. Its `set` downloads and runs Scoop's own installer, and its only job is installing Scoop; buckets and apps stay with `Winfiles/ScoopPackageList`. The installer refuses an elevated shell, so the resource's `set` exits with 3 there instead of trying. That's why Scoop lives in the user half, and why a `set` of the whole `winfiles.dsc.yaml`, which runs elevated, fails on a machine without Scoop. If Scoop is still missing when a list's `set` runs, that list exits with 3 too. Both resources look up the Scoop root with `Get-ScoopRoot` from `dsc/resources/scooproot.ps1` (`$env:SCOOP`, then `root_path` in Scoop's config, then `~\scoop`), which their scripts dot-source.
- **WSL:** `dsc/wsl/wsl.dsc.yaml` writes `~/.wslconfig` and `~/.wslgconfig` from inline content (a script, since there's no built-in file resource; the content starts with a `Managed by winfiles` comment because DSC parses a string starting with `[` as an expression). It also installs NixOS-WSL with `Winfiles/WslDistribution` and makes it the default. It does only the Windows side: everything inside the distro (`wsl.*` options, `/etc/wsl.conf`, users) belongs to the NixOS configuration. The resource reads state from the `HKCU\...\Lxss` registration, never unregisters or moves a distribution, and `location` only applies at install time. WSL itself is installed before DSC runs, by `just wsl-install` (`scripts/Install-Wsl.ps1`). It runs `wsl --install --no-distribution`, which installs the WSL package and also enables VirtualMachinePlatform. The winget `Microsoft.WSL` package doesn't enable the feature. Enabling it needs a restart, which would interrupt a `dsc` run, and `Microsoft.Windows/OptionalFeatureList` needs elevation even for `get`. The script skips when WSL is already set up and elevates through UAC otherwise. Before installing a distribution, the resource checks through CIM that the feature is enabled and that WSL is 2.4.4 or later, and that no restart is pending, and exits with 3 if not. The script uses the same check, so keep the two in step.
  The pending restart is read from `Component Based Servicing\RebootPending`: right after `wsl --install`, before any restart, the feature already reads as enabled (CIM `InstallState` 1, `RestartNeeded` false on build 26300). The script exits with 3010 whenever that key is set, including after installing and when WSL is already set up, so `just install` stops before DSC. Trade-off: the key also covers Windows Update, so `just install` stops for a restart Windows Update is waiting on, even on a set-up machine. Installers such as `Microsoft.DotNet.Framework.DeveloperPack.4.6` refuse to run then anyway ("RebootPending = 0" bundle condition, seen in the test VM 2026-10-29). Revisit if that stops become a nuisance.
  `just wsl-install` runs the script under mise's pwsh 7, like every other recipe. It used to run under Windows PowerShell 5.1 so it would work before pwsh was installed, but the bootstrap now runs `mise install` first. 5.1 turned `wsl.exe`'s "not installed" on stderr into a fatal error, and this way the bootstrap recipes are less of a special case. The script keeps `#Requires -Version 5.1` and 5.1-compatible syntax, so it still runs by hand on a bare machine. Revisit if the bootstrap ever has to run before mise.
- **Custom resources:** these live in `dsc/resources/` as `*.dsc.resource.json` manifests plus scripts. `just dsc` makes them discoverable.

DSC document conventions (copy them from existing documents):

- Each document has the `$schema` (2023/08 document.json) and `metadata.winget.processor.identifier: dscv3` header, which keeps it usable with `winget configure`.
- Configurable paths and keys go in `parameters` with a `defaultValue`. Paths are stored with `%VAR%` placeholders and expanded inside scripts with `[Environment]::ExpandEnvironmentVariables`.
- Each resource has a `metadata.description`, and ordering is set with `dependsOn: "[resourceId('<type>', '<name>')]"`.
- Prefer DSC built-in resources (`Microsoft.Windows/Registry`, `Microsoft.WinGet/Package`, `Microsoft.DSC/Include`, ...) over scripts. Use `Microsoft.DSC.Transitional/PowerShellScript` only when no built-in can do the job, or one is broken. In that case, add a comment saying which built-in was ruled out and why. Pass the script's data through `input`, and make `getScript`/`testScript`/`setScript` idempotent (`testScript` returns a bool).

How `dsc/powershell/pwsh.dsc.yaml` works (this is the non-obvious part):

- PowerShell's CurrentUser install scope always writes to `Documents\PowerShell\{Modules,Scripts}`. The document points `PSModulePath` (in `powershell.config.json`) at `~/.local/share/powershell/Modules` and replaces both Documents folders with junctions to `~/.local/share/powershell/{Modules,Scripts}`, migrating existing contents and keeping clashes in `.bak` folders.
- With the junctions, the `PSModulePath` setting is redundant in effect. It's kept as a trade-off: `Documents` is redirected to OneDrive on this machine, and the setting keeps module loading off the junction inside it, so only installs go through it. The cost is that if the junction goes missing, CurrentUser installs land outside `PSModulePath`. Revisit if `Documents` stops being redirected (checked 2026-10-28).
- Modules are installed with `Save-PSResource` into that path, not through `PSResourceList`. The junction would make `PSResourceList` usable now, but PSResourceGet 1.2.0 (shipped with PowerShell 7.6.9) has no DSC manifest for it, and a version that has one would also need its folder on `DSC_RESOURCE_PATH`. `Save-PSResource -Path` doesn't depend on the junction existing.
- `$PROFILE` can't be relocated, so the default profile files become stubs (they start with `# Managed by winfiles (...)`) that repoint `$PROFILE` and dot-source `~/.config/powershell/`. `testScript` compares the stub text exactly, so editing the stub makes `test` report false until the next `set`.
- `Microsoft.PowerShell/Profile` is avoided because its `get` is broken (`JSON: EOF while parsing a value`). It ships with PowerShell, not DSC, and fails under both DSC 3.2.3 and 3.3.0.

## Constraints

- winfiles must never modify the persistent `PATH`. The pwsh profile (kept outside this repo) owns `PATH`, including the junctioned Scripts folder. Changing `PATH` for a single process inside a recipe is fine. A tool that winfiles drives may change the persistent `PATH` only if the user has approved that tool. So far Scoop (its installer, and manifests with `env_add_path` such as nodejs and python) and winget (package installs and uninstalls) are approved. Ask before relying on any other tool doing it.
- Commit messages use conventional commits plus gitmoji, scoped by area, for example `feat(dsc): ✨ ...`, `refactor(dsc): ♻️ ...`, `chore: 📝 ...`.
