# Scoop

Scoop is in the home configuration, because its installer refuses an elevated shell. Where packages are listed overall is in [packages.md](packages.md).

## The resources

- `Winfiles/Scoop`, the first resource in `modules/home/scoop-core.dsc.yaml`, installs Scoop by downloading and running Scoop's own installer, and does nothing else. In an elevated shell, its `set` exits 3 instead of trying.
- `Winfiles.Scoop/Package` is one app: `name`, and optionally `bucket`. Without `bucket`, an install from any bucket counts.
  - State comes from `apps/<name>/current/scoop-install.json` (`install.json` from older Scoop) under the root, not from running Scoop. `get` reports the bucket it was installed from.
  - `test` and `set` return `stateAndDiff`: a missing app differs in `_exist`, and one installed from another bucket in `bucket`.
  - `set` runs `scoop install [<bucket>/]<name>` for a missing app, and exits 2 if it's still missing. For an app from another bucket it exits 2 without running Scoop, which wouldn't replace it.
- `Winfiles.Scoop/Bucket` is one bucket: `name`, and `source`, the repository URL (empty for a bucket Scoop knows). State is whether `buckets/<name>` exists; the URL it was added from isn't checked. `set` runs `scoop bucket add`, and exits 2 if the bucket is still missing.
- Both only add: removing a resource doesn't uninstall anything, and `_exist: false` exits 4. If Scoop is missing when their `set` has something to do, they exit 3.
- All three resources find the Scoop root with `Get-ScoopRoot` (`dsc/resources/scooproot.ps1`): `$env:SCOOP`, then `root_path` in Scoop's config, then `~\scoop`. The package and bucket resources run Scoop through `Invoke-Scoop` (`dsc/resources/scoopcommand.ps1`).

Trade-off: each app is a pwsh start of its own, where the lists checked all their apps in one, so `check` takes roughly half a second more per app, about 25s for iris's 48 resources (estimated from `Winfiles.WinGet/Package`'s pwsh start, [benchmarks](../benchmarks.md#per-package-resources); not measured yet), and each install loads Scoop again. In return there's no list code, drift names the app, a failure names the one app that failed, and each app shows in DSC's progress bar. Revisit if `check` gets slow enough to discourage running it.

## The resources in the documents

Each app is a resource of its own, named after the app, with comments between them grouping the apps by purpose, as winget packages are ([winget.md](winget.md)).

`scoop-core.dsc.yaml` holds Scoop, then:
- git and the tools Scoop's installs use (7zip, innounp, dark, cacert, scoop-search), each depending on `Winfiles/Scoop`.
- A `Winfiles.Scoop/Bucket` per bucket, each depending on git, since adding any bucket other than `main` needs it. Their URLs come from the `buckets` parameter, so a new bucket is an entry there and a resource.

Other modules have only apps, and depend on `scoop-core` in the entry. An app from a bucket other than `main` names its `bucket`.

- Scoop finds git through its shims. The `dsc` of a fresh `just install` started before Scoop's installer added them to the user `PATH`, so `Invoke-Scoop` puts `<root>\shims` on `PATH` for its own process.
- Scoop's output stays plain, so DSC shows it only at `-l trace`, as for the other tools ([resources.md](resources.md#conventions)). DSC's progress bar names the app being installed, which tells a slow download from a hang.
- A failed app stops its batch, as a failed winget package does ([run/output.md](../run/output.md#failures)).

## App notes

`just scoop-notes` (`scripts/Show-ScoopNote.ps1`) prints the `notes` from every installed app's manifest again, with `$dir`, `$original_dir` and `$persist_dir` filled in as `scoop info --verbose` does. A DSC run hides them. It covers every installed app, not just the configured ones, and changes nothing. Notes are free text, and mostly optional (context menus, file associations), so they're for review; one worth having becomes a resource. It stays out of `just install` and apart from `just post-install`, whose notes are a host's curated must-dos ([run/post-install.md](../run/post-install.md)).

Trade-off: nothing says when a new note appears, so it only helps when run. Revisit if a note that mattered gets missed.
