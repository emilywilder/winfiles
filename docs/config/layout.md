# Layout

The rules for where a document goes in `dsc/`, and why. The overview, with the table of document kinds, is in [architecture.md](../architecture.md).

Three kinds of reuse, each in a form plain DSC already has:

| What's reused | Its form | Where |
|---|---|---|
| the logic for one item: a package, a distribution, a file | a resource | `dsc/resources/`, and DSC's own |
| a concern's configuration, varying by a few values | a module: a document with scalar `parameters` | `dsc/modules/{system,home}/` |
| a host's choices: which packages, which values | resources, and Includes with `parametersContent` | `dsc/hosts/<host>/{system,home}/` and the entries |

## Entries

- **An entry is a host's or a user's whole configuration,** like nixfiles' `hosts/<host>/default.nix` and `home.nix`. It includes the modules its host uses, passing the host's values in `parametersContent`, then its host's documents, and orders them with `dependsOn`. A home entry also holds the user's own choices on that host as resources, such as their WSL distributions and `~/.wslconfig`.
- **Entries run under plain DSC.** `winfiles.ps1 dsc config test|set --file <entry>` works and gives DSC's own output. `dependsOn` can't name another entry's resources. `winfiles.ps1 install` and `winfiles.ps1 check` run the system and home entries as one aggregate, system first.
- **Privilege is declared once.** `metadata.winget.securityContext: elevated` at the top of the system entry covers everything it includes ([run/flat-configuration.md](../run/flat-configuration.md)). The home entry has none.
- **Entries stay directly in `dsc/`.** A `configurationFile` resolves from the folder of the document passed to `--file`, nested Includes too, and DSC 3.3.0 refuses `..` ([reference](../reference/dsc.md#include-paths)).
- **Only entries include.** A module or a host's document includes nothing, so every document runs on its own (`winfiles.ps1 dsc config test --file dsc/modules/home/wsl.dsc.yaml`), and what a host is made of is read from its two entries. A test checks it.
- **An entry reaches each document once.** DSC runs a document each time it's included, so it would apply one included twice twice. The flattener fails on a document reached twice, naming both routes, so `winfiles.ps1 test` catches it ([ruled-out.md](../reference/ruled-out.md#a-module-that-includes-what-it-depends-on)).

Trade-off: with no shared layer to import, each entry lists its modules, and `vm`'s entries list iris's documents too ([ruled-out.md](../reference/ruled-out.md#shared-layers-of-includes)). A test catches a document of iris's own that `vm` is missing, but not a module only `iris` includes. Revisit if a module meant for both gets added to one.

## Privilege first, then concern

Both `dsc/modules/` and `dsc/hosts/<host>/` split into **`system/`**, for any document with a resource that needs elevation, and **`home/`**, for the rest, following the winget rule in [winget.md](winget.md). A system entry includes only from `system/` folders and a home entry only from `home/` ones, so each Include's path shows its privilege; a test checks this. A concern with both halves uses the same name in each (`modules/system/wsl.dsc.yaml` and `modules/home/wsl.dsc.yaml`), so `dsc/modules/*/wsl.dsc.yaml` finds both.

Trade-off: a concern's two halves sit in two folders. Most concerns have one side (Scoop, the computer name, Remote Desktop, the policies), and only PowerShell, the settings and WSL have both. Revisit if most concerns come to have both halves.

## Modules

- **A module is code, not a list of a host's items.** It holds one concern's configuration (`powershell`, `settings`, `policies`, `scoop`, `wsl`, `computername`, `remote-desktop`), written once, and takes what varies by host as scalar `parameters`. An entry sets one through `parametersContent` on its Include (`computerName` for each host; `wslSshPort` for a host whose sshd listens elsewhere).
- **Parameters have a `defaultValue`** where one suits every host, so the module runs on its own. `computerName` has none, since no name does; its comment gives the `--parameters` to run it alone.
- **A parameter name is declared once per entry.** The flattener merges every document's parameters into one set and fails on a name declared twice, so a module's parameters are named for it (`wslSshPort`, `scoopInstaller`).
- **What varies in number isn't a parameter.** Packages, buckets, PowerShell modules and distributions are written out one resource each in the host's documents or the user's entry. Trade-off: hosts that share a package each list it. That's what lets hosts differ freely; a list parameter fed to a list resource, or a `copy` loop, would make the documents harder to read for someone who knows DSC but not winfiles ([ruled-out.md](../reference/ruled-out.md#list-resources-for-a-hosts-items)). Revisit if several hosts end up with the same long documents.

## A host's documents

- **`dsc/hosts/<host>/` holds that host's choices:** its features, its package documents (`packages-<category>.dsc.yaml`, split however the host likes), its Scoop buckets and PowerShell modules, and software for its hardware. `manual.yaml` sits at the top of the folder, since it isn't a DSC document.
- **A host may include another host's documents** where it wants exactly the same choices: `vm` includes iris's package, bucket and PowerShell module documents, so a VM run installs what iris does. A host that wants most of one copies it and edits the copy; that's data, which is meant to differ by host.
- **iris** adds its features, `hardware` and the `remote-desktop` module. **`vm`** has its own features and none of iris's hardware or Remote Desktop. **`vm-quick`** has its own few packages, buckets and PowerShell module, and one firewall rule ([dev/test-vm.md](../dev/test-vm.md)).
- **Notes** for what winfiles can't do go in a `# post-install:` comment in a document an entry includes, the entry itself, or `manual.yaml` ([run/post-install.md](../run/post-install.md)).

## Ordering

`dependsOn` can only name a resource in its own document, so how finely things are ordered comes from where resources go:

- **One concern per document,** so an Include's `dependsOn` means just that concern: the Scoop packages wait for the `Scoop Buckets` Include, which waits for `Scoop`, and not for PowerShell or the settings.
- **A prerequisite only one document needs goes in that document,** and its dependents name it by `resourceId`.
- **A prerequisite several documents need gets its own small document,** included once, and only the Includes that need it depend on it (iris's `packages-runtimes.dsc.yaml`).

Trade-off: across documents, order is per document, not per resource. DSC applies resources one at a time and stops at the first failure, so it changes no run today. Revisit if DSC runs resources in parallel, or lets `dependsOn` name a resource inside an Include.

## Users

- **A user's choices on a host,** what lives in their home directory or HKCU, go in their home entry, `dsc/<user>@<host>.home.dsc.yaml`, not in a host's folder. Their `# post-install:` notes go there too. Trade-off: the user's WSL resources only run with the rest of their home configuration. Revisit, with a `dsc/users/<user>@<host>/` folder of documents, once a user has several separate concerns, the way a host does.
- **The hosts** are `iris`; `vm`, for test VMs; and `vm-quick`, a quicker test host. To add a host, create `dsc/hosts/<host>/{system,home}/` with its features, packages, Scoop buckets and PowerShell modules (copying or including another host's), and a pair of entries that include the modules it wants, passing `computerName`, and then those documents.
- `dsc/templates/` is reference material, deliberately left out of every configuration.

## Not done yet

- **Move entries out of `dsc/`.** DSC 3.3.0's refusal of `..` is why entries stay there. With flattening reading the files itself, the entries could move later; a separate decision.
- **Bicep in place of the YAML documents.** It would bring real modules with parameters, loops and per-host parameter files, but `bicep local-deploy` only applies (no test or what-if), the documents would stop being DSC's, and both pieces are experimental. The research, and when to revisit, is in [reference/bicep.md](../reference/bicep.md).
