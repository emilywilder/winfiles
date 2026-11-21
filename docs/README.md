# Docs

Start with the two overviews, then follow their links to the area you're working on. Where each kind of content goes is set out in the Docs section of `CLAUDE.md`.

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

## Working on winfiles

- [dev/testing.md](dev/testing.md): the Pester tests and fakes, what isn't tested, `demos/` and `surveys/`.
- [dev/tooling.md](dev/tooling.md): mise and `mise.lock`, DSC from mise, `just dsc` and `DSC_RESOURCE_PATH`, the recipes.
- [dev/dependencies.md](dev/dependencies.md): what `just install` needs before it starts, and what it installs on the way.

## Evidence and records

- [reference/](reference/): dated facts about tools winfiles doesn't own, one file per tool, and [ruled-out.md](reference/ruled-out.md), the approaches not taken.
- [benchmarks.md](benchmarks.md): every timing, with date, machine, commit and sample count.
- [upstream-drift.md](upstream-drift.md): where winfiles deliberately differs from the project a setting came from.
- [optional-goals.md](optional-goals.md): improvements nothing needs yet.
