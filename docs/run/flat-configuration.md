# Flat configuration

How winfiles turns its checked-in DSC documents into the documents it runs, why, and where that stops. The three tests every addition has to pass are in [architecture.md](../architecture.md#organized-like-nix-run-like-dsc), and how a run uses the result is in [flat-configuration.md](flat-configuration.md).

## Tiers

| Tier | What it is | May contain |
|---|---|---|
| Checked-in documents | `dsc/`: entries, modules, hosts' documents | What DSC understands, plus metadata it ignores (`metadata.winget.securityContext`) |
| Derived documents | `~/.local/state/winfiles/flat/`: the flat copy, the batches, the aggregate | Never edited by hand; rewritten from the checked-in ones on every run |
| Execution | `Invoke-Configuration.ps1`, `Set-RestartStage.ps1` | Privilege and restarts, which DSC has no notion of |

The flat copy belongs to the middle tier. Its rule is that winfiles' scripts only turn documents into documents. DSC still does all the work on resources.

## Why flatten

DSC 3.3.0's `Microsoft.DSC/Include` runs each included document in a child `dsc`, and that costs:

- **The progress bar.** It counts only the entry's top level, so it sat at "4/8 Set 'Packages'" for a whole module, and the child draws no bar ([reference](../reference/dsc.md#the-progress-bar)). Flat, one dsc runs every resource, and the bar names each one ("37/54 Set 'Malwarebytes.Malwarebytes'").
- **Messages.** A resource's messages below `trace` are lost through two levels of Include ([reference](../reference/dsc.md#resource-messages-and-levels)).
- **`dependsOn` across privilege.** An entry document has one privilege, so a `dependsOn` couldn't cross from elevated to unelevated resources. Flat, privilege is per resource, so it can.
- **Start-up.** One dsc instead of one per Include: about 15s less per configuration in `set` and `check` ([benchmarks](../benchmarks.md#check)).

## How it works

`scripts/ConvertTo-FlatConfiguration.ps1` reads the documents with `yq -o json` and `ConvertFrom-Json -DateKind String`, and writes them with `yq -p json -o yaml -P`, so the result is readable YAML. Comments aren't kept.

**Flattening.** An Include is replaced by the resources of the document its `configurationFile` names. That path is resolved from the entry's folder, as DSC does, at any depth.
- An Include's `parametersContent` values become the defaults of the included document's parameters, and all the documents' parameters are merged.
- An Include's `dependsOn` becomes a `dependsOn` on every resource inside it, so DSC still orders the resources and still stops at a failure.

**Refused, not guessed.** It fails, naming the document, on:
- an Include that includes itself, directly or through others (naming the chain);
- a document the entry reaches twice, however its path is written and whatever values each Include passes (naming both routes), since DSC would apply it twice ([config/layout.md](../config/layout.md#entries));
- a `dependsOn` loop in the result (naming the resources);
- an expression in `parametersContent`;
- an Include property other than `configurationFile`, `parametersContent` and `dependsOn`;
- a top-level key other than `$schema`, `metadata`, `parameters` and `resources`;
- a `dependsOn` that isn't `resourceId()`;
- a resource or parameter name used twice across the documents, or a parameter declared twice;
- an Include that carries a `securityContext`.

It doesn't refuse `..` in a `configurationFile`, which DSC 3.3.0 does, so an entry using one would pass here and fail by hand. Keep entries directly in `dsc/` (below).

**Privilege.** `metadata.winget.securityContext: elevated` is Microsoft's name for it, and plain dsc ignores it at document level ([reference](../reference/dsc.md#document-level-securitycontext)).
- A resource takes its own tag, else its document's, else the including document's. So `dsc/<host>.system.dsc.yaml` is tagged once, and `dsc/<user>@<host>.home.dsc.yaml` not at all.
- Only `elevated` is accepted.
- The tag is removed from every output, because dsc hands a resource its metadata, and `Microsoft.Windows/RegistryList` and `Microsoft.Windows/Service` count it as a difference ([reference](../reference/dsc.md#metadatadescription-and-whole-resource-tests)). So those two are never tagged themselves; they sit in a tagged document.

**Batches (`-Batch`).** The flat resources are split into batches of one level, as few as `dependsOn` allows. The order is Kahn's algorithm, staying on the current level while a resource of that level is ready.
- A `dependsOn` on an earlier batch is dropped, since running the batches in order satisfies it.
- Each batch keeps only the parameters its resources use.
- Files are named `<entry>.<n>-<level>.dsc.yaml`, and earlier ones for the same destination are deleted first.
- The result is an object per batch, with `Path`, `Level`, `Stage` and `Resources`.

`Invoke-Configuration.ps1 set|test <entry>...` runs each batch as its own dsc process, through `Invoke-AsAdmin.ps1` or `Invoke-AsUser.ps1` ([privilege.md](privilege.md)):
- A `set` stops at the first batch that fails, with its exit code.
- A `test` runs every batch, lists what differs under each batch's "N of M in desired state", and ends with one total.

**Aggregate.** Several entries are flattened as one: `winfiles.ps1 install` and `winfiles.ps1 check` give the system entry, then the home one. The first entry's header and resources come first wherever `dependsOn` doesn't say otherwise, and names must be unique across all of them. A `dependsOn` still can't name another entry's resources, since the checked-in documents have to run alone.

**First batch (`-First "<type>|<name>;..."`).** The named resources, and everything they depend on at any depth, become the first batch (stage `restart`). They must all be elevated, or it fails with the reason. `Invoke-Configuration.ps1` passes it the resources that reported `_restartRequired` ([restarts.md](restarts.md)).

**Who flattens.** Only `scripts/Invoke-Configuration.ps1` (`winfiles.ps1 system`, `home`, `check` and `install`) and `winfiles.ps1 flatten <document>`, which writes the flat copy to the same place and prints its path, without running anything. `Set-Winfiles.ps1`, `Test-Winfiles.ps1`, `Set-RestartStage.ps1` and `Find-RestartResource.ps1` take what it made, and refuse a document that still has an Include (`Get-RunDocument` in `scripts/dsclog.ps1`).

A flat copy or batch can be read to see exactly what ran, or applied by hand with `winfiles.ps1 dsc config set --file <it>`. To compare with the entries themselves, run `winfiles.ps1 dsc config test --file dsc/<entry>`. The results should match `winfiles.ps1 check`'s, resource for resource. `tests/scripts/ConvertTo-FlatConfiguration.Tests.ps1` covers the rest ([dev/script-tests.md](../dev/script-tests.md)).

## Trade-offs

- `winfiles.ps1 install` and a by-hand `dsc config set` on an entry take different routes to the same resources, and an error names a resource rather than a line in a module. In return: a bar that names each package, less start-up, results with no Include nesting, and per-resource privilege. Revisit if the entries need an Include feature the copy doesn't cover, or if DSC lets an Include's `dsc` draw its own bar.
- `check` doesn't catch a difference between the copy and the entries by itself; that takes a by-hand run. Revisit if a difference ever shows up in one.
- A batch is a dsc process of its own, so the bar restarts at each batch, and a run pays dsc's start-up per batch: once per change of level, not per resource. Today every host has one elevated batch and one user batch, plus the restart batch. Revisit if an entry needs many batches.
- The flattener follows Includes at any depth, as DSC does, though in `dsc/` only entries include, which a test checks and the flattener doesn't ([config/layout.md](../config/layout.md#entries)). It gives an Include no meaning DSC doesn't, such as applying a document reached twice only once, because the entry run by hand would then do something else ([ruled-out.md](../reference/ruled-out.md#a-dialect-of-the-documents)).

## Not done yet

- **Run iris through the batches.** Only `vm-quick` and `vm` have been installed this way. Worth it before the next install on iris.
- **Refuse `..` in a `configurationFile`,** as DSC 3.3.0 does, so a bad entry fails `winfiles.ps1 install` as it fails by hand.
- **Refuse a resource-level `securityContext` in a flat document run by hand.** The flattener removes the tag from its output, but a flat document written another way, with a tag on a whole-resource-tested type, would count it as a difference. Low value: nothing writes one.
