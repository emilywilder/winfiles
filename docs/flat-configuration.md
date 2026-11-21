# Flat configuration

How winfiles turns its checked-in DSC documents into the documents it runs, why, and where that stops. Timings are in `benchmarks.md` and VM results in `reference/test-vm.md`; the tiers and their trade-off are in `architecture.md`.

## Concept

winfiles is organized like Nix (hosts, modules, a system entry and a per-user entry per machine) and run like DSC: the checked-in documents use only what DSC itself understands, so every one of them runs under plain `just dsc config test|set --file <document>` and gives DSC's own output. Three tiers keep it that way:

| Tier | What it is | May contain |
|---|---|---|
| Checked-in documents | `dsc/`: entries, modules, hosts | What DSC understands, plus metadata it ignores (`metadata.winget.securityContext`) |
| Derived documents | `~/.local/state/winfiles/flat/`: the flat copy, the batches, the aggregate | Never edited by hand; derived from the checked-in ones every run |
| Execution | `Invoke-Configuration.ps1`, `Set-RestartStage.ps1` | Privilege and restarts, which DSC has no notion of |

The flat copy belongs to the middle tier. Its rule: **winfiles' scripts only turn documents into documents** (flatten, batch, aggregate). DSC still does all the work on resources, and with the scripts gone the checked-in documents still apply, one at a time, in an order you choose.

Why flatten at all. DSC 3.3.0's `Microsoft.DSC/Include` runs each included document in a child `dsc`, and that costs:

- **The progress bar.** It counts only the entry's top level, so it sat at "4/8 Set 'Packages'" for a whole module, and the child's stderr isn't a console, so the child draws no bar. Flat, one dsc runs every resource and the bar names each one ("37/54 Set 'Malwarebytes.Malwarebytes'").
- **Messages.** A resource's messages below `trace` are lost through two levels of Include (`architecture.md`).
- **`dependsOn` across privilege.** An entry document has one privilege, so a `dependsOn` couldn't cross from elevated to unelevated resources. Flat, privilege is per resource, so it can.
- **Start-up.** One dsc instead of one per Include: about 15s less per configuration in `set` and `check` (iris, 2026-11-17/18).

## Implementation

`scripts/ConvertTo-FlatConfiguration.ps1` reads the documents with `yq -o json` and `ConvertFrom-Json -DateKind String`, and writes with `yq -p json -o yaml -P` (YAML, readable, from mise). Comments aren't kept.

**Flattening.** An Include is replaced by the resources of the document its `configurationFile` names, resolved from the entry's folder as DSC does, at any depth. Its `parametersContent` values become the defaults of the included document's parameters, and the documents' parameters are merged. An Include's `dependsOn` becomes `dependsOn` on every resource inside it, for each resource of the dependent Include (or the resource itself, outside any Include), so DSC still orders and still stops at a failure.

**Refused, not guessed.** An Include that includes itself (directly or through others, naming the chain), a `dependsOn` loop in the result (naming the resources), an expression in `parametersContent`, an Include property other than `configurationFile`, `parametersContent` and `dependsOn`, a top-level key other than `$schema`, `metadata`, `parameters` and `resources`, a `dependsOn` that isn't `resourceId()`, a resource or parameter name used twice across the documents, a parameter declared twice, and an Include that carries a `securityContext`. It doesn't refuse `..` in a `configurationFile`, which DSC 3.3.0 does, so an entry using one would pass here and fail by hand: keep entries directly in `dsc/`.

**Privilege.** `metadata.winget.securityContext: elevated` is Microsoft's name for it, and plain dsc ignores it at document level (checked 2026-11-19, dsc 3.3.0). A resource takes its own tag, else its document's, else the including document's; `dsc/<host>.system.dsc.yaml` is tagged once, `dsc/<user>@<host>.home.dsc.yaml` not at all. Only `elevated` is accepted. The tag is removed from every output, because dsc hands a resource its metadata, and the resources that are tested as a whole (`Microsoft.Windows/RegistryList`, `Microsoft.Windows/Service`) count it as a difference; those are never tagged themselves and sit in a tagged document.

**Batches (`-Batch`).** The flat resources are split into batches of one level, as few as `dependsOn` allows (Kahn's algorithm that stays on the current level while a resource of it is ready). A `dependsOn` on an earlier batch is dropped, since running them in order satisfies it, and each batch keeps only the parameters its resources use. Files are `<entry>.<n>-<level>.dsc.yaml`; earlier ones for the same destination are deleted first. The result is an object per batch: `Path`, `Level`, `Stage` and `Resources`.

**Aggregate.** Several entries (`just install` and `just check` give the system one, then the home one) are flattened as one: the first's header and resources first wherever `dependsOn` doesn't say otherwise, names unique across them. A `dependsOn` can't name another entry's resources, since the checked-in documents have to run alone.

**First batch (`-First "<type>|<name>;..."`).** The named resources and everything they depend on, at any depth, become the first batch (`Stage` `restart`). They must all be elevated, otherwise it fails with the reason. `Invoke-Configuration.ps1` passes it the resources that reported `_restartRequired` when it tested the elevated batches. Nothing in a document says what needs a restart.

**Who flattens.** Only `scripts/Invoke-Configuration.ps1` (`just system`, `home`, `check`, `install`) and `just flatten <document>` (writes the flat copy to the same place and prints its path, without running anything). `Set-Winfiles.ps1`, `Test-Winfiles.ps1`, `Set-RestartStage.ps1` and `Find-RestartResources.ps1` take what it made and refuse a document that still has an Include, through `Get-RunDocument` in `scripts/dsclog.ps1` (decided 2026-11-19).

A flat copy or batch can be read to see exactly what ran, or applied by hand: `just dsc config set --file <it>`. To compare with the entries themselves, run those under dsc by hand: `just dsc config test --file dsc/<entry>`; the results should match `just check`'s, resource for resource.

## Tests

`tests/scripts/ConvertTo-FlatConfiguration.Tests.ps1` covers each refusal, the tag order, `-Batch`, `-First`, the aggregate and `just flatten`, and flattens every entry in `dsc/`, so a name used twice across modules fails in `just test` rather than at the start of an install.

## Trade-offs

- Trade-off: `just install` and a by-hand `dsc config set` on an entry take different routes to the same resources, and an error names a resource rather than a line in a module. In return: a bar that names each package, less start-up, results with no Include nesting, and per-resource privilege. Revisit if the entries need an Include feature the copy doesn't cover, or if DSC lets an Include's `dsc` draw its own bar.
- Trade-off: `check` no longer catches a difference between the copy and the entries by itself (the `flat=false` switch went on 2026-11-19, with `-NoFlatten`). Revisit if a difference ever shows up in a by-hand run.
- Trade-off: a batch is a dsc process of its own, so the bar restarts at each and a run pays dsc's start-up per batch (the number of level changes, not of resources). Revisit if an entry needs many batches.
- Trade-off: the flattener could allow more than the checked-in documents may do (modules that include modules, a shared layer), since only the copy needs to be flat. That would break "every document runs under plain dsc" for a module run by hand, so it doesn't. Revisit if a third host repeats the same module lists (vm-quick is the third, and they haven't drifted yet).

## Checked

- 2026-11-17, iris: every entry flattens; each resource and parameter equals its source apart from `dependsOn`; `config test` of the flat documents gave the same results as the entries, in 62s against 75s (system) and 73s against 88s (home).
- 2026-11-18, iris: `just check` passed all 118 resources through the flat copies in 136s, against 153s through the entries.
- 2026-11-17, iris: DSC 3.3.0 draws its bar through `tracing-indicatif` on stderr, so capturing stdout (as `dsclog.ps1` does) doesn't hide it; only stderr has to be a console.
- 2026-11-19: each host's system and home documents flatten together without a collision, into one elevated and one user batch (vm-quick 14 and 14 resources, vm 57 and 53, iris 62 and 57).
- 2026-11-19, test VM: `vm-quick` and `vm` installed through the batches (`reference/test-vm.md`). iris wasn't run through them.
