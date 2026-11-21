# winget packages

How winget packages are listed, and which list a new one goes in. Where packages are listed overall is in [packages.md](packages.md); winget's behaviour is in [reference/winget.md](../reference/winget.md).

Each winget package is a resource of its own, with comments between them grouping the packages by purpose. The properties are `name` (the id), `source: winget` and `acceptAgreements: true`.
- In `modules/system` and the hosts' system documents, it's a `Microsoft.WinGet/Package`. These set no scope, so winget picks one.
- In `modules/home` and the hosts' home documents, it's a `Winfiles.WinGet/Package` with `_scope: User`, which makes winget pick a per-user installer, and fail if there's none ([reference](../reference/winget.md#install-scope)).

## Adding a package

Copy a neighbour under the right comment.
- It goes in `modules/home` if it has a per-user installer (`winget show --id <id> --exact --scope user` names one) that really runs unelevated.
- Otherwise it goes in `modules/system`.
- The manifest doesn't prove the installer runs unelevated: KDE Connect's per-user installer still asks for UAC, so it's in `modules/system`. Only a run in the test VM shows this ([reference](../reference/apps.md)).

Removing a package's resource doesn't uninstall it: set `_exist: false` and apply that first. A failed package stops its batch ([run/output.md](../run/output.md#failures)). `modules/system/settings.dsc.yaml` marks the `msstore` source explicit (`Microsoft.WinGet/Source`), so winget only uses it when a command passes `--source msstore`.

Trade-off: each package is a `winget dscv3` process that looks up its own package, which roughly doubled `just check` on iris against the old lists, to about 150s ([benchmarks](../benchmarks.md#per-package-resources)). In return there's no custom list code, each package has its own options, uninstalls work through `_exist`, and drift names the package. Revisit if `check` gets slow enough to discourage running it, or if winget gains a batch `test`.

## Winfiles.WinGet/Package

It exists for the home packages, until App Installer's resource has a canonical `_scope` (below). It takes `Microsoft.WinGet/Package`'s properties, plus `_scope` (`User` or `Machine`), and passes everything but `_scope` to `winget dscv3 package`, as App Installer's manifest does, so winget decides the state and the messages.

- `_scope` only changes `set`. A package that isn't installed is first installed with `winget install --exact --scope`, since `winget dscv3` takes no scope. Then `winget dscv3 package --set` finds it installed.
- `get` and `test` ignore the scope a package is in, as winget does.
- A failed install exits 2, which stops the configuration like a failed `Microsoft.WinGet/Package`. The failure is written to `run.log` under `[winget]`.

Trade-off: a pwsh start on top of each winget call, about 0.55s per package ([benchmarks](../benchmarks.md#per-package-resources)), so about 22s more on a `check` for the 40 home ids, for installs that don't raise UAC in `just home`. Revisit when the official `_scope` ships.

## Drift from upstream

### Install scope: `_scope`

Checked 2026-11-17.

- **Upstream:** [PowerShell/DSC#828](https://github.com/PowerShell/DSC/issues/828) proposes a canonical `_scope` property (open when read, no linked PR or milestone). On 2025-08-20 the DSC working group agreed on the values `User` and `Machine`; the default was asked about and never answered. App Installer's `Microsoft.WinGet/Package` (winget 1.29.380) has neither `_scope` nor `scope`, so it installs in whichever scope winget picks.
- **Why winfiles differs:** without a scope, winget picked gh's machine-wide MSI on every path, which raises a UAC prompt in the unelevated `just home` ([reference](../reference/winget.md#install-scope)). A global `installBehavior` scope in winget's `settings.json` was ruled out, since the elevated `just system` reads the same file.
- **Kept in step:** the values are the working group's, and the other properties are exactly upstream's, so moving to the official resource is meant to be a change of `type:` only.
- **Revisit:** when `just dsc resource schema --resource Microsoft.WinGet/Package` shows `_scope`, after an App Installer update. Check the semantics before swapping: upstream's `test` may count a package installed in the other scope as drift, or `_scope` may get a default, where this resource ignores the scope in `test`.

## Not done yet

- **A retry for `0x80071130`** ("Fast Cache data not found"), seen once from `winget dscv3 package --get` right after a portable `Kubernetes.kubectl` install, 7m07s into a `vm` user batch; a rerun passed ([reference](../reference/winget.md#0x80071130-after-a-portable-install)). Cause unknown and the package whose `get` failed isn't recorded, so no retry yet. If it recurs, the `[winget]` line in `run.log` now names the package; retry there only if it keeps happening.
