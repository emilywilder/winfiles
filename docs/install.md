# Bootstrap and install

How a machine goes from a fresh Windows 11 install to its configuration. This is the overview: each step links to the doc that covers its details and trade-offs. How the configuration itself is laid out is in [architecture.md](architecture.md).

```powershell
.\bootstrap.cmd        # unelevated: winget, mise and mise.toml's tools; lists the hosts; applies nothing
.\install.cmd <host>   # then: winfiles.ps1 switch --restart; resumes at the sign-in after its restart, once Enter is pressed
```

## Two stages

1. **The bootstrap** (`bootstrap.cmd`) updates App Installer, installs mise with winget, and has mise install the repo's tools: pwsh, gsudo, yq and DSC. It proves a command runs, lists the hosts, and applies nothing. It reads nothing from `dsc/`. [run/bootstrap.md](run/bootstrap.md)
2. **The install** (`install.cmd <host>`) runs `winfiles.ps1 switch <host> --restart` in a clean environment, which restarts Windows itself and picks the run up again after the restart it needs. It assumes only what the bootstrap guarantees.

After that, `winfiles.ps1 switch` (or `.\winfiles.cmd switch` before pwsh is on `PATH`) makes the machine match its configuration again whenever it changes, as `nixos-rebuild switch` does. Without `--restart` it never restarts Windows: when a restart is needed it stops, says what it applied, what's left and the command to run, and the person restarts and runs it.

No `.cmd` changes the persistent `PATH`, so until the configuration installs its own `pwsh`, run commands through `winfiles.cmd`, e.g. `.\winfiles.cmd switch <host>` ([run/bootstrap.md](run/bootstrap.md#the-cmd-files)). What has to be in place before all this is in [dev/dependencies.md](dev/dependencies.md), and what the install sets up on the way is in [dev/installed-by-install.md](dev/installed-by-install.md).

## What the switch command runs

`winfiles.ps1 switch [host] [user] [--restart]` defaults to the computer name and the username, and fails before any change when there's no configuration for them. Then:

```powershell
gsudo --direct pwsh -File winfiles.ps1 --run switch <host> <user>   # the one UAC prompt (none from an elevated shell)
pwsh -File ./scripts/Invoke-Configuration.ps1 set  dsc/<host>.system.dsc.yaml dsc/<user>@<host>.home.dsc.yaml   # configure
pwsh -File ./scripts/Invoke-Configuration.ps1 test dsc/<host>.system.dsc.yaml dsc/<user>@<host>.home.dsc.yaml   # check: one total; exits 1 if anything is missing
pwsh -File ./scripts/Show-PostInstall.ps1 dsc/hosts/<host>/manual.yaml dsc/<host>.system.dsc.yaml dsc/<user>@<host>.home.dsc.yaml   # what's left to do by hand
```

Each step skips what's already done, so `switch` can be rerun at any point.

1. **Elevate once.** The whole run is elevated at its start, and drops back to unelevated for the batches that need it, such as Scoop's. [run/privilege.md](run/privilege.md)
2. **Flatten.** The system and home entries are flattened into one aggregate document, with every Include replaced by its resources, and split into batches by privilege. DSC only ever runs those batches. [run/flat-configuration.md](run/flat-configuration.md)
3. **Restart first.** Resources that report they'll need a restart (optional features, WSL, the computer name) are applied in a first batch. If Windows then has a restart pending, the run stops with 3010, saying what's left; with `--restart` it restarts Windows first. [run/restarts.md](run/restarts.md)
4. **Apply the rest,** batch by batch. A failed winget package stops its batch. [run/output.md](run/output.md#failures)
5. **Check.** Both configurations are tested, with one total, so a run that left anything missing fails.
6. **Post-install notes.** What a host or user still needs done by hand. [run/post-install.md](run/post-install.md)

A clean install runs twice: once up to the restart, and once after it, when the test finds the first batch done and carries on.

## Around the run

- **Continuing after a restart.** With `--restart` (as `install.cmd` runs it), `switch` registers a `RunOnce` entry, so the run continues at the next sign-in once Enter is pressed. [run/resume.md](run/resume.md)
- **A run inherits nothing.** Every run starts in the environment Windows builds for the user, under `mise exec`, so it's the same from any terminal. [run/clean-environment.md](run/clean-environment.md)
- **What a run says.** The console shows failures, warnings and results; progress goes to `~/.local/state/winfiles/run.log`. [run/output.md](run/output.md)
