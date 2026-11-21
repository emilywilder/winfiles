# DSC 3.3.0

How DSC 3.3.0 behaved when checked, and what in winfiles relies on it. Recheck these before bumping DSC in `mise.toml` (`docs/tooling.md`).

## The progress bar

DSC draws its progress bar through `tracing-indicatif` on stderr. Only stderr has to be a console: the bar showed with stdout on the console, with stdout captured, and with stdout captured through an Include (where it named the Include). With stderr redirected, it didn't show. The bar erases itself when it finishes, so a copied transcript doesn't show it.

Through an Include, the bar counts the entry's top level ("4/8 Set 'Packages'" for a whole module). The `dsc` each Include starts draws no bar of its own, because its stderr goes to the parent, not to a console.

- Checked: 2026-11-17, iris, in a conhost window, sampling the screen buffer while `Test/SlowList` documents ran.
- Used by: `dsclog.ps1` captures stdout only; the flat copy exists partly for a bar per resource (`docs/flat-configuration.md`).

## Resource messages and levels

At its default `warn` level, DSC shows only `warn` and `error` lines from resources. A resource's plain stderr lines are logged at `trace`. A resource can write `info`, but that needs `-l info` on the run, which adds DSC's own lines too (38 stderr lines for 5 items in `demos/dsc-messages`).

What a line looks like:
- In a flat document: `2026-11-18T23:42:39.864459Z  WARN PID 9308: Installing 'git' ...`.
- Through an Include: `WARN trace_message="PID <dsc>: PID <child>: Installing 'git' ..."`.
- Through two levels of Include, every message below `trace` is lost.

Details and per-version results are in `demos/dsc-messages/README.md`.

## Include result shapes

A `test` result for an Include is the bare list of its resources' results. A `set` result for an Include isn't: that list is its `afterState`. A list resource's leftovers are in `afterState.missing` after `set`, and in `actualState` after `test`.

- Checked: 2026-11-16, against a real `set` result from a `vm-quick` install. Reading only the `test` shape, that run logged `[home] done ... 5 resources` (its Includes) with three Scoop items missing.
- Used by: `dsclog.ps1` reads both shapes; the fake `dsc` gives a `set` Include that shape.

## Where restartRequired lands

A resource's top-level `_restartRequired` is collected into its own `executionInformation.restartRequired`. It also goes into the document's top-level `executionInformation.restartRequired` and `metadata.Microsoft.DSC.restartRequired`, but not through `Microsoft.DSC/Include`: there, each nested resource keeps its own entry under the Include's `result[]`, and nothing reaches the top. The schema is `dsc schema --type restart-required`, from PowerShell/DSC issue 50 and PR 975 (merged 2025-07-18).

- Checked: 2026-11-18, iris, with a probe document inside an Include; it also works on a flattened document.
- Used by: `Get-RestartReport` in `scripts/dsclog.ps1` reads the entries that `Get-ResourceResult` flattens.

## OptionalFeatureList and restarts

`Microsoft.Windows/OptionalFeatureList` can't report a restart from `test`: nothing its `get` returns reaches DSC's `restartRequired`. Its `set` does: it returned `_restartRequired: [{system: <computer name>}]` in its `afterState`. DSC collected that into the resource's `executionInformation.restartRequired`, with `changedProperties` `_restartRequired` and `features`.

Each feature's own `restartRequired` field says `Possible` for every feature, installed or not. Telnet Client (DISM `Disabled`, DSC `Staged`) and Virtual Machine Platform (`Enabled`, `Installed`) both said `Possible`. So the field can't tell a feature that needs a restart from one that doesn't.

- Checked: `test`, elevated, 2026-11-18 on iris; `set`, 2026-11-18 in a `vm-quick` run in the test VM.
- Used by: the run reads a pending restart from the machine after the features are applied (`docs/install.md`, "What needs a restart").

## Document-level securityContext

DSC 3.3.0 ignores `metadata.winget.securityContext` at the document level: `dsc config test` of a document with it ran as without it.

- Checked: 2026-11-19.
- Used by: the system entries carry the tag (`docs/flat-configuration.md`).
