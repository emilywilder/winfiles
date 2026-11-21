# DSC 3.3.0

How DSC 3.3.0 behaved when checked, and what in winfiles relies on it. Recheck these before bumping DSC in `mise.toml` (`docs/dev/tooling.md`).

## Discovery

- DSC 3.3.0 ships two discovery extensions, `Microsoft.Windows.Appx/Discover` and `Microsoft.PowerShell/Discover`, and `dsc.settings.json` has no switch for them: it only covers `resourcePath` and `tracing`. They cost every `dsc` process about 3.3s ([benchmarks](../benchmarks.md#dsc-discovery)). The Appx extension also found the Store DSC's own `Include`, `PowerShellScript` and `Registry`, so a run could mix resources from two installed DSCs (checked 2026-10-28).
- `DSC_RESOURCE_PATH` replaces the scan of all of `PATH` for manifests. `tryWhich` conditions in manifests, such as `pwsh` and `sshd`, still search `PATH`. `PowerShellScript` and pwsh-based resources such as `Winfiles/*` are only discovered when `tryWhich('pwsh')` finds a pwsh.
- Used by: `mise.toml`'s `postinstall` deletes the extensions, and `scripts/Invoke-Dsc.ps1` sets `DSC_RESOURCE_PATH` and warns when the extensions are back (`docs/dev/tooling.md`).

## The Store package

- The Store package's `dism_dsc` refuses to run ("not supported when installed via Appx").
- The Store's DSC (`9NVTPZWRC6KQ`, 3.2.3) run as plain `dsc` didn't find the `Winfiles/*` resources ("Resource not found", 2026-11-14).
- Used by: `scripts/Invoke-Dsc.ps1` refuses a `dsc` under a `WindowsApps` folder and says to use `mise exec`.

## Include paths

- A `configurationFile` resolves from the folder of the document passed to `--file`, from any working directory. That includes the Includes inside included documents (also in 3.2.3).
- `..` in the path is refused ("must not contain '..'").
- So a module that includes a sibling works either from its entry (`modules/system/b.dsc.yaml`) or on its own (`b.dsc.yaml`), never both.
- Two modules that include the same third one each run it, so a `set` applies it twice.
- Checked: 2026-11-21, with `dsc config get` on scratch documents of `Microsoft.DSC.Debug/Echo` laid out like `dsc/`.
- Used by: entries stay directly in `dsc/`, and modules don't include each other (`docs/architecture.md`, "Structure").

## metadata.description and whole-resource tests

DSC passes a resource's `metadata` to it as `_metadata`. `Microsoft.Windows/RegistryList` and `Microsoft.Windows/Service` have a synthetic test that counts it as a difference, so with a description, `test` always reports false and every `set` rewrites the values. Those two resources get a comment instead. `Microsoft.PowerShell.PSResourceGet/Repository`'s synthetic test isn't affected (`docs/reference/powershell.md`).

## Strings that start with [

DSC parses a string that starts with `[` as an expression. Doubling it (`[[`) escapes it. So inline `~/.wslconfig` content, which would start with `[wsl2]`, starts with a `Managed by winfiles` comment instead, and a version range in a document is written `'[[0.0,)'`.

## copy loops

A `copy` loop over a list parameter worked from a list passed in an Include's `parametersContent` (YAML is accepted), through the flattener, and in `config test` on iris. But DSC deprecates `copy` (PowerShell/DSC#1429, to be removed after 3.x, with no replacement yet) and warns about it on every run, at the default level.

- Checked: 2026-11-21, DSC 3.3.0; tried and reverted (`docs/reference/ruled-out.md`).

## OptionalFeatureList and elevation

`Microsoft.Windows/OptionalFeatureList` needs elevation even for `get`, and DSC refuses the whole run without it. So a document that includes it, and `just check`, run elevated.

## The progress bar

DSC draws its progress bar through `tracing-indicatif` on stderr. Only stderr has to be a console: the bar showed with stdout on the console, with stdout captured, and with stdout captured through an Include (where it named the Include). With stderr redirected, it didn't show. The bar erases itself when it finishes, so a copied transcript doesn't show it.

Through an Include, the bar counts the entry's top level ("4/8 Set 'Packages'" for a whole module). The `dsc` each Include starts draws no bar of its own, because its stderr goes to the parent, not to a console.

- Checked: 2026-11-17, iris, in a conhost window, sampling the screen buffer while `Test/SlowList` documents ran.
- Used by: `dsclog.ps1` captures stdout only; the flat copy exists partly for a bar per resource (`docs/run/flat-configuration.md`).

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

The same data under `_metadata.Microsoft.DSC` (the shape PowerShell/DSC#975 describes) stays in the resource's `metadata` and is collected nowhere. An entry that isn't `system`, `service` or `process` is still kept in `actualState`, and DSC only logs `WARN Resource returned property '_restartRequired' which contains invalid value`, so the restart goes unreported.

- Checked: 2026-11-18, iris, with a scratch resource and with a probe document inside an Include; it also works on a flattened document.
- Used by: `Winfiles/Wsl` and `Winfiles/ComputerName` report a top-level `_restartRequired`; the tests check it against `dsc schema -t restart-required`.
- Used by: `Get-RestartReport` in `scripts/dsclog.ps1` reads the entries that `Get-ResourceResult` flattens.

## OptionalFeatureList and restarts

`Microsoft.Windows/OptionalFeatureList` can't report a restart from `test`: nothing its `get` returns reaches DSC's `restartRequired`. Its `set` does: it returned `_restartRequired: [{system: <computer name>}]` in its `afterState`. DSC collected that into the resource's `executionInformation.restartRequired`, with `changedProperties` `_restartRequired` and `features`.

Its schema says it returns `_restartRequired` from `set` when DISM reports a reboot is needed (read 2026-11-18). Each feature's own `restartRequired` field says `Possible` for every feature, installed or not. Telnet Client (DISM `Disabled`, DSC `Staged`) and Virtual Machine Platform (`Enabled`, `Installed`) both said `Possible`. So the field can't tell a feature that needs a restart from one that doesn't.

- Checked: `test`, elevated, 2026-11-18 on iris; `set`, 2026-11-18 in a `vm-quick` run in the test VM.
- Used by: the run reads a pending restart from the machine after the features are applied (`docs/run/restarts.md`).

## Document-level securityContext

DSC 3.3.0 ignores `metadata.winget.securityContext` at the document level: `dsc config test` of a document with it ran as without it.

- Checked: 2026-11-19.
- Used by: the system entries carry the tag (`docs/run/flat-configuration.md`).
