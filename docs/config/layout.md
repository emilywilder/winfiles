# Layout

The rules for where a document goes in `dsc/`, and why. The overview, with the table of document kinds, is in [architecture.md](../architecture.md).

## Entries

- **An entry is a host's or a user's whole configuration.** It includes modules and host documents, and a home entry also holds the user's own choices on that host as resources, such as their WSL distributions and `~/.wslconfig`. `dependsOn` orders what's in an entry, but it can't name another entry's resources. `winfiles.ps1 install` and `winfiles.ps1 check` run the system and home entries as one aggregate, system first.
- **Privilege is declared once.** `metadata.winget.securityContext: elevated` at the top of the system entry covers everything it includes ([run/flat-configuration.md](../run/flat-configuration.md)). The home entry has none.
- **Entries stay directly in `dsc/`.** A `configurationFile` resolves from the folder of the document passed to `--file`, nested Includes too, and DSC 3.3.0 refuses `..` ([reference](../reference/dsc.md#include-paths)).

## Privilege first, then concern

Both `dsc/modules/` and `dsc/hosts/<host>/` split into **`system/`**, for any document with a resource that needs elevation, and **`home/`**, for the rest, following the winget rule in [winget.md](winget.md). A system entry includes only from `system/` folders and a home entry only from `home/` ones, so each Include's path shows its privilege; a test checks this. A concern with both halves uses the same name in each (`modules/system/wsl.dsc.yaml` and `modules/home/wsl.dsc.yaml`), so `dsc/modules/*/wsl.dsc.yaml` finds both.

Trade-off: a concern's two halves sit in two folders. Most concerns have one side (Scoop, the computer name, Remote Desktop, the policies), and only PowerShell, the settings and WSL have both. Revisit if most concerns come to have both halves.

## Modules, hosts and users

- **Modules don't include each other.** A module that included a sibling would work from its entry or on its own, never both, and two modules including the same one would apply it twice ([ruled-out.md](../reference/ruled-out.md#modules-that-include-each-other)). So each module also runs on its own, and entries state the ordering.
- **Modules hold nothing specific to one person or machine,** so the project can become a starting point for others. A document that needs elevation for any of its resources goes in `modules/system`.
- **`dsc/hosts/<host>/`** holds that host's own choices: its features, its package documents (`packages-<category>.dsc.yaml`, split however the host likes), its Scoop buckets, software for its hardware, `manual.yaml` and `# post-install:` notes. A host may include another's documents where it wants exactly the same choices, as `vm` does iris's packages; one that wants most of them copies the file.
- **A user's choices on a host,** what lives in their home directory or HKCU, go in their home entry, not in a host's folder. Trade-off: the user's WSL resources only run with the rest of their home configuration. Revisit, with a `dsc/users/<user>@<host>/` folder of documents, once a user has several separate concerns, the way a host does.
- **The hosts** are `iris`; `vm`, for test VMs, which has iris's packages and none of its hardware; and `vm-quick`, a quicker test host ([dev/test-vm.md](../dev/test-vm.md)). To add a host, create `dsc/hosts/<host>/{system,home}/` with its features, packages and Scoop buckets (copying or including another host's), copy a pair of entries, and edit their Includes.
- `dsc/templates/` is reference material, deliberately left out of every configuration.

Trade-off: each entry repeats its module list, where Nix would import a common file. A shared layer that only includes modules would work (below). Revisit once there's a third real host, or the lists drift.

## Not done yet

- **A shared layer of modules for `iris` and `vm`.** A document that only includes modules, with paths from `dsc/`, which both entries include in place of their 13 identical system Includes (and a home counterpart). It would also stop a module being added to `iris` and not to `vm`. `vm-quick` has its own smaller set, so it would keep its list. The layer runs from an entry but not on its own; the modules it includes stay leaves that still do. Costs: resource messages below `trace` are lost when an entry is run by hand (not in the flat copy), two layers in one entry can't share a module, and the ordering on a host's `Features` stays in the entry. Revisit once there's a third real host, or the lists drift.
- **Move entries out of `dsc/`.** DSC 3.3.0's refusal of `..` is why entries stay there. With flattening reading the files itself, the entries could move later; a separate decision.
- **Bicep in place of the YAML documents.** It would bring real modules with parameters, loops and per-host parameter files, but `bicep local-deploy` only applies (no test or what-if), the documents would stop being DSC's, and both pieces are experimental. The research, and when to revisit, is in [reference/bicep.md](../reference/bicep.md).
