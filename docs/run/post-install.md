# Post-install notes

A step winfiles can't do goes in a YAML comment beside the setting it's about: in a document a host's entries include (a module, such as `dsc/modules/system/settings.dsc.yaml`, or one of the host's own), in an entry, or in `dsc/hosts/<host>/manual.yaml`. The comment starts with `# post-install: ` and runs to the end of that block of comment lines. `winfiles.ps1 post-install` (`scripts/Show-PostInstall.ps1`) prints the notes from `manual.yaml`, then from the system entry and what it includes, then from the user's home entry and what it includes, each document once. A module's note shows only for hosts whose entries include it.

`winfiles.ps1 install` runs it last, so a stop for a restart or a failed `check` hides the notes until a run gets through.

Trade-off: nothing can tell whether a note has been done, so they print on every `winfiles.ps1 install`. Revisit if they start being ignored.

Something that can't be installed unattended goes in `manual.yaml` instead ([config/manual.md](../config/manual.md)), and Scoop's own app notes are printed by `winfiles.ps1 scoop-notes` ([config/scoop.md](../config/scoop.md)).
