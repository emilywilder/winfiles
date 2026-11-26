# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Personal Windows 11 configuration management (a counterpart to the user's Linux/macOS nix flake config), described with DSC v3 and driven by a command runner: `winfiles.ps1` at the root, with its commands in `commands.jsonc`, see [Commands](#commands).

The `test` command runs Pester tests of winfiles' own logic against fakes. How Windows, winget or an installer really behaves is checked with DSC `test`/`get` on the live machine, or a clean install in the test VM.

## Docs

`docs/README.md` lists every doc with what it covers. Before changing an area, read its doc.

| Where | What |
|---|---|
| `docs/architecture.md`, `docs/install.md` | the overviews: how the configuration is laid out, and what a run does in order, each area in a paragraph that links to its doc |
| `docs/run/` | how a run works: the bootstrap, privilege, the flat copy, restarts, the resume, the clean environment, what a run says |
| `docs/config/` | what is configured, and how: features, winget, Scoop, manual installs, WSL, PowerShell, settings and policies, the computer name, the custom resources |
| `docs/dev/` | working on winfiles: tests, the test VM, tooling and commands, dependencies |
| `docs/reference/` | dated facts about tools winfiles doesn't own (`windows.md` also covers 5.1, pwsh, mise and gsudo), and `ruled-out.md` |
| `docs/benchmarks.md` | every timing, with date, machine, commit and sample count |

Keep the docs in step with the code, with each kind of content in one place:

- **One subject per file.** A new area gets its own file in the folder it belongs to, and a line in `docs/README.md`, rather than a section in a doc about something else.
- **The overviews** stay short: what happens and where it's covered, with no trade-offs or edge cases. Those go in the area doc.
- **An area doc** says what happens, why, and its trade-offs, as `Trade-off: ... Revisit if ...` in a sentence or two. It links to evidence rather than quoting it, and doesn't tell how the area got there; git history has that.
- **A fact about a tool's behaviour** goes in `docs/reference/`, with date, version and where it was checked ("Checked: 2026-11-14, test VM, winget 1.29.380"), and what relies on it.
- **A timing** goes in `docs/benchmarks.md`. An area doc may give a rounded figure and link there.
- **An approach rejected** after trying it, or reasoning it through, goes in `docs/reference/ruled-out.md`. Work nothing needs yet goes at the end of its area doc, under `## Not done yet`: what it is, why it isn't done, and what would make it worth doing. Delete an item when it's done or its reason goes away. `git grep -n -A1 "## Not done yet" docs` lists them all.
- **A new dependency:** when a command, script or document starts relying on something new, update `docs/dev/dependencies.md`.

## Commands

The command runner is the single entry point for routine work. `winfiles.ps1` (the runner is `scripts/commands.ps1`, and the commands, with their reasons, are data in `commands.jsonc`, described in `docs/dev/tooling.md`) provides:

- **Discovery.** List the commands, and show one command's usage, plus the help of the script its extra arguments go to.
- **Ordered workflows.** Install runs the system and home configurations, then checks them, then runs post-install. Check tests both configurations and reports one total.
- **Safe defaults for DSC and privilege.** The `dsc` command sets `DSC_RESOURCE_PATH`, without which the `Winfiles/*` resources aren't found. Apply commands elevate only when needed. Commands run pwsh without the user's profile, so each sets up what it needs.
- **Read-only versus changing.** Test, lint, flatten and check don't change the machine. The apply commands and install do.
- **VM runs.** Commands that run a command inside a test VM, elevated or unelevated.

The commands, run from the repo root (under `mise exec -- pwsh -File winfiles.ps1 ...` where mise isn't activated):

```powershell
.\bootstrap.cmd                      # fresh install: winget, mise and mise.toml's tools; get environment able to run through the install
.\install.cmd <host>                 # then: switch --restart in a clean environment (restarts and resumes by itself)
.\winfiles.cmd <command> [args]      # any winfiles.ps1 command, from any terminal, before pwsh is on PATH
./winfiles.ps1                       # list commands
./winfiles.ps1 help <command>        # a command's usage, plus Get-Help for the script its extra arguments go to
./winfiles.ps1 switch [host] [user]  # system and home as one aggregate, then check, then post-install; stops for a restart (--restart: restarts and resumes)
./winfiles.ps1 system [host]         # apply the system configuration (elevates unless the shell already is)
./winfiles.ps1 home [user] [host]    # apply the home configuration (unelevated, even from an elevated shell)
./winfiles.ps1 check [host] [user]   # test both configurations; fail if anything is missing (elevates)
./winfiles.ps1 test [paths]          # Pester tests (default: tests); changes nothing on the machine
./winfiles.ps1 lint [paths]          # PSScriptAnalyzer against the PoshCode style guide (docs/dev/style.md)
./winfiles.ps1 flatten <doc>         # write the flat copy a run would use, and print its path
./winfiles.ps1 dsc config test --file dsc/<host>.system.dsc.yaml             # one configuration, as full JSON
./winfiles.ps1 dsc config test --file dsc/modules/system/policies.dsc.yaml   # one module on its own
./winfiles.ps1 dsc config set  --file <doc>                                  # apply (HKLM resources need elevation)
./winfiles.ps1 test-vm-run <name> 'mise exec -- pwsh -File winfiles.ps1 check vm'   # read results in a test VM
./winfiles.ps1 test-vm-unelevated <name> 'cmd /c .\install.cmd vm-quick'     # start a command in a test VM unelevated
```

- Run DSC through the `dsc` command (or under `mise exec`), never a bare `dsc`: it sets `DSC_RESOURCE_PATH`, which is how the `Winfiles/*` resources are found.
- `dsc config test` exits successfully whatever it finds, so read its results. Run `test` before `set`: `set` changes the real machine.
- In a test VM, pass the host (`vm` or `vm-quick`): the computer name doesn't pick it. Run `bootstrap.cmd` and `install.cmd` in the VM's desktop or through the `test-vm-unelevated` command, never `test-vm-run`, which is elevated with no UAC.
- DSC is pinned in `mise.toml` (3.3.0), and `docs/reference/dsc.md` records version-specific behaviour: read `docs/dev/tooling.md` before bumping it.

## Layout

The layout is summed up in `docs/architecture.md`, and its rules and reasons are in `docs/config/layout.md`.

- **`dsc/<host>.system.dsc.yaml`** (elevated) and **`dsc/<user>@<host>.home.dsc.yaml`** (unelevated) are the entries, like nixfiles' `hosts/<host>/default.nix` and `home.nix`. They include the modules the host uses, passing its values in `parametersContent`, then the host's own documents, ordered with `dependsOn`; a home entry also holds the user's own resources on that host (home directory, HKCU, WSL distributions). They stay directly in `dsc/`, since DSC refuses `..` in `configurationFile`.
  - Privilege is declared by a document or a resource, never an Include: `metadata.winget.securityContext: elevated` at the top of the system entry covers everything it includes.
  - A `dependsOn` can't name another entry's resources, or a resource inside another document.
  - No document lists restarts: resources report `_restartRequired`.
- **Privilege first, then concern.** `dsc/modules/` and `dsc/hosts/<host>/` each split into `system/` (any document with a resource that needs elevation) and `home/` (the rest). A system entry includes only from `system/` folders, a home entry only from `home/`; a test checks this.
- **`dsc/modules/{system,home}/`** holds reusable code, one concern per document (`powershell`, `settings`, `policies`, `scoop`, `wsl`, `computername`, `remote-desktop`). What varies by host is a scalar parameter (`computerName`, `wslSshPort`), named for its module, since a parameter name is declared once per entry. A module never holds a host's list of items.
- **`dsc/hosts/<host>/{system,home}/`** holds the host's own choices: `features`, `packages-<category>.dsc.yaml`, `scoop-buckets`, `powershell-modules`, `hardware`. Packages, buckets, modules and distributions are written out one resource each, so hosts differ freely; no list resources, no `copy`. A host that wants exactly another's choices includes its documents (`vm` includes iris's packages); one that wants most of them copies the file.
  - **Only entries include.** Modules and host documents include nothing, so every document also runs on its own; a test checks this.
  - **An entry reaches each document once**, since DSC would apply a document included twice twice. The flattener fails otherwise, so `test` catches it.
  - **Granular ordering** comes from small single-concern documents, and from keeping a prerequisite in the same document as the one resource that needs it; a prerequisite several documents share gets its own document, included once (iris's `packages-runtimes`).
- **`manual.yaml`** sits at the top of `dsc/hosts/<host>/`: it isn't a DSC document.
- **A user's choices on a host** (home directory, HKCU) go in their home entry, not in `dsc/hosts/`. A WSL distribution there needs the host's system entry to include `dsc/modules/system/wsl.dsc.yaml`; a test checks this.
- **`dsc/resources/`** holds the `Winfiles/*` resources.
- **`dsc/templates/`** is reference material, in no configuration.
- **Other folders:** `scripts/` (run by the commands); `tests/` (`resources/`, `scripts/`, `fakes/`); `demos/` (watched by hand); `surveys/` (measure real tools, usually in the test VM, never run by the `test` command). Both are development utilities, not winfiles features: no command runs them, nothing depends on them, and their scripts run from their own folder ([docs/dev/demos-and-surveys.md](docs/dev/demos-and-surveys.md)).
- **To add a package,** see `docs/config/packages.md` and `docs/config/winget.md`.

Every entry has to keep running under plain `dsc config test|set --file <it>` through the `dsc` command, and so does every other document, since none of them includes anything. winfiles' scripts turn documents into documents, and never add a dialect.

## DSC document conventions

Copy them from existing documents.

- **Header.** `$schema`.
  - `dsc schema --type configuration`, from the pinned DSC (run under `mise exec`), is the source of truth for `$schema`: it must be one of the URIs listed in `properties.$schema.enum`. Use the one `dsc resource export` writes, `https://aka.ms/dsc/schemas/v3/bundled/config/document.json`, and check both again when bumping DSC.
  - `winget configure` doesn't accept that URI (`docs/reference/dsc.md#configuration-document-schema-uri`).
- **Parameters.** Configurable paths and keys go in `parameters`, with a `defaultValue`. Paths use `%VAR%` placeholders, expanded in scripts with `[Environment]::ExpandEnvironmentVariables`.
- **Descriptions.** Each resource has a `metadata.description`, except `Microsoft.Windows/RegistryList` and `Microsoft.Windows/Service`, which get a comment instead, because a description breaks their `test` (`docs/reference/dsc.md`).
- **Ordering** is set with `dependsOn: "[resourceId('<type>', '<name>')]"`.
- **Registry values.** Several values in a document go in one `Microsoft.Windows/RegistryList`, which also creates their keys. The trade-off is in `docs/config/settings.md`.
- **Built-ins first.** Prefer DSC built-in resources over scripts. Use `Microsoft.DSC.Transitional/PowerShellScript` only when no built-in can do the job, or one is broken, with a comment saying which built-in was ruled out and why. Pass its data through `input`, and make `getScript`, `testScript` and `setScript` idempotent (`testScript` returns a bool).
- **Upstream settings.** A setting taken from another project, such as WindowsDeveloperConfig, says so in its comment. If winfiles does it differently on purpose, add an entry under `## Drift from upstream` in the area's doc (the upstream file at a pinned commit, what each side does, the evidence, when to revisit), and point to it from the comment.

## Custom resource conventions

More in `docs/config/resources.md`, and how to write one in `docs/dev/writing-resources.md`.

- Each script is an advanced script: `-Operation` first, and DSC's JSON through a `ValueFromPipeline` parameter, collected in `process` and used in `end`. It dot-sources `common.ps1` in `begin`.
- A failure throws `New-ResourceError` with the manifest's exit code. Each script declares its own `trap` calling `Exit-ResourceError`, which reports the error as a JSON line. The reasons are in `docs/config/resources.md#conventions`.

## Script conventions

Copy them from existing scripts in `scripts/`.

- **Style** follows the PoshCode style guide, with the exceptions in `docs/dev/style.md`. The `lint` command checks what PSScriptAnalyzer can.
- **Help.** A script starts with its `#Requires` lines, a blank line, comment-based help (`.SYNOPSIS`, `.DESCRIPTION` where it helps, and an `.EXAMPLE` with a line saying what it does), then `[CmdletBinding()]` and `param()`. Without the blank line, Get-Help ignores the help; `tests/scripts/Help.Tests.ps1` checks it. No help line may start with a dot, or Get-Help drops the whole block.
- **Parameters** are declared in `param()` with types, a comment above each saying what it is (not `.PARAMETER`), and `[Parameter(Mandatory)]` where needed, because `winfiles.ps1 help` shows a command's script through Get-Help, which builds its syntax from them. `.EXAMPLE` commands run from the repo root.
- **Functions** get the same: `[CmdletBinding()]`, `[OutputType()]` when they return something, help with a `.SYNOPSIS`, and a typed `param()`. Two blank lines around each. No `return`: let the output fall out of `if`/`else`.
- **Errors.** A script sets `$ErrorActionPreference = 'Stop'` itself, then runs in `try`, with a `catch` that copies `$_` and rethrows it, and a `finally` that sets it back to `Continue`. The `catch` matters: without it, an error that only ends a statement leaves the script exiting 0. Calls use named parameters.
- **`-WhatIf`.** A script or function that changes the system has `SupportsShouldProcess` and asks `$PSCmdlet.ShouldProcess` before each change.
- **Dot-sourced files** have a plain comment at the top instead of help; their functions have help.
- **Exceptions** (`Invoke-Clean.ps1`'s version check, the scripts that run under Windows PowerShell 5.1, the ones with no `param()`) are listed in `docs/dev/style.md`.
- **Progress** is recorded with `Write-WinfilesLog` (file only, `run.log`). The console gets `Write-Host`, and only failures, warnings and results. Don't make the logger print.
- **Privilege.** A step that needs a privilege goes through `scripts/Invoke-AsAdmin.ps1` or `scripts/Invoke-AsUser.ps1`, which use gsudo only when the shell's privilege differs. Don't call gsudo from a command. Tests override them as `docs/run/privilege.md` describes.
- **Tests.** A new script gets tests in `tests/scripts/` unless it's in the "Not tested" list in `docs/dev/testing.md`. Keep the fakes basic.

## Constraints

- **Never modify the persistent `PATH` to achieve a goal.** The pwsh profile, kept outside this repo, owns it. Changing `PATH` for one process inside a command is fine. A tool winfiles drives may change it only if the user has approved that tool. So far that's Scoop (its installer, and manifests with `env_add_path`) and winget (installs and uninstalls). Ask before relying on any other tool doing it.
- **Commit messages** use conventional commits plus gitmoji, scoped by area, for example `feat(dsc): ✨  ...` or `chore: 📝  ...`. Put two spaces after the gitmoji, since terminals draw some emoji wider than their cell and hide a single space.
