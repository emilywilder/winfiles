# Tooling

Where the tools winfiles runs on come from (mise, its lock, DSC), how DSC is run, and the commands. Facts about DSC are in [reference/dsc.md](../reference/dsc.md), and timings are in [benchmarks.md](../benchmarks.md).

## mise

`mise.toml` holds the repo's tools, and `mise.lock` holds the exact version, download URL and checksum behind each one (Windows x64 only: `mise lock --platform windows-x64`). So every install gets the same tools, and mise refuses one that doesn't match the lock.

- `just`, `powershell` and `gsudo` stay `latest` in `mise.toml`, and only move when `mise lock --bump` is run.
- After changing a request in `mise.toml`, run `mise lock`.
- mise provides pwsh because DSC needs one before `modules/system/powershell.dsc.yaml` installs PowerShell: `scripts/Invoke-Dsc.ps1` runs under it, and `PowerShellScript` and the `Winfiles/*` resources are only discovered when DSC finds a pwsh. Inside the repo, under `mise exec` or `mise activate`, `pwsh` is mise's, not the winget one.

## DSC

DSC also comes from `mise.toml`: the GitHub release, pinned (3.3.0), because `reference/dsc.md` records version-specific behaviour. Before bumping it:
1. Recheck the entries in `reference/dsc.md`.
2. Re-time `just check`.
3. Rerun `just dsc-messages` in `demos/` (`demos/dsc-messages/README.md`).

Its `postinstall` deletes DSC's two discovery extensions, since DSC's settings have no switch for them ([reference](../reference/dsc.md#discovery)). The hook only runs when a version is installed, so after changing it, run `mise install --force github:PowerShell/DSC`. `scripts/Invoke-Dsc.ps1` warns when the extensions are back.

Trade-off: mise's DSC without the extensions, rather than the Store package.
- **Faster:** the extensions cost each `dsc` process about 3.3s ([benchmarks](../benchmarks.md#dsc-discovery)).
- **One way to install it,** pinned in the repo instead of updated by the Store, so only one version needs documenting, and no run mixes in another DSC's resources.
- **The cost:** resources that exist only inside Store packages aren't discovered, so `just dsc-export` no longer exports `OhMyPosh/*`. winfiles' documents use none of them.

Revisit when either version changes.

A machine may still have the Store DSC installed. Under `mise exec`, mise's `dsc` comes first on `PATH`; without mise, the Store's would, so `Invoke-Dsc.ps1` refuses a `dsc` under `WindowsApps` and says to use `mise exec` ([reference](../reference/dsc.md#the-store-package)).

### just dsc

`just dsc <args>` (`scripts/Invoke-Dsc.ps1`) runs `dsc` after setting `DSC_RESOURCE_PATH` for that process only. The path covers:
- DSC's install folder;
- App Installer's (`Microsoft.WinGet/*`);
- the PSResourceGet module bundled with the running pwsh (`Microsoft.PowerShell.PSResourceGet/*`), when it has DSC manifests, as pwsh 7.7.0's 1.3.1 does;
- `dsc/resources` (`Winfiles/*`).

That's how the `Winfiles/*` resources are found, and it stops every `dsc` process scanning all of `PATH` for manifests. The commands run it under mise's pwsh, which is also the `pwsh` DSC starts for the PSResourceGet resources, so the two match.

```powershell
just dsc config test --file dsc/iris.system.dsc.yaml               # one configuration, as full JSON
just dsc config test --file dsc/modules/system/policies.dsc.yaml   # one module on its own
just dsc config get  --file <doc>                                  # current state
just dsc config set  --file <doc>                                  # apply (HKLM resources need an elevated shell)
```

`dsc config test` exits 0 whatever it finds, so a script has to read its results; `scripts/Test-Winfiles.ps1` does that for `just check`. Run `test` before `set`, since `set` changes the real machine: it installs packages, writes the registry, and rewrites profile stubs (keeping `.bak` copies).

`just dsc-export` (`scripts/Export-DscResource.ps1`) writes the current state of every exportable resource to `exports/`. It's a nice-to-have, not part of applying the configuration, so don't let it drive design decisions.

## Recipes

Recipes are `[windows]` only, and run in pwsh without the profile, which is much faster ([benchmarks](../benchmarks.md#recipes-without-the-profile)). A recipe that comes to need something from the profile has to set it up itself. `just` lists them, and `just help <recipe>` shows a recipe's arguments plus the help of the scripts its `*args` go to.

| Command | What |
|---|---|
| `install [host] [user]` | a clean install of a host's system and home configurations ([install.md](../install.md)) |
| `system [host]`, `home [user] [host]` | apply one configuration; `system` elevates, `home` runs unelevated from either kind of shell |
| `check [host] [user]` | test both configurations, with one total; exits 1 if anything is missing (elevates) |
| `post-install [host] [user]` | what a host and its user still need done by hand |
| `manual [host]` | download the installers of what a host installs by hand and is missing |
| `scoop-notes` | the notes of installed Scoop apps, for review |
| `hosts` | the configurations in `dsc/` |
| `install-rebuild [dir]` | write `winfiles-rebuild` (below) |
| `test [paths]` | the Pester tests ([testing.md](testing.md)) |
| `test-vm`, `test-vm-copy`, `test-vm-shell`, `test-vm-run`, `test-vm-unelevated`, `test-vm-log` | the test VM ([test-vm.md](test-vm.md)) |
| `dsc`, `flatten`, `dsc-export` | DSC by hand (above), and the flat copy ([flat-configuration.md](../run/flat-configuration.md)) |

### winfiles.ps1

`winfiles.ps1` at the repo root runs the same commands without `just`. `install.cmd`, the bootstrap's check and `winfiles-rebuild` call it; the justfile stays for running commands by hand until it's removed. The commands are data, in `commands.jsonc` (JSON with comments, which `ConvertFrom-Json` reads, [reference](../reference/windows.md#convertfrom-json-and-comments)), and its header lists the fields. The runner is `scripts/commands.ps1`. It checks the files the whole plan requires before anything runs. It goes through `Invoke-Clean.ps1` once per run, rather than once per recipe line, and through `Invoke-AsAdmin.ps1` once, as `winfiles.ps1 --run <command>`, rather than a nested `just`. It exits with the first failing script's code, unchanged. `tests/scripts/Commands.Tests.ps1` checks that every public recipe has a command with the same parameters, until the justfile goes.

### winfiles-rebuild

`just install-rebuild` (`scripts/Install-Rebuild.ps1`) writes `winfiles-rebuild.ps1`, the counterpart of pointing `nixos-rebuild` at a flake directory. `winfiles-rebuild check` is `./winfiles.ps1 check` in the checkout, from any directory; with no arguments, it lists the commands.

- It runs `mise -C <repo> exec -- pwsh -File <repo>\winfiles.ps1`, so only `mise` has to be on `PATH`, and the commands then clean the environment as usual.
- The checkout's path is written into the script, and rerunning from another checkout repoints it.
- It refuses to replace a file that doesn't start with its `# Managed by winfiles` marker, though it replaces an empty one.
- It doesn't add the folder to `PATH`, and `just install` doesn't run it.

Trade-off: a path fixed at write time, so moving the checkout means rerunning it (the script says so), rather than a lookup that would need its own config. Revisit if checkouts start moving often.
