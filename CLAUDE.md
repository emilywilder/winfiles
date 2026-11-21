# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Personal Windows 11 configuration management (a counterpart to the user's Linux/macOS dotfiles), described with DSC v3 and driven by the root `justfile`. It's a work in progress, and there is no build. `just test` runs Pester tests of winfiles' own logic against fakes. How Windows, winget or an installer really behaves is checked with DSC `test`/`get` on the live machine, or a clean install in the test VM.

## Docs

`docs/README.md` lists every doc with what it covers. Before changing an area, read its doc.

| Where | What |
|---|---|
| `docs/architecture.md`, `docs/install.md` | the overviews: how the configuration is laid out, and what a run does in order, each area in a paragraph that links to its doc |
| `docs/run/` | how a run works: the bootstrap, privilege, the flat copy, restarts, the resume, the clean environment, what a run says |
| `docs/config/` | what is configured, and how: features, winget, Scoop, manual installs, WSL, PowerShell, the computer name, the custom resources |
| `docs/dev/` | working on winfiles: tests, the test VM, tooling and recipes, dependencies |
| `docs/reference/` | dated facts about tools winfiles doesn't own (`windows.md` also covers 5.1, pwsh, mise, just and gsudo), and `ruled-out.md` |
| `docs/benchmarks.md` | every timing, with date, machine, commit and sample count |
| `docs/upstream-drift.md` | where winfiles deliberately differs from the project a setting came from |

Keep the docs in step with the code, with each kind of content in one place:

- **One subject per file.** A new area gets its own file in the folder it belongs to, and a line in `docs/README.md`, rather than a section in a doc about something else.
- **The overviews** stay short: what happens and where it's covered, with no trade-offs or edge cases. Those go in the area doc.
- **An area doc** says what happens, why, and its trade-offs, as `Trade-off: ... Revisit if ...` in a sentence or two. It links to evidence rather than quoting it, and doesn't tell how the area got there; git history has that.
- **A fact about a tool's behaviour** goes in `docs/reference/`, with date, version and where it was checked ("Checked: 2026-11-14, test VM, winget 1.29.380"), and what relies on it.
- **A timing** goes in `docs/benchmarks.md`. An area doc may give a rounded figure and link there.
- **An approach rejected** after trying it, or reasoning it through, goes in `docs/reference/ruled-out.md`. Work nothing needs yet goes at the end of its area doc, under `## Not done yet`: what it is, why it isn't done, and what would make it worth doing. Delete an item when it's done or its reason goes away. `git grep -n -A1 "## Not done yet" docs` lists them all.
- **A new dependency:** when a recipe, script or document starts relying on something new, update `docs/dev/dependencies.md`.

## Commands

```powershell
.\bootstrap.cmd              # fresh install, unelevated: winget, mise and mise.toml's tools; applies nothing
.\install.cmd <host>         # then: just install in a clean environment; resumes after its restart once Enter is pressed
just                         # list recipes
just help <recipe>           # a recipe's usage, plus Get-Help for the scripts its *args go to
just install [host] [user]   # system and home as one aggregate, then check, then post-install
just system [host]           # apply the system configuration (elevates unless the shell already is)
just home [user] [host]      # apply the home configuration (unelevated, even from an elevated shell)
just check [host] [user]     # test both configurations, with one total; exits 1 if anything is missing (elevates)
just test [paths]            # Pester tests (default: tests); changes nothing on the machine
just flatten <doc>           # write the flat copy a run would use, and print its path
just dsc config test --file dsc/iris.system.dsc.yaml               # one configuration, as full JSON
just dsc config test --file dsc/modules/system/policies.dsc.yaml   # one module on its own
just dsc config set  --file <doc>                                  # apply (HKLM resources need elevation)
just test-vm-run <name> 'mise exec -- just check vm'               # read results in a test VM
just test-vm-unelevated <name> 'cmd /c .\install.cmd vm-quick'     # start a command in a test VM unelevated
```

- Run DSC through `just dsc` (or under `mise exec`), never a bare `dsc`: it sets `DSC_RESOURCE_PATH`, which is how the `Winfiles/*` resources are found.
- `dsc config test` exits 0 whatever it finds, so read its results. Run `test` before `set`: `set` changes the real machine.
- Recipes run pwsh without the profile; a recipe that needs something from it sets it up itself.
- In a test VM, pass the host (`vm` or `vm-quick`): the computer name doesn't pick it. Run `bootstrap.cmd` and `install.cmd` in the VM's desktop or through `just test-vm-unelevated`, never `test-vm-run`, which is elevated with no UAC.
- DSC is pinned in `mise.toml` (3.3.0), and `docs/reference/dsc.md` records version-specific behaviour: read `docs/dev/tooling.md` before bumping it.

## Layout

The layout is summed up in `docs/architecture.md`, and its rules and reasons are in `docs/config/layout.md`.

- **`dsc/<host>.system.dsc.yaml`** (elevated) and **`dsc/<user>@<host>.home.dsc.yaml`** (unelevated) are the entries. They only list Includes, and stay directly in `dsc/`, since DSC refuses `..` in `configurationFile`.
  - Privilege is declared by a document or a resource, never an Include: `metadata.winget.securityContext: elevated` at the top of the system entry covers everything it includes.
  - A `dependsOn` can't name another entry's resources.
  - No document lists restarts: resources report `_restartRequired`.
- **`dsc/modules/{system,home}/`** holds reusable documents, with nothing specific to one person or machine. Modules don't include each other; entries order them with `dependsOn`. A document that needs elevation for any resource goes in `system`.
- **`dsc/hosts/<host>/`** holds one machine's differences (`features.dsc.yaml`, `manual.yaml`, host packages, `# post-install:` comments). The hosts are `iris`, `vm` and `vm-quick`.
- **`dsc/users/<user>@<host>/`** holds one user's choices on a host: what lives in their home directory or HKCU, such as `wsl.dsc.yaml`. A distribution there needs the host's system entry to include `modules/system/wsl-platform.dsc.yaml`; a test checks this.
- **`dsc/resources/`** holds the `Winfiles/*` resources. `dsc/templates/` is reference material, in no configuration.
- **Other folders:** `scripts/` (run by the recipes); `tests/` (`resources/`, `scripts/`, `fakes/`); `demos/` (watched by hand); `surveys/` (measure real tools, usually in the test VM, never run by `just test`).
- **To add a package,** see `docs/config/packages.md` and `docs/config/winget.md`.

Every checked-in document has to keep running under plain `just dsc config test|set --file <it>`. winfiles' scripts turn documents into documents, and never add a dialect.

## DSC document conventions

Copy them from existing documents.

- **Header.** The `$schema` (2023/08 document.json) and `metadata.winget.processor.identifier: dscv3`, which keeps the document usable with `winget configure`.
- **Parameters.** Configurable paths and keys go in `parameters`, with a `defaultValue`. Paths use `%VAR%` placeholders, expanded in scripts with `[Environment]::ExpandEnvironmentVariables`.
- **Descriptions.** Each resource has a `metadata.description`, except `Microsoft.Windows/RegistryList` and `Microsoft.Windows/Service`, which get a comment instead: a description makes their `test` always report false (`docs/reference/dsc.md`).
- **Ordering** is set with `dependsOn: "[resourceId('<type>', '<name>')]"`.
- **Registry values.** Several values in a document go in one `Microsoft.Windows/RegistryList`, which also creates their keys. Trade-off: a drifted value reports the whole list as false, so finding which one means reading `actualState`. Revisit if that gets in the way.
- **Built-ins first.** Prefer DSC built-in resources over scripts. Use `Microsoft.DSC.Transitional/PowerShellScript` only when no built-in can do the job, or one is broken, with a comment saying which built-in was ruled out and why. Pass its data through `input`, and make `getScript`, `testScript` and `setScript` idempotent (`testScript` returns a bool).
- **Upstream settings.** A setting taken from another project, such as WindowsDeveloperConfig, says so in its comment. If winfiles does it differently on purpose, add an entry to `docs/upstream-drift.md` and point to it from the comment.

## Custom resource conventions

More in `docs/config/resources.md`.

- Each script dot-sources `common.ps1`, and has no `[CmdletBinding()]` or `[Parameter()]`, so `$input` can hold the JSON from stdin.
- Report a failure through `Write-ResourceMessage error`, since DSC shows plain stderr only at `trace`. Each script declares its own `trap`, because a trap only covers the scope that declares it.
- A list resource keeps an item that fails in its `missing` property and still exits 0, because DSC stops the whole configuration on a non-zero exit.

## Script conventions

Copy them from existing scripts in `scripts/`.

- **Help.** A script starts with its `#Requires` lines, a blank line, comment-based help (`.SYNOPSIS`, plus `.DESCRIPTION` and `.EXAMPLE` where they help), then `param()`. Without the blank line, Get-Help ignores the help; `tests/scripts/Help.Tests.ps1` checks it.
- **Parameters** are declared in `param()` with types, and `[Parameter(Mandatory)]` where needed, because `just help` builds a recipe's usage from them. `.EXAMPLE` commands run from the repo root.
- **Dot-sourced files** (`dsclog.ps1`, `testvm.ps1`, `miseignore.ps1`, `winlog.ps1`, `privilege.ps1`) have a plain comment at the top instead of help.
- **Exceptions:**
  - `Invoke-Clean.ps1` checks its pwsh version explicitly instead of with `#Requires`, since a recipe line carries on past a failed `#Requires` and reports 0.
  - `Start-Clean.ps1`, `Invoke-Install.ps1` and `Resume-Winfiles.ps1` run under Windows PowerShell 5.1, so they keep to 5.1 syntax and pass no double quotes inside arguments.
- **Progress** is recorded with `Write-WinfilesLog` (file only, `run.log`). The console gets `Write-Host`, and only failures, warnings and results. Don't make the logger print.
- **Privilege.** A step that needs a privilege goes through `scripts/Invoke-AsAdmin.ps1` or `scripts/Invoke-AsUser.ps1`, which use gsudo only when the shell's privilege differs. Don't call gsudo from a recipe. Their test overrides are `WINFILES_ELEVATED` and `WINFILES_GSUDO`.
- **Tests.** A new script gets tests in `tests/scripts/` unless it's in the "Not tested" list in `docs/dev/testing.md`. Keep the fakes basic.

## Constraints

- **Never modify the persistent `PATH`.** The pwsh profile, kept outside this repo, owns it. Changing `PATH` for one process inside a recipe is fine. A tool winfiles drives may change it only if the user has approved that tool. So far that's Scoop (its installer, and manifests with `env_add_path`) and winget (installs and uninstalls). Ask before relying on any other tool doing it.
- **Commit messages** use conventional commits plus gitmoji, scoped by area, for example `feat(dsc): ✨  ...` or `chore: 📝  ...`. Put two spaces after the gitmoji, since terminals draw some emoji wider than their cell and hide a single space.
