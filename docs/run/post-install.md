# Post-install notes

A step winfiles can't do goes in a YAML comment in `dsc/hosts/<host>/` or `dsc/users/<user>@<host>/`. The comment starts with `# post-install: ` and runs to the end of that block of comment lines, beside the setting it's about. `just post-install` (`scripts/Show-PostInstall.ps1`) prints the host's notes, then the user's.

`just install` runs it last, so a stop for a restart or a failed `check` hides the notes until a run gets through.

Trade-off: nothing can tell whether a note has been done, so they print on every `just install`. Revisit if they start being ignored.

Something that can't be installed unattended goes in `manual.yaml` instead ([architecture.md](../architecture.md#installed-by-hand)), and Scoop's own app notes are printed by `just scoop-notes` ([architecture.md](../architecture.md#scoop)).
