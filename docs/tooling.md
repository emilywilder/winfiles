# Tooling

Where the tools winfiles runs on come from (mise, its lock, DSC), how DSC is run, and the recipes.

mise (per-directory tools, like direnv): `mise.toml` holds the tools for the repo, and `mise.lock` (Windows x64 only, `mise lock --platform windows-x64`) the exact version, download URL and checksum behind each, so every install gets the same tools. mise refuses an install that doesn't match the lock. `just`, `powershell` and `gsudo` stay `latest` in `mise.toml` and only move when `mise lock --bump` is run; after changing a request in `mise.toml`, run `mise lock`. Its pwsh is there because DSC needs pwsh before `modules/system/powershell.dsc.yaml` installs it: `scripts/Invoke-Dsc.ps1` runs under it, and `PowerShellScript` and the `Winfiles/*` resources are only discovered when `tryWhich('pwsh')` finds it. Inside the repo (under `mise exec` or `mise activate`) `pwsh` is mise's, not the winget one.

DSC also comes from `mise.toml`: the GitHub release, pinned (currently 3.3.0) because these docs record version-specific behaviour. Before bumping it, re-check that behaviour and re-time `just check`, and rerun `just dsc-messages` in `demos/` (see `demos/dsc-messages/README.md`). Its `postinstall` deletes DSC's two discovery extensions (`Microsoft.Windows.Appx/Discover` and `Microsoft.PowerShell/Discover`), because DSC's settings have no switch for them: `dsc.settings.json` only covers `resourcePath` and `tracing`. The hook only runs when a version is installed, so after changing it run `mise install --force github:PowerShell/DSC`. `scripts/Invoke-Dsc.ps1` warns when the extensions are back.

Using mise's DSC rather than the Store package is a trade-off, not a rule. It was measured on 2026-10-28; reconsider it when either version changes:

- **Speed:** with the extensions, each `dsc` process spent about 0.8s in the PowerShell one, which found nothing, and about 2.5s in the Appx one. Every Include starts another `dsc` process, so this repeats. A whole-composition `test` took about 34s under mise's 3.3.0 without extensions, about 41s under the Store 3.2.3, and about 91s under 3.3.0 with them.
- **Maintenance:** there is one way to install DSC, with no Store install script, second mise environment or duplicate `*-github` recipes. The version is pinned in the repo instead of updated by the Store. The Store package's `dism_dsc` also refuses to run ("not supported when installed via Appx").
- **Clarity:** only one version needs documenting. With the extensions, a run could also mix in resources from another installed DSC: the Appx extension found the Store DSC's own `Include`, `PowerShellScript` and `Registry`.
- **Cost:** resources that exist only inside Store packages aren't discovered, so `just dsc-export` no longer exports `OhMyPosh/*`. winfiles' documents use none of them, and export is a nice-to-have of uncertain use, outside the project's main focus, so this weighs little. A machine may still have the Store DSC (`9NVTPZWRC6KQ`) installed. It isn't on `DSC_RESOURCE_PATH`, and under `mise exec` mise's `dsc` comes first on `PATH`. Without mise (plain `just dsc` from a shell that hasn't activated it) the Store's `dsc` comes first, and 3.2.3 from there doesn't find the `Winfiles/*` resources ("Resource not found", seen 2026-11-14), so `scripts/Invoke-Dsc.ps1` refuses a `dsc` under a `WindowsApps` folder and says to use `mise exec`.

DSC (v3, `dsc` CLI). Run it through `just dsc` (`scripts/Invoke-Dsc.ps1`), which passes arguments to `dsc` after setting `DSC_RESOURCE_PATH` for that process only. The path covers DSC's install folder, App Installer's (`Microsoft.WinGet/*`), the PSResourceGet module bundled with the pwsh running the script (`Microsoft.PowerShell.PSResourceGet/*`, only when it has DSC manifests, which pwsh 7.7.0's 1.3.1 does) and `dsc/resources` (the `Winfiles/*` resources). The recipes run it under mise's pwsh, which is also the `pwsh` on `PATH` that DSC starts for the PSResourceGet resources, so the two match. This is how `Winfiles/*` resources are found, and it stops every `dsc` process from scanning all of `PATH` for manifests. `tryWhich` conditions, such as `pwsh` and `sshd`, still search `PATH`. `just dsc-export` (`scripts/Export-DscResource.ps1`) runs `dsc` the same way. It writes the current state of every exportable resource to `exports/`. It's a nice-to-have, not part of applying the configuration, so don't let it drive design decisions:

```powershell
just check [host] [user]                                     # both configurations; lists what's missing and exits 1 if anything is
just dsc config test --file dsc/iris.system.dsc.yaml         # one configuration, as full JSON (or dsc/emily@iris.home.dsc.yaml)
just dsc config test --file dsc/modules/system/policies.dsc.yaml   # one module on its own
just dsc config get  --file <doc>                            # current state
just dsc config set  --file <doc>                            # apply (HKLM resources need an elevated shell)
```

`dsc config test` exits 0 whatever it finds, so a script has to read its results, not its exit code; `scripts/Test-Winfiles.ps1` does that for `just check`. Run `test` before `set` and check the result. `set` changes the real machine: it installs packages, writes the registry, and rewrites profile stubs (keeping `.bak` copies).

just (recipes are `[windows]` only and run in pwsh, without the profile, which cost about 5s per recipe line on iris against 0.47s; a recipe that comes to need something from the profile has to set it up itself):

```powershell
just                  # list recipes
just help <recipe>    # a recipe's usage (just --usage <recipe>), plus Get-Help for the scripts its *args go to (scripts/Show-RecipeHelp.ps1)
just install [host] [user]   # clean install to a host's system and home configurations (docs/install.md)
just system [host]           # apply the system configuration (elevates)
just home [user] [host]      # apply the home configuration (unelevated)
just check [host] [user]     # test both configurations; exits 1 if anything is missing
just flat=false check ...    # the same through the entries themselves, Includes and all (also system, home, install)
just post-install [host]     # show what a host still needs done by hand after an install
just scoop-notes             # show the notes of installed Scoop apps, for review
just hosts                   # list the configurations in dsc/
just manual [host]           # download the installers of what a host installs by hand and is missing
just install-rebuild [dir]   # write winfiles-rebuild (default: ~/bin), which runs this checkout's recipes from any directory
just test [paths]            # run the Pester tests (default: tests); changes nothing on the machine
just test-vm <iso>    # Hyper-V VM with nested virtualization for testing `just install` (scripts/New-TestVm.ps1); skips if it exists
just test-vm <iso> -Unattended   # the same, with Windows already applied and OOBE answered
just test-vm-copy [name]          # copy the working tree into a running test VM's ~\src\winfiles (scripts/Copy-RepoToTestVm.ps1)
just test-vm-shell [name]         # PowerShell Direct session in a running test VM (scripts/Enter-TestVm.ps1)
just test-vm-run <name> <command> # run one command there, in ~\src\winfiles, and pass on its exit code
just test-vm-log [name] [-Tail <lines>] [-All]   # follow a running test VM's run.log, and with -All winget's and the installers' logs (scripts/Watch-TestVmLog.ps1)
```

`just install-rebuild` (`scripts/Install-Rebuild.ps1`) writes `winfiles-rebuild.ps1`, the counterpart of pointing `nixos-rebuild` at a flake directory: `winfiles-rebuild check` is `just check` in the checkout, from any directory, and with no arguments it lists the recipes. The checkout's path is written into the script, and rerunning from another checkout repoints it. It refuses to replace a file that doesn't start with its `# Managed by winfiles` marker, though it replaces an empty one. It runs `mise -C <repo> exec -- just --justfile <repo>\justfile`, so `just` comes from `mise.toml` without `mise activate`, and the recipes then clean the environment as usual. Only `mise` has to be on `PATH`. The recipe doesn't add the folder to `PATH` (see Constraints), and `just install` doesn't run it. Trade-off: a path fixed at write time, so moving the checkout means rerunning it (the script says so), rather than a lookup that would need its own config. Revisit if checkouts start moving often.
