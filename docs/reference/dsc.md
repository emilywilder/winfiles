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
- Used by: entries stay directly in `dsc/`, and modules don't include each other (`docs/config/layout.md`).

## metadata.description and whole-resource tests

DSC passes a resource's `metadata` to it as `_metadata`, but only when the resource's schema declares `_metadata`. It validates the instance with `_metadata` in it, logs "Will not add '_metadata' to properties because resource schema does not support it" at `info`, and writes the instance to stdin without it.

- Checked: 2026-11-21, iris, `-l trace config test` on a scratch document with `Winfiles/ComputerName` and a `metadata.description`: its stdin was `{"name":"IRIS"}`, and it reported in the desired state.
- Used by: no `Winfiles/*` schema declares `_metadata`, so none receives it and `Winfiles.WinGet/Package` doesn't forward it to winget (`docs/dev/writing-resources.md`).

`Microsoft.Windows/RegistryList` and `Microsoft.Windows/Service` have a synthetic test that counts it as a difference, so with a description, `test` always reports false and every `set` rewrites the values. Those two resources get a comment instead. `Microsoft.PowerShell.PSResourceGet/Repository`'s synthetic test isn't affected (`docs/reference/powershell.md`).

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

A resource that exits non-zero gets one `ERROR` line with its exit code and the manifest's description of that code ("Command: Resource 'pwsh' [exit code 1] manifest description: Error"), and nothing of what it wrote to stderr: a `throw` and a `Write-Error` both showed only that line.

- Checked: 2026-11-21, iris, DSC 3.3.0, with a test resource in the scratchpad.
- Used by: the `Winfiles/*` resources report every error as a JSON `error` line from their trap (`Exit-ResourceError` in `dsc/resources/common.ps1`).

## Include result shapes

A `test` result for an Include is the bare list of its resources' results. A `set` result for an Include isn't: that list is its `afterState`. A list resource's leftovers are in `afterState.missing` after `set`, and in `actualState` after `test`.

- Checked: 2026-11-16, against a real `set` result from a `vm-quick` install. Reading only the `test` shape, that run logged `[home] done ... 5 resources` (its Includes) with three Scoop items missing.
- Used by: `dsclog.ps1` reads both shapes; the fake `dsc` gives a `set` Include that shape.

## Where restartRequired lands

A resource's top-level `_restartRequired` is collected into its own `executionInformation.restartRequired`. It also goes into the document's top-level `executionInformation.restartRequired` and `metadata.Microsoft.DSC.restartRequired`, but not through `Microsoft.DSC/Include`: there, each nested resource keeps its own entry under the Include's `result[]`, and nothing reaches the top. The schema is `dsc schema --type restart-required`, from PowerShell/DSC issue 50 and PR 975 (merged 2025-07-18).

The same data under `_metadata.Microsoft.DSC` (the shape PowerShell/DSC#975 describes) stays in the resource's `metadata` and is collected nowhere. An entry that isn't `system`, `service` or `process` is still kept in `actualState`, and DSC only logs `WARN Resource returned property '_restartRequired' which contains invalid value`, so the restart goes unreported.

- Checked: 2026-11-18, iris, with a scratch resource and with a probe document inside an Include; it also works on a flattened document.
- Used by: `Winfiles.Wsl/Wsl` and `Winfiles/ComputerName` report a top-level `_restartRequired`; the tests check it against `dsc schema -t restart-required`.
- Used by: `Get-RestartReport` in `scripts/dsclog.ps1` reads the entries that `Get-ResourceResult` flattens.

## OptionalFeatureList and restarts

`Microsoft.Windows/OptionalFeatureList` can't report a restart from `test`: nothing its `get` returns reaches DSC's `restartRequired`. Its `set` does: it returned `_restartRequired: [{system: <computer name>}]` in its `afterState`. DSC collected that into the resource's `executionInformation.restartRequired`, with `changedProperties` `_restartRequired` and `features`.

Its schema says it returns `_restartRequired` from `set` when DISM reports a reboot is needed (read 2026-11-18). Each feature's own `restartRequired` field says `Possible` for every feature, installed or not. Telnet Client (DISM `Disabled`, DSC `Staged`) and Virtual Machine Platform (`Enabled`, `Installed`) both said `Possible`. So the field can't tell a feature that needs a restart from one that doesn't.

- Checked: `test`, elevated, 2026-11-18 on iris; `set`, 2026-11-18 in a `vm-quick` run in the test VM.
- Used by: the run reads a pending restart from the machine after the features are applied (`docs/run/restarts.md`).

## The command resource contract, as documented

What Microsoft's docs say a command resource must do. Read, not checked against 3.3.0, except where a line says so.

- **Manifest.** A UTF-8 JSON or YAML file named `<name>.dsc.resource.json` (or `.yaml`, `.yml`), validated against the manifest schema when found. It needn't sit beside its executable. Required: `$schema`, `type` (`^\w+(\.\w+){0,2}\/\w+$`), `version` (semver, of the resource, not what it manages) and `get`. `kind` is `resource` unless the manifest says `group`, `adapter`, `importer` or `exporter`.
- **Operations.** `get`, `set`, `test`, `export` and the others share one shape: `executable`, `args` (strings, plus at most one `{ "jsonInputArg": ..., "mandatory": ... }`) and `input` (`stdin` or `env`). A manifest with neither `input` nor a JSON argument is invalid. Without `set`, DSC can only get and test; without `test`, it runs a synthetic test: `get`, then a strict comparison of every desired property; without `whatIf`, it works one out from `test`. `export` is what `dsc resource export`, `dsc config export` and `get --all` use, and returns every instance.
- **Input.** `stdin` gets compressed JSON on one line. `env` gets one variable per property, same name and case, for booleans, numbers, strings and arrays of those only, an array joined with commas.
- **`set` and `test`.** `set.implementsPretest: true` means `set` tests for itself, so DSC skips `test` first. `return: state` (the default) gives the state after; `stateAndDiff` adds a line with the array of property names changed (`set`) or out of the desired state (`test`). `set.handlesExist: true` means the resource deals with `_exist: false` itself.
- **Output.** JSON on stdout, validated against the instance schema; an adapter may return an array or JSON Lines. Exit code 0 is success, and any other is a failure, described from `exitCodes` when listed there. Its keys are signed decimal integers, so `-2147024891`, not `0x80070005`, quoted in YAML.
- **Messages.** The anatomy page describes stderr lines as JSON with `message` and `level` (`error`, `warning`, `information`). winfiles writes `{"warn": "..."}` instead, the form checked in "Resource messages and levels" above; the documented form wasn't tried.
- **The Go sample.** PowerShell/DSC-Samples' Go tutorial (`gotstoy`, the only language there) uses `manifestVersion` and `preTest`, names from before 3.0; 3.3.0's manifests take `$schema` and `implementsPretest`, which every `Winfiles/*` manifest uses. It models presence with an `ensure` enum rather than `_exist`, and reads stdin by turning it into an `--inputJSON` argument.
- Read: 2026-11-21. Microsoft Learn, [resource anatomy](https://learn.microsoft.com/en-us/powershell/dsc/concepts/resources/anatomy) (ms.date 2025-03-25) and the [manifest schema reference](https://learn.microsoft.com/en-us/powershell/dsc/reference/schemas/resource/manifest/root) (2025-08-21; `get`, `set`, `test` pages 2025-07-03); [PowerShell/DSC-Samples](https://github.com/PowerShell/DSC-Samples).
- Used by: `docs/dev/writing-resources.md`.

## Editor schemas

Microsoft publishes an "enhanced" variant of the document and manifest schemas for VS Code: `https://aka.ms/dsc/schemas/v3/bundled/config/document.vscode.json` and `https://aka.ms/dsc/schemas/v3/bundled/resource/manifest.vscode.json`. They validate the same as the canonical ones, and add hover documentation, help for each enum value, snippets and clearer pattern errors, through keywords other tools may reject. VS Code maps them with `json.schemas` and `yaml.schemas` in `settings.json`; a YAML file can name one in a first-line `# yaml-language-server: $schema=<uri>` comment.

- Read: 2026-11-21, Microsoft Learn, [enhanced authoring](https://learn.microsoft.com/en-us/powershell/dsc/concepts/enhanced-authoring) (ms.date 2025-03-25). Its example `json.schemas` for manifests isn't valid JSON as printed (a trailing comma, a missing one).
- Used by: nothing yet (`docs/dev/writing-resources.md`, "Not done yet").

## Document-level securityContext

DSC 3.3.0 ignores `metadata.winget.securityContext` at the document level: `dsc config test` of a document with it ran as without it.

- Checked: 2026-11-19.
- Used by: the system entries carry the tag (`docs/run/flat-configuration.md`).
