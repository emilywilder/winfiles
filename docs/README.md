# Docs

Start with the two overviews, then follow their links to the area you're working on. Work nothing needs yet is at the end of each area doc, under "Not done yet". Where each kind of content goes is set out in the Docs section of `CLAUDE.md`.

## Overviews

- [architecture.md](architecture.md): how the configuration is laid out, and the three tests everything added has to pass.
- [install.md](install.md): how a machine goes from a fresh Windows to its configuration, step by step.

## How a run works

- [run/bootstrap.md](run/bootstrap.md): `bootstrap.cmd` and `install.cmd`, what the bootstrap runs and why.
- [run/privilege.md](run/privilege.md): the one UAC prompt, and dropping back to unelevated with gsudo.
- [run/flat-configuration.md](run/flat-configuration.md): the flat copy, batches, the aggregate and `-First`: why, how, and what it refuses.
- [run/restarts.md](run/restarts.md): finding what needs a restart, applying it first, and what counts as pending.
- [run/resume.md](run/resume.md): the RunOnce entry and `Resume-Winfiles.ps1`.
- [run/clean-environment.md](run/clean-environment.md): `Invoke-Clean.ps1` and `Start-Clean.ps1`, so a run inherits nothing from its terminal.
- [run/output.md](run/output.md): failures, DSC's results files, the console and `run.log`.
- [run/post-install.md](run/post-install.md): `# post-install:` notes.

## What's configured

- [config/layout.md](config/layout.md): where a document goes in `dsc/`, the hosts, and how to add one.
- [config/features.md](config/features.md): Windows optional features.
- [config/packages.md](config/packages.md): where packages are listed, and what's managed elsewhere.
- [config/winget.md](config/winget.md): winget packages, which list a new one goes in, and `Winfiles.WinGet/Package`.
- [config/scoop.md](config/scoop.md): Scoop, its lists, and `just scoop-notes`.
- [config/manual.md](config/manual.md): what's installed by hand, and `just manual`.
- [config/wsl.md](config/wsl.md): the WSL package, distributions and the firewall.
- [config/powershell.md](config/powershell.md): PowerShell 7, remoting, modules and profiles.
- [config/computer-name.md](config/computer-name.md): naming the computer after its host.
- [config/resources.md](config/resources.md): the `Winfiles/*` resources and their conventions.

## Working on winfiles

- [dev/testing.md](dev/testing.md): the Pester tests and fakes, what isn't tested, `demos/` and `surveys/`.
- [dev/tooling.md](dev/tooling.md): mise and `mise.lock`, DSC from mise, `just dsc` and `DSC_RESOURCE_PATH`, the recipes.
- [dev/dependencies.md](dev/dependencies.md): what `just install` needs before it starts, and what it installs on the way.

## Evidence and records

- [reference/](reference/): dated facts about tools winfiles doesn't own, one file per tool (including [bicep.md](reference/bicep.md), researched and not used yet), and [ruled-out.md](reference/ruled-out.md), the approaches not taken.
- [benchmarks.md](benchmarks.md): every timing, with date, machine, commit and sample count.
- [upstream-drift.md](upstream-drift.md): where winfiles deliberately differs from the project a setting came from.
