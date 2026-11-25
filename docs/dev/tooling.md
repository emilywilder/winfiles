# Tooling

Where the tools winfiles runs on come from (mise, its lock, DSC), how DSC is run, and the commands. Facts about DSC are in [reference/dsc.md](../reference/dsc.md), and timings are in [benchmarks.md](../benchmarks.md).

## mise

`mise.toml` holds the repo's tools, and `mise.lock` holds the exact version, download URL and checksum behind each one (Windows x64 only: `mise lock --platform windows-x64`). So every install gets the same tools, and mise refuses one that doesn't match the lock.

- `powershell`, `gsudo`, `yq` and `glow` stay `latest` in `mise.toml`, and only move when `mise lock --bump` is run.
- After changing a request in `mise.toml`, run `mise lock`.
- mise provides pwsh because DSC needs one before `modules/system/powershell.dsc.yaml` installs PowerShell: `scripts/Invoke-Dsc.ps1` runs under it, and `PowerShellScript` and the `Winfiles/*` resources are only discovered when DSC finds a pwsh. Inside the repo, under `mise exec` or `mise activate`, `pwsh` is mise's, not the winget one.

## DSC

DSC also comes from `mise.toml`: the GitHub release, pinned (3.3.0), because `reference/dsc.md` records version-specific behaviour. Before bumping it:
1. Recheck the entries in `reference/dsc.md`.
2. Re-time `winfiles.ps1 check`.
3. Rerun the `demos/dsc-messages` demo (its README).

Its `postinstall` deletes DSC's two discovery extensions, since DSC's settings have no switch for them ([reference](../reference/dsc.md#discovery)). The hook only runs when a version is installed, so after changing it, run `mise install --force github:PowerShell/DSC`. `scripts/Invoke-Dsc.ps1` warns when the extensions are back.

Trade-off: mise's DSC without the extensions, rather than the Store package.
- **Faster:** the extensions cost each `dsc` process about 3.3s ([benchmarks](../benchmarks.md#dsc-discovery)).
- **One way to install it,** pinned in the repo instead of updated by the Store, so only one version needs documenting, and no run mixes in another DSC's resources.
- **The cost:** resources that exist only inside Store packages aren't discovered, so `winfiles.ps1 dsc-export` no longer exports `OhMyPosh/*`. winfiles' documents use none of them.

Revisit when either version changes.

A machine may still have the Store DSC installed. Under `mise exec`, mise's `dsc` comes first on `PATH`; without mise, the Store's would, so `Invoke-Dsc.ps1` refuses a `dsc` under `WindowsApps` and says to use `mise exec` ([reference](../reference/dsc.md#the-store-package)).

### winfiles.ps1 dsc

`winfiles.ps1 dsc <args>` (`scripts/Invoke-Dsc.ps1`) runs `dsc` after setting `DSC_RESOURCE_PATH` for that process only. The path covers:
- DSC's install folder;
- App Installer's (`Microsoft.WinGet/*`);
- the PSResourceGet module bundled with the running pwsh (`Microsoft.PowerShell.PSResourceGet/*`), when it has DSC manifests, as pwsh 7.7.0's 1.3.1 does;
- `dsc/resources` (`Winfiles/*`).

That's how the `Winfiles/*` resources are found, and it stops every `dsc` process scanning all of `PATH` for manifests. The commands run it under mise's pwsh, which is also the `pwsh` DSC starts for the PSResourceGet resources, so the two match.

```powershell
winfiles.ps1 dsc config test --file dsc/iris.system.dsc.yaml               # one configuration, as full JSON
winfiles.ps1 dsc config test --file dsc/modules/system/policies.dsc.yaml   # one module on its own
winfiles.ps1 dsc config get  --file <doc>                                  # current state
winfiles.ps1 dsc config set  --file <doc>                                  # apply (HKLM resources need an elevated shell)
```

`dsc config test` exits 0 whatever it finds, so a script has to read its results; `scripts/Test-Winfiles.ps1` does that for `winfiles.ps1 check`. Run `test` before `set`, since `set` changes the real machine: it installs packages, writes the registry, and rewrites profile stubs (keeping `.bak` copies).

`winfiles.ps1 dsc-export` (`scripts/Export-DscResource.ps1`) writes the current state of every exportable resource to `exports/`. It's a nice-to-have, not part of applying the configuration, so don't let it drive design decisions.

## Commands

`winfiles.ps1` at the repo root runs the commands. With no arguments it lists them, and `winfiles.ps1 help <command>` shows a command's arguments and defaults, plus the help of the script its extra arguments go to. `install.cmd`, the bootstrap's check and `winfiles-rebuild` call it too.

The commands are data, in `commands.jsonc`: JSON with comments, which `ConvertFrom-Json` reads ([reference](../reference/windows.md#convertfrom-json-and-comments)), so each command's reasons sit next to it. Its header lists the fields:
- **What runs:** a `script` with its `args`, `steps` (other commands, in order) and `dependsOn`, or a `builtin` (`hosts`, `help`);
- **Arguments:** `parameters`, with defaults that may use `{computername}`, `{username}` and `{home}`, and `passArgs` for a command whose extra arguments go on to its script;
- **Safe defaults:** `requires` (files checked for the whole plan before anything runs, so a wrong host never reaches a UAC prompt), `privilege` (`admin`, `user` or `any`) with its `uacMessage`, `clean`, and `log` (the `run.log` lines), and `resumable` for a command that continues after a restart ([resume.md](../run/resume.md));
- **Listing:** `description`, `group` and `private`.

The runner, `scripts/commands.ps1`, reads and checks the table (an unknown field, a placeholder that isn't a parameter, a missing script or command), resolves a command's dependencies and steps depth first, each once per set of arguments, and refuses a cycle. Then it runs the plan:
1. It checks every `requires`.
2. When anything in the plan is `clean`, it starts itself again as `winfiles.ps1 --clean <command>` through `Invoke-Clean.ps1`, once per run ([clean-environment.md](../run/clean-environment.md)).
3. A command that needs another privilege runs as `winfiles.ps1 --run <command>` through `Invoke-AsAdmin.ps1` or `Invoke-AsUser.ps1`, once, with its steps inside ([privilege.md](../run/privilege.md)).
4. Each script runs as `pwsh -NoLogo -NoProfile -File <script> <args>`. The first that fails stops the run, which exits with its code unchanged, 3010 included. The runner prints nothing of its own about it, since the scripts report their failures.

A usage error (an unknown command, a missing or extra argument) exits 2. Scripts run without the profile, which is much faster ([benchmarks](../benchmarks.md#commands-without-the-profile)); a script that comes to need something from it sets that up itself. `tests/scripts/Commands.Tests.ps1` covers the runner against a table of its own, and the real `install`.

Trade-off: a runner of winfiles' own, in PowerShell, rather than `just`. The commands' order, privilege and clean environment are fields the runner handles once per run, rather than lines repeated in each `just` recipe, and the rationale lives in the table. The cost is one more script to maintain and test, and pwsh's start-up on every run. Revisit if the runner grows features a general command runner already has. mise tasks ([ruled-out.md](../reference/ruled-out.md#mise-tasks-for-the-command-runner)) and a runner in Rust or Go ([ruled-out.md](../reference/ruled-out.md#rust-or-go-for-the-command-runner)) were ruled out.

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

### winfiles-rebuild

`winfiles.ps1 install-rebuild` (`scripts/Install-Rebuild.ps1`) writes `winfiles-rebuild.ps1`, the counterpart of pointing `nixos-rebuild` at a flake directory. `winfiles-rebuild check` is `./winfiles.ps1 check` in the checkout, from any directory; with no arguments, it lists the commands.

- It runs `mise -C <repo> exec -- pwsh -File <repo>\winfiles.ps1`, so only `mise` has to be on `PATH`, and the commands then clean the environment as usual.
- The checkout's path is written into the script, and rerunning from another checkout repoints it.
- It refuses to replace a file that doesn't start with its `# Managed by winfiles` marker, though it replaces an empty one.
- It doesn't add the folder to `PATH`, and `winfiles.ps1 install` doesn't run it.

Trade-off: a path fixed at write time, so moving the checkout means rerunning it (the script says so), rather than a lookup that would need its own config. Revisit if checkouts start moving often.

## Not done yet

- **A C# port of the runner.** A Native AOT `winfiles.exe` that reads the same `commands.jsonc` (`System.Text.Json` skips its comments with `JsonCommentHandling.Skip`), with `Commands.Tests.ps1` ported or run against it. Not done because the pwsh runner covers every need. Worth doing if pwsh's start-up shows up as significant in [benchmarks.md](../benchmarks.md), if unattended runs need the scheduled-task broker ([ruled-out.md](../reference/ruled-out.md#a-scheduled-task-for-the-resumes-uac-prompt)), or if a build step becomes acceptable for another reason.
