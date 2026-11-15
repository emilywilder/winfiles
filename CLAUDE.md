# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Personal Windows 11 configuration management (a counterpart to the user's Linux/macOS dotfiles), described with DSC v3 and driven by the root `justfile`. It's a work in progress. There is no build. `just test` runs Pester tests of the `Winfiles/*` resources' own logic against fakes; anything that depends on how Windows, winget or an installer really behaves is still tested by running DSC `test`/`get` against the live machine, or a clean install in the test VM.

Before changing an area, read its doc. Each records what was checked, when, and the trade-offs behind it:

- `docs/install.md`: `bootstrap.cmd`, what `just install` runs and in what order, UAC and restarts, how failures are handled, `# post-install:` notes, `Invoke-Clean.ps1`
- `docs/tooling.md`: mise and `mise.lock`, DSC from mise (pinned, extensions removed, not the Store), `just dsc` and `DSC_RESOURCE_PATH`, `just dsc-export`, the full recipe list, `winfiles-rebuild`
- `docs/testing.md`: the Pester tests and their fakes, what isn't tested, `demos/`, the test VM
- `docs/architecture.md`: structure, optional features, packages (winget, Scoop, by hand), WSL, custom resources, how PowerShell is set up
- `docs/upstream-drift.md`: where winfiles deliberately differs from the project a setting came from

Keep these docs in step with the code. When a decision is a trade-off, write it down where the area is documented as `Trade-off: ... Revisit if ...`, and date what was checked (for example "checked 2026-11-14 in the test VM").

## Commands

```powershell
.\bootstrap.cmd iris         # fresh install, unelevated, from the repo; rerun after the restart it asks for
just                         # list recipes
just help <recipe>           # a recipe's usage, plus Get-Help for the scripts its *args go to
just install [host] [user]   # system, then home, then check, then post-install (docs/install.md)
just system [host]           # apply the system configuration (elevates)
just home [user] [host]      # apply the home configuration (unelevated)
just check [host] [user]     # test both configurations; exits 1 if anything is missing
just test [paths]            # run the Pester tests (default: tests); changes nothing on the machine
just dsc config test --file dsc/iris.system.dsc.yaml               # one configuration, as full JSON
just dsc config test --file dsc/modules/system/policies.dsc.yaml   # one module on its own
just dsc config set  --file <doc>                                  # apply (HKLM resources need elevation)
just test-vm-run <name> 'mise exec -- just check vm'               # read results in a test VM
```

- Run DSC through `just dsc` (or under `mise exec`), never a bare `dsc`: it sets `DSC_RESOURCE_PATH`, which is how the `Winfiles/*` resources are found.
- `dsc config test` exits 0 whatever it finds, so read its results, not its exit code. Run `test` before `set`: `set` changes the real machine (it installs packages, writes the registry, and rewrites profile stubs).
- Recipes run pwsh without the profile; a recipe that comes to need something from it has to set it up itself.
- A test VM's computer name doesn't pick its configuration, so pass the host (`just install vm` or `just install vm-quick`, or `-HostName vm` to the bootstrap). Run the bootstrap in the VM's desktop, not over PowerShell Direct, which runs elevated with no UAC.
- DSC is pinned in `mise.toml` (currently 3.3.0) and these docs record version-specific behaviour, so read `docs/tooling.md` before bumping it.

## Layout

- `dsc/<host>.system.dsc.yaml` (elevated, `just system`) and `dsc/<user>@<host>.home.dsc.yaml` (unelevated, `just home`) only list Includes. They stay directly in `dsc/`, because DSC 3.3.0 refuses `..` in `configurationFile`. A `dependsOn` can't cross between the two; `just install` orders them.
- `dsc/modules/{system,home}/`: reusable documents with nothing specific to one person or machine. Modules don't include each other. A document that needs elevation for any of its resources goes in `system`.
- `dsc/hosts/<host>/`: one machine's differences (`features.dsc.yaml`, `manual.yaml`, host package lists, `# post-install:` comments). The hosts are `iris`, `vm`, for test VMs, and `vm-quick`, a quicker test host (`docs/testing.md`).
- `dsc/resources/`: the `Winfiles/*` resources (manifest plus script). `dsc/templates/`: reference material, in no configuration.
- `scripts/` (run by the recipes), `tests/` (`resources/`, `scripts/`, `fakes/`), `demos/` (run by hand, nothing to pass or fail).
- To add a package, see "Packages" in `docs/architecture.md`: which module it goes in, and `home` or `system`, depends on its installer.

DSC document conventions (copy them from existing documents):

- Each document has the `$schema` (2023/08 document.json) and `metadata.winget.processor.identifier: dscv3` header, which keeps it usable with `winget configure`.
- Configurable paths and keys go in `parameters` with a `defaultValue`. Paths are stored with `%VAR%` placeholders and expanded inside scripts with `[Environment]::ExpandEnvironmentVariables`.
- Each resource has a `metadata.description`, except `Microsoft.Windows/RegistryList` and `Microsoft.Windows/Service`, which get a comment instead: DSC 3.3.0 passes the description to the resource as `_metadata`, which their synthetic test counts as a difference, so `test` would always report false and every `set` would rewrite the values. Ordering is set with `dependsOn: "[resourceId('<type>', '<name>')]"`.
- Several registry values in a document go in one `Microsoft.Windows/RegistryList`, which also creates their keys. Trade-off: a drifted value reports the whole list as false with `differingProperties: registryEntries`, so finding which one means reading `actualState`; revisit if that gets in the way.
- Prefer DSC built-in resources (`Microsoft.Windows/Registry`, `Microsoft.WinGet/Package`, `Microsoft.DSC/Include`, ...) over scripts. Use `Microsoft.DSC.Transitional/PowerShellScript` only when no built-in can do the job, or one is broken. In that case, add a comment saying which built-in was ruled out and why. Pass the script's data through `input`, and make `getScript`/`testScript`/`setScript` idempotent (`testScript` returns a bool).
- A setting taken from another project, such as Microsoft's WindowsDeveloperConfig, says so in its comment. If winfiles does it differently on purpose, add an entry to `docs/upstream-drift.md` (upstream file at a pinned commit, what each side does, evidence, revisit condition) and point to it from the comment.

Custom resource conventions (`dsc/resources/`, more in `docs/architecture.md`): each script dot-sources `common.ps1` (preferences, `Read-ResourceInput`, `Write-ResourceMessage`) and has no `[CmdletBinding()]` or `[Parameter()]`, so `$input` can hold the JSON from stdin. DSC logs plain stderr lines at `trace` only, so a failure has to go through `Write-ResourceMessage error`, and each script declares its own `trap` for uncaught errors (a trap only covers the scope that declares it, even when dot-sourced). A list resource keeps an item that fails in its `missing` property and still exits 0, because DSC stops the whole configuration when a resource exits non-zero.

Script conventions for `scripts/` (copy them from existing scripts):

- A script starts with its `#Requires` lines, then a blank line, then comment-based help (`.SYNOPSIS`, plus `.DESCRIPTION` and `.EXAMPLE` where they help), then `param()`. Without the blank line Get-Help silently ignores the help and shows only the script's name or syntax. `tests/scripts/Help.Tests.ps1` checks this for every script with a `.SYNOPSIS`, so a new script is covered without adding a test.
- Its parameters are declared in `param()` with types, and `[Parameter(Mandatory)]` where needed, because `just help <recipe>` builds the usage of a recipe's `*args` from Get-Help's syntax data. `.EXAMPLE` commands are written to run from the repo root, as the recipes do (`./scripts/<name>.ps1 ...`, or the full command when the script needs elevation or Windows PowerShell).
- Files that are only dot-sourced (`dsclog.ps1`, `testvm.ps1`) have a plain comment at the top instead of help.
- A new script gets tests in `tests/scripts/` (see `docs/testing.md`), unless it's in the "Not tested" list there. Keep the fakes basic: extend one when a test needs it, rather than modelling Windows.

## Constraints

- winfiles must never modify the persistent `PATH`. The pwsh profile (kept outside this repo) owns `PATH`, including the junctioned Scripts folder. Changing `PATH` for a single process inside a recipe is fine. A tool that winfiles drives may change the persistent `PATH` only if the user has approved that tool. So far Scoop (its installer, and manifests with `env_add_path` such as nodejs and python) and winget (package installs and uninstalls) are approved. Ask before relying on any other tool doing it.
- Commit messages use conventional commits plus gitmoji, scoped by area, for example `feat(dsc): ✨  ...`, `refactor(dsc): ♻️  ...`, `chore: 📝  ...`. Put two spaces after the gitmoji: terminals draw emoji such as the recycling symbol wider than the cell they reserve, which hides a single space.
