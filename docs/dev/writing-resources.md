# Writing a resource

How to add a `Winfiles/*` resource: the files, the manifest, what each operation returns, and how to try and test it. The resources that exist, and the conventions their scripts share, are in [config/resources.md](../config/resources.md). What DSC documents about resources, and how 3.3.0 really behaved, is in [reference/dsc.md](../reference/dsc.md#the-command-resource-contract-as-documented).

A resource is for a job no built-in does, and that needs more than a `Microsoft.DSC.Transitional/PowerShellScript` in a document can carry: its own tests, a schema, a `_restartRequired`, or a list that applies what it can. Prefer a built-in, then a script in a document, as `CLAUDE.md` says.

## The files

A resource is two files in `dsc/resources/`, named after it in lower case: `<name>.dsc.resource.json`, the manifest, and `<name>.ps1`, the script. DSC finds manifests by their `.dsc.resource.json` suffix, in `DSC_RESOURCE_PATH`, which `winfiles.ps1 dsc` sets ([tooling.md](tooling.md#winfilesps1-dsc)). Start by copying `computername.dsc.resource.json` and `computername.ps1`: they're the smallest that use every convention.

Code that two resources share goes in a dot-sourced file beside them, such as `wslstate.ps1` (Winfiles.Wsl/Wsl and Winfiles.Wsl/Distribution) or `scooproot.ps1`, and code shared with `scripts/` stays there and is dot-sourced from it, as `privilege.ps1` is. Like the other dot-sourced files, it has a plain comment at the top saying who uses it, and help on each function. Since the script dot-sources it, a test running the script in-process can still mock what it defines. A resource that runs a slow tool whose output DSC wouldn't show, such as `wsl.exe` or `winget`, also dot-sources `scripts/winlog.ps1` and writes that output to `run.log`, so a failed run can be read afterwards ([output.md](../run/output.md#the-console-and-runlog)).

## The manifest

| Field | What winfiles puts there, and why |
|---|---|
| `$schema` | `https://aka.ms/dsc/schemas/v3/bundled/resource/manifest.json`, the canonical schema, which any JSON Schema tool can check |
| `type` | `Winfiles/<Name>`, or `Winfiles.<Area>/<Name>` for one of several resources for one tool (`Winfiles.Scoop/Package`, `Winfiles.Scoop/Bucket`) or one that wraps another resource (`Winfiles.WinGet/Package`). DSC's pattern is `^\w+(\.\w+){0,2}\/\w+$` |
| `version` | the resource's own semver, starting at `0.1.0` |
| `description` | one line saying what state it ensures |
| `condition` | `[not(equals(tryWhich('pwsh'), null()))]`, so the resource is only offered where there's a pwsh to run it |
| `get`, `test`, `set` | the same command, differing only in the operation: `pwsh -NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -Command "$input \| ./<name>.ps1 <operation>; exit $LASTEXITCODE"`, with `"input": "stdin"` |
| `set.implementsPretest` | `true`: `set` tests for itself and changes only what differs, so DSC doesn't run `test` first |
| `set.return`, `test.return` | `state`, or `stateAndDiff` when the resource can name what differs (below) |
| `set.handlesExist` | `true` only for a resource with `_exist` that removes what it manages; otherwise left out |
| `exitCodes` | `0` success and `1` "PowerShell script execution failed", then `2` up for the resource's own failures, each described for the person reading DSC's one error line. A tool's failure maps to one of these, with the tool's own code in the message, as `Winfiles.WinGet/Package`'s `4` does: DSC describes only the codes the manifest lists |
| `schema.embedded` | the instance's JSON Schema (below) |

`input: stdin` sends the instance as one line of compressed JSON, which keeps nested objects and lists. The `env` input can't carry those, and a JSON argument puts the instance on the command line, where pwsh's quoting gets in the way.

No `Winfiles/*` resource has `export`, `whatIf` or `delete`. Without `whatIf`, DSC works out `set --what-if` from `test`. Add `export` only for a resource whose instances can be listed cheaply, and `delete` only for one with `_exist`.

### The schema

- `"$schema": "https://json-schema.org/draft/2020-12/schema"`, `"type": "object"`, the properties that identify the instance in `required`, and `"additionalProperties": false`, so a misspelt property fails validation rather than being ignored. A resource with one instance per machine, such as `Winfiles.Scoop/Scoop` or `Winfiles.Wsl/Wsl`, has nothing to identify it, and no `required`.
- A `description` on every property, `_inDesiredState` included: it's what `dsc resource schema` and an editor show.
- What the resource reports but doesn't take, such as `activeName`, is `readOnly`. It has `null` among its types only when it can be absent, as `activeName` and `basePath` can; a count or a flag the resource always reports, such as `hypervisor`, doesn't.
- DSC's own properties start with `_`. A resource that returns one declares it: `_inDesiredState` (boolean) from `test`, and `_restartRequired` in the shape `dsc schema --type restart-required` gives. A wrong `_restartRequired` only logs a warning, and the restart goes unreported ([reference](../reference/dsc.md#where-restartrequired-lands)).
- DSC passes the document's `metadata` in as `_metadata` only to a resource whose schema declares it ([reference](../reference/dsc.md#metadatadescription-and-whole-resource-tests)). No `Winfiles/*` schema does, so a `metadata.description` reaches none of them, and `Winfiles.WinGet/Package` never forwards it to winget.

## The operations

Each operation reads the instance from stdin and writes one JSON object to stdout, which DSC validates against the schema.

- **`get`** returns the actual state: the desired instance's identifying properties, and what's really there.
- **`test`** returns the same, plus `_inDesiredState`. Without a `test` of its own, DSC compares every property it was given with what `get` returns, exactly, and `_metadata` too for a schema that takes it ([reference](../reference/dsc.md#metadatadescription-and-whole-resource-tests)), so a resource with any property that's reported differently from how it's written, such as a name compared ignoring case, needs its own `test`.
- **`set`** changes only what differs, asking `$PSCmdlet.ShouldProcess` before each change, then returns the state after it. Running it twice changes nothing the second time. What it can't do, such as a restart, it reports: `_restartRequired`, and a `warn` message.
- **`stateAndDiff`**: the state, then a second line with a JSON array of property names: for `test` the ones out of the desired state, for `set` the ones it changed. `Winfiles.WinGet/Package` passes on what `winget dscv3` returns, adding `_exist` when it installed the package itself.

## Output and messages

- **stdout is only the JSON.** Anything else printed before it, such as a cmdlet's warning (pwsh writes warnings to stdout here), makes DSC fail with "JSON: expected value at line 1 column 1". Silence it at the call (`-WarningAction SilentlyContinue`, `$ProgressPreference = 'SilentlyContinue'`), or capture a tool's output.
- **Messages** go through `Write-ResourceMessage` as JSON lines on stderr. Only `warn` and `error` show at DSC's default level, and plain stderr only at `trace` ([reference](../reference/dsc.md#resource-messages-and-levels)). Warn about what someone has to act on; leave progress out.
- **Errors** throw `New-ResourceError` with one of the manifest's exit codes, and the script's `trap` reports them. A failure writes no state ([config/resources.md](../config/resources.md#conventions)).

## The script

Its structure is set in `CLAUDE.md` (Custom resource conventions, Script conventions) and in [config/resources.md](../config/resources.md#conventions). In short: `#Requires`, help with an `.EXAMPLE` that pipes an instance in, `[CmdletBinding(SupportsShouldProcess)]`, `-Operation` with a `ValidateSet` of the manifest's operations, the pipeline parameter, `common.ps1` dot-sourced in `begin`, lines collected in `process`, the work in `end` under its own `trap`, and an explicit `exit 0`. Put what reads the machine (registry, CIM, a tool) in small functions, so the tests can mock them.

## Trying it

From `dsc/resources`, the script runs as DSC runs it, and `-WhatIf` shows what `set` would do:

```powershell
'{"name":"iris"}' | ./computername.ps1 test
'{"name":"iris"}' | ./computername.ps1 set -WhatIf
```

Then through DSC, which also checks the manifest and the schema. Pipe the instance in with `--file -`: an `--input` argument lost its quotes on the way through `just` and the pwsh it started, and that hasn't been rechecked through `winfiles.ps1`.

```powershell
mise exec -- pwsh -File winfiles.ps1 dsc resource list 'Winfiles/*'
mise exec -- pwsh -File winfiles.ps1 dsc resource schema --resource Winfiles/ComputerName
'{"name":"iris"}' | mise exec -- pwsh -File winfiles.ps1 dsc resource test --resource Winfiles/ComputerName --file -
```

`mise exec` is only needed in a shell without mise activated, where `dsc` would be the Store's.

Run `test` before `set`: `set` changes the real machine.

## Tests and docs

- **Tests** go in `tests/resources/`. They run the resource through its manifest's command in a child pwsh, or, for one that reads what a child can't be pointed away from, in-process with mocks ([resource-tests.md](resource-tests.md)).
- **Docs:** a row in the table in [config/resources.md](../config/resources.md), what it does and its trade-offs in its area's doc, and anything learned about the tool it drives in `docs/reference/`.

## Why command resources

The resources are pwsh scripts behind a manifest, not class-based PowerShell resources run through the `Microsoft.DSC/PowerShell` adapter. Trade-off: each operation starts a pwsh, and the resource can't also serve PSDSC, for resources that DSC finds and runs like any other, with the exit codes, messages and stdout under winfiles' control ([ruled-out.md](../reference/ruled-out.md#class-based-powershell-resources)). Revisit if a resource needs to be published for others, or the adapter's costs are measured and turn out small.

## Not done yet

- **Editor help from the enhanced schemas.** Microsoft publishes VS Code variants of the schemas (`https://aka.ms/dsc/schemas/v3/bundled/resource/manifest.vscode.json`, and `.../config/document.vscode.json` for documents), with hover docs, per-value enum help and snippets ([reference](../reference/dsc.md#editor-schemas)). The repo has no `.vscode/settings.json` to map them to `*.dsc.resource.json` and `*.dsc.yaml`, and the manifests keep the canonical `$schema`, since other tools may reject the extra keywords. Worth doing if manifests get written often enough that the editor's help would save looking things up.
