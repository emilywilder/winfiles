# Scoop

Scoop is in the home configuration, because its installer refuses an elevated shell. Where packages are listed overall is in [packages.md](packages.md).

## The resources

- `Winfiles/Scoop`, the first resource in `modules/home/scoop-core.dsc.yaml`, installs Scoop by downloading and running Scoop's own installer, and does nothing else. In an elevated shell, its `set` exits 3 instead of trying.
- `Winfiles/ScoopPackageList` is a list: at most one per document, checked with one read of the Scoop root. Entries are `name` or `bucket/name`.
  - State comes from `apps/<name>/current/scoop-install.json` (`install.json` from older Scoop) and `buckets/<name>` under the root, not from running Scoop.
  - `set` adds missing buckets, then makes one `scoop install` call for the missing apps.
  - An app or bucket that fails stays in `missing` or `missingBuckets`, and the list still exits 0.
  - If Scoop is still missing when a list's `set` runs, the list exits 3.
- Both resources find the Scoop root with `Get-ScoopRoot` (`dsc/resources/scooproot.ps1`): `$env:SCOOP`, then `root_path` in Scoop's config, then `~\scoop`.

## The lists

`scoop-core.dsc.yaml` holds two lists:
- `Core` installs git, with no buckets, because adding any bucket other than `main` needs git.
- `Buckets` declares every bucket (name → repository URL), with no apps, and depends on `Core`.

Other modules list only apps, and depend on it in the entry.

- Scoop finds git through its shims. The `dsc` of a fresh `just install` started before Scoop's installer added them to the user `PATH`, so the list puts `<root>\shims` on `PATH` for its own process.
- Scoop's own `Installing '<app>' ...` lines are raised to `WARN`, the lowest level DSC shows by default, because otherwise a slow download looks like a hang.

## App notes

`just scoop-notes` (`scripts/Show-ScoopNote.ps1`) prints the `notes` from every installed app's manifest again, with `$dir`, `$original_dir` and `$persist_dir` filled in as `scoop info --verbose` does. A DSC run hides them. It covers every installed app, not just the lists, and changes nothing. Notes are free text, and mostly optional (context menus, file associations), so they're for review; one worth having becomes a resource. It stays out of `just install` and apart from `just post-install`, whose notes are a host's curated must-dos ([run/post-install.md](../run/post-install.md)).

Trade-off: nothing says when a new note appears, so it only helps when run. Revisit if a note that mattered gets missed.
