# Architecture

How the configuration is structured, and why. Facts about the tools it relies on are in [reference/](reference/), and timings are in [benchmarks.md](benchmarks.md). How a run applies the documents is in [install.md](install.md).

## Structure

The layout is modelled on NixOS and Home Manager (see nix-starter-configs). Each configuration is an entry document directly in `dsc/`, split by the privilege its `set` needs:

| Document | Like | Privilege | Applied by |
|---|---|---|---|
| `dsc/<host>.system.dsc.yaml` | `nixosConfigurations.<host>` | elevated, declared once in its own `metadata.winget.securityContext: elevated`, which covers everything it includes | `just system` |
| `dsc/<user>@<host>.home.dsc.yaml` | a standalone `homeConfigurations."<user>@<host>"` | unelevated | `just home` |
| `dsc/modules/{system,home}/` | modules | the entry's | through an entry |
| `dsc/hosts/<host>/` | one machine's differences | the entry's | through an entry |
| `dsc/users/<user>@<host>/` | one user's own choices on a host: what lives in their home directory or HKCU, such as their WSL distributions | unelevated | through the home entry |

- **Entries only list Includes.** `dependsOn` orders the Includes inside an entry, but it can't name another entry's resources. `just install` and `just check` run the system and home entries as one aggregate, system first.
- **Entries stay directly in `dsc/`.** A `configurationFile` resolves from the folder of the document passed to `--file`, nested Includes too, and DSC 3.3.0 refuses `..` ([reference](reference/dsc.md#include-paths)).
- **Modules don't include each other.** A module that included a sibling would work from its entry or on its own, never both, and two modules including the same one would apply it twice ([ruled-out.md](reference/ruled-out.md#modules-that-include-each-other)). So each module also runs on its own, and entries state the ordering.
- **Modules hold nothing specific to one person or machine,** so the project can become a starting point for others. A document that needs elevation for any of its resources goes in `modules/system`.
- **The hosts** are `iris`; `vm`, for test VMs, which has every shared module and none of a real machine's hardware; and `vm-quick`, a quicker test host ([testing.md](testing.md)). To add a host, create `dsc/hosts/<host>/`, copy a pair of entries, and edit their module lists.
- `dsc/templates/` is reference material, deliberately left out of every configuration.

`just system`, `home`, `check` and `install` don't give DSC the entries. They flatten them, split the result into batches by privilege, and run each batch at its level ([install.md](install.md#the-flat-copy), [flat-configuration.md](flat-configuration.md)).

Trade-off: each entry repeats its module list, where Nix would import a common file. A shared layer that only includes modules would work ([optional-goals.md](optional-goals.md)). Revisit once there's a third real host, or the lists drift.

### Organized like Nix, run like DSC

Nix is the model for how the files are laid out, not for how they're evaluated: there are no options, no list merging and no generations. Everything winfiles adds has to pass three tests:

1. Every checked-in document runs under plain `just dsc config test|set --file <document>`, and gives the output DSC gives.
2. winfiles' scripts only turn documents into documents (the flat copy, the batches, the aggregate), and DSC does all the work on resources.
3. Take the scripts away, and the documents still apply, one at a time, in an order you choose.

So the checked-in documents contain only what DSC understands, plus metadata it ignores (`metadata.winget.securityContext`, Microsoft's own name, as `winget configure` reads it). Privilege and restarts, which DSC has no notion of, live in the scripts. Where Nix does something DSC can't (modules that include each other, `lib.mkIf`), it's left out, not imitated with a dialect ([ruled-out.md](reference/ruled-out.md#a-dialect-of-the-documents)).

## Optional features

`dsc/hosts/<host>/features.dsc.yaml` holds the Windows optional features a host relies on, in one `Microsoft.Windows/OptionalFeatureList`: Virtual Machine Platform, plus Hyper-V on iris, which hosts the test VMs. Add new features there. DISM doesn't enable a feature's children along with it, so each one is listed, parents first.

The system entry includes it, so `just system` applies it and `just check` tests it. The resource needs elevation even for `get` ([reference](reference/dsc.md#optionalfeaturelist-and-elevation)), so the document can only run on its own from an elevated shell: `just dsc config test --file dsc/hosts/iris/features.dsc.yaml`. It can't report a restart from `test`, so it reaches the restart batch through WSL's `dependsOn` ([install.md](install.md#what-needs-a-restart)).

## Packages

Each feature (base, dev, gaming, internet, productivity, media) has a document of the same name in `dsc/modules/system` and `dsc/modules/home`.
- `modules/system/runtimes.dsc.yaml` holds the shared runtimes.
- `dsc/hosts/<host>/hardware.dsc.yaml` and `home.dsc.yaml` hold what only one machine wants.
- MSIX frameworks (VCLibs, UI.Xaml, .NET Native, Windows App Runtime) are left out: the image and the Store supply most of them, and winget installs one that an app declares along with it ([reference](reference/winget.md#dependencies-of-an-app)). Revisit if a new app's dependency fails to install: list the dependency first.

Packages managed elsewhere are left out of these lists:

| Package | Managed by |
|---|---|
| PowerShell | `modules/system/powershell.dsc.yaml` |
| DSC | `mise.toml` |
| WSL | `Winfiles/Wsl`, in `modules/system/wsl-platform.dsc.yaml` |
| IntelliJ IDEA | JetBrains Toolbox |
| Python, Meld | Scoop, in `modules/home/dev.dsc.yaml` |
| Discord | Scoop, in `modules/home/internet.dsc.yaml`: winget's installer asks for UAC mid-run ([reference](reference/apps.md)) |
| What can't be installed unattended | `dsc/hosts/<host>/manual.yaml` (below) |

### winget

Each winget package is a resource of its own, with comments between them grouping the packages by purpose. The properties are `name` (the id), `source: winget` and `acceptAgreements: true`.
- In `modules/system` and the hosts' system documents, it's a `Microsoft.WinGet/Package`. These set no scope, so winget picks one.
- In `modules/home` and the hosts' home documents, it's a `Winfiles.WinGet/Package` with `_scope: User`, which makes winget pick a per-user installer, and fail if there's none ([reference](reference/winget.md#install-scope)).

To add a package, copy a neighbour under the right comment.
- It goes in `modules/home` if it has a per-user installer (`winget show --id <id> --exact --scope user` names one) that really runs unelevated.
- Otherwise it goes in `modules/system`.
- The manifest doesn't prove the installer runs unelevated: KDE Connect's per-user installer still asks for UAC, so it's in `modules/system`. Only a run in the test VM shows this ([reference](reference/apps.md)).

Removing a package's resource doesn't uninstall it: set `_exist: false` and apply that first. A failed package stops its batch ([install.md](install.md#failures)). `modules/system/settings.dsc.yaml` marks the `msstore` source explicit (`Microsoft.WinGet/Source`), so winget only uses it when a command passes `--source msstore`.

Trade-off: each package is a `winget dscv3` process that looks up its own package, which roughly doubled `just check` on iris against the old lists, to about 150s ([benchmarks](benchmarks.md#per-package-resources)). In return there's no custom list code, each package has its own options, uninstalls work through `_exist`, and drift names the package. Revisit if `check` gets slow enough to discourage running it, or if winget gains a batch `test`.

### Scoop

Scoop is in the home configuration, because its installer refuses an elevated shell.

- `Winfiles/Scoop`, the first resource in `modules/home/scoop-core.dsc.yaml`, installs Scoop by downloading and running Scoop's own installer, and does nothing else. In an elevated shell, its `set` exits 3 instead of trying.
- `Winfiles/ScoopPackageList` is a list: at most one per document, checked with one read of the Scoop root. Entries are `name` or `bucket/name`.
  - State comes from `apps/<name>/current/scoop-install.json` (`install.json` from older Scoop) and `buckets/<name>` under the root, not from running Scoop.
  - `set` adds missing buckets, then makes one `scoop install` call for the missing apps.
  - An app or bucket that fails stays in `missing` or `missingBuckets`, and the list still exits 0.
  - If Scoop is still missing when a list's `set` runs, the list exits 3.
- `scoop-core.dsc.yaml` holds two lists:
  - `Core` installs git, with no buckets, because adding any bucket other than `main` needs git.
  - `Buckets` declares every bucket (name → repository URL), with no apps, and depends on `Core`.

  Other modules list only apps, and depend on it in the entry.
- Scoop finds git through its shims. The `dsc` of a fresh `just install` started before Scoop's installer added them to the user `PATH`, so the list puts `<root>\shims` on `PATH` for its own process.
- Scoop's own `Installing '<app>' ...` lines are raised to `WARN`, the lowest level DSC shows by default, because otherwise a slow download looks like a hang.
- Both resources find the Scoop root with `Get-ScoopRoot` (`dsc/resources/scooproot.ps1`): `$env:SCOOP`, then `root_path` in Scoop's config, then `~\scoop`.

`just scoop-notes` (`scripts/Show-ScoopNotes.ps1`) prints the `notes` from every installed app's manifest again, with `$dir`, `$original_dir` and `$persist_dir` filled in as `scoop info --verbose` does. A DSC run hides them. It covers every installed app, not just the lists, and changes nothing. Notes are free text, and mostly optional (context menus, file associations), so they're for review; one worth having becomes a resource. It stays out of `just install` and apart from `just post-install`, whose notes are a host's curated must-dos. Trade-off: nothing says when a new note appears, so it only helps when run. Revisit if a note that mattered gets missed.

### Installed by hand

`dsc/hosts/<host>/manual.yaml` lists what a host needs that can't be installed unattended, each with why. `just manual [host]` (`scripts/Get-ManualInstaller.ps1`):
- finds what's missing from the display names in the Uninstall registry keys;
- downloads it to `~/.cache/winfiles/manual` with `winget download`, which checks the manifest's hash;
- never runs an installer.

It's outside DSC, so `just check` still means what winfiles can apply by itself. An entry can move to an ordinary list if its installer turns out to work unattended. The list is read with `yq`, since PowerShell has no YAML parser. The list goes with the host, so a new host has to copy entries such as LyX and Battle.net that would otherwise belong to shared modules.

The TeX engine is Tectonic, from Scoop, in `modules/home/productivity.dsc.yaml`, and LyX works with it ([reference](reference/apps.md#lyx-and-tectonic)). Trade-off: a small engine winfiles can install unattended, rather than a full distribution it can't. Revisit if something needs a full LaTeX distribution.

## WSL

WSL is optional, and so is everything a user puts in it. winfiles does only the Windows side: everything inside a distribution (`wsl.*` options, `/etc/wsl.conf`, users) belongs to the distribution's own configuration.

| Document | Entry | What |
|---|---|---|
| `modules/system/wsl-platform.dsc.yaml` | system | `Winfiles/Wsl`: the WSL package and Virtual Machine Platform; depends on the host's features |
| `modules/system/wsl.dsc.yaml` | system | WSL's Hyper-V firewall (setting it needs elevation) |
| `modules/home/wsl.dsc.yaml` | home | marks WSL's first run done (`OOBEComplete`, from WindowsDeveloperConfig), so the "Welcome to WSL" window doesn't open |
| `dsc/users/<user>@<host>/wsl.dsc.yaml` | home | the user's distributions, and `~/.wslconfig` and `~/.wslgconfig` if they want them |

A test (`WSL in the entry documents`, in `tests/scripts/ConvertTo-FlatConfiguration.Tests.ps1`) fails when a home entry installs a distribution and its host's system entry has no `Winfiles/Wsl`. WSL facts are in [reference/wsl.md](reference/wsl.md).

### The WSL package

`Winfiles/Wsl`'s `test` is in the desired state when:
- WSL is installed at `minimumVersion` (2.4.4 by default, the first with `--from-file` and `--name`);
- Virtual Machine Platform is enabled;
- no restart is pending;
- a hypervisor runs.

`set` runs `wsl --update` for an old WSL, and `wsl --install --no-distribution` for a missing WSL or a disabled feature. It needs elevation only when there's something to do.

- **Restarts.** It never restarts Windows. It reports `_restartRequired` and exits 0, since DSC stops the whole configuration on a non-zero exit. `get` reports it while a restart is pending, and `test` also while Virtual Machine Platform is off, since enabling it leaves one pending. So a run knows ahead of time, and applies WSL first ([install.md](install.md#what-needs-a-restart)). A WSL that only needs installing or updating isn't predicted to need a restart; the machine shows it afterwards. `wsl.exe`'s 1641 (success, restart already started) is accepted like 3010.
- **The hypervisor check** catches virtualization that's off in the firmware, or not passed through to a VM. It's only judged once no restart is pending, since the hypervisor starts at boot.
- **Running `wsl.exe`.** The resource runs it through `cmd /c "wsl.exe ... <con > file 2>&1"`, because the inbox `wsl.exe` refuses a piped stdin ([reference](reference/wsl.md#the-inbox-wslexe)). Its arguments, output and exit code go to `run.log` under `[wsl]`, since DSC shows a resource's stderr only at `trace`. Trade-off: the output reaches the console only when the install fails, not as progress. Revisit if watching it matters.
- **Elevation** is read through `whoami.exe /groups`, so a test can mock it.
- **Keep the checks in step.** `Winfiles/WslDistribution` makes the same checks before installing a distribution.
- **It needs pwsh,** like the other resources, so it doesn't run by hand on a bare machine. That's fine while the bootstrap installs mise's pwsh first. Revisit if the bootstrap ever has to run before mise.

### Distributions

Each distribution is a `Winfiles/WslDistribution` resource of its own in the user's document, and none is fine. So far emily has NixOS-WSL and both config files on iris, NixOS-WSL alone on `vm`, and Alpine on `vm-quick`.

- A distribution's `source` is a URL, a local `.wsl`/`.tar` file, or a name from `wsl --list --online`. Without one, the resource's `name` is installed from the online list.
- The resource reads state from the `HKCU\...\Lxss` registration. It never unregisters or moves a distribution, and `location` only applies at install time.
- Before installing, it checks through CIM that the feature is enabled, that a hypervisor runs, that WSL is 2.4.4 or later, and that no restart is pending. If not, it exits 3.
- `~/.wslconfig` and `~/.wslgconfig` are written from inline content by `Winfiles/FileContentList`, one resource per file, since there's no built-in file resource.

Trade-off: each user's distributions are written out in their own document, rather than in one parameterised module, because resource and parameter names have to be unique across the flattened documents. So NixOS-WSL is written twice, for iris and vm. A `copy` loop would do it in one module, but DSC deprecates `copy` ([ruled-out.md](reference/ruled-out.md#a-copy-loop-for-wsl-distributions)). Revisit if several users come to share distributions ([optional-goals.md](optional-goals.md)).

### Firewall

`modules/system/wsl.dsc.yaml` limits inbound access to WSL to SSH from the local network.
- It sets WSL's default inbound action to Block, on WSL's Hyper-V firewall creator and each of its profiles, creating the creator's setting if WSL hasn't ([reference](reference/wsl.md#hyper-v-firewall)).
- It declares one Hyper-V rule: TCP `sshPort` (2122 by default, the port emily's NixOS configuration gives sshd), Private profile, `LocalSubnet`. A host whose user runs sshd on another port sets `sshPort` on the Include.
- The rule covers every distribution, since they share WSL's one VM. Another service in a distribution that should be reachable needs its own rule.
- It uses the NetSecurity cmdlets, since `Microsoft.Windows/FirewallRuleList` only manages host rules. Reading them needs no elevation, so `test` stays unelevated.

## Custom resources

The `Winfiles/*` resources live in `dsc/resources/` as `*.dsc.resource.json` manifests plus scripts, and `just dsc` makes them discoverable.

- **Common code.** Each script dot-sources `common.ps1`, which sets the preferences and provides `Read-ResourceInput` and `Write-ResourceMessage`.
- **No `[CmdletBinding()]` or `[Parameter()]`,** so `$input` can hold the JSON from stdin.
- **Errors.** DSC logs plain stderr lines only at `trace`, so a failure has to go through `Write-ResourceMessage error`. Each script declares its own `trap` for uncaught errors, because a trap only covers the scope that declares it, even when dot-sourced.
- **Lists.** A list resource keeps an item that fails in its `missing` property and still exits 0, because DSC stops the whole configuration when a resource exits non-zero.
- **Tools' output.** Output from Scoop and `wsl.exe` stays plain, so see it with `-l trace`. Trade-off: a failure names the package but not the tool's own explanation, which keeps a normal run readable. Revisit if failures keep needing `trace`.

| Resource | What |
|---|---|
| `Winfiles.WinGet/Package` | `Microsoft.WinGet/Package` plus a stop-gap `_scope` (below) |
| `Winfiles/Scoop`, `Winfiles/ScoopPackageList` | Scoop and its buckets and apps ([Scoop](#scoop)) |
| `Winfiles/Wsl`, `Winfiles/WslDistribution` | WSL and distributions ([WSL](#wsl)) |
| `Winfiles/FileContentList` | whole text files from inline content, keeping a `.bak` of a file it replaces. `specialFolder` reaches folders that can be redirected, such as `MyDocuments` (OneDrive on iris), which `%USERPROFILE%` can't |
| `Winfiles/ComputerName` | the computer's name (below) |

### Winfiles.WinGet/Package

It exists for the home packages, until App Installer's resource has a canonical `_scope` ([upstream-drift.md](upstream-drift.md)). It takes `Microsoft.WinGet/Package`'s properties, plus `_scope` (`User` or `Machine`), and passes everything but `_scope` to `winget dscv3 package`, as App Installer's manifest does, so winget decides the state and the messages.

- `_scope` only changes `set`. A package that isn't installed is first installed with `winget install --exact --scope`, since `winget dscv3` takes no scope. Then `winget dscv3 package --set` finds it installed.
- `get` and `test` ignore the scope a package is in, as winget does.
- A failed install exits 2, which stops the configuration like a failed `Microsoft.WinGet/Package`. The failure is written to `run.log` under `[winget]`.

Trade-off: a pwsh start on top of each winget call, about 0.55s per package ([benchmarks](benchmarks.md#per-package-resources)), so about 22s more on a `check` for the 40 home ids, for installs that don't raise UAC in `just home`. Revisit when the official `_scope` ships.

### Winfiles/ComputerName

`dsc/hosts/<host>/computername.dsc.yaml`, included by each system entry, names the computer after its host. The test VMs are renamed `vm` and `vm-quick` too, since their names never picked a host.

- Windows applies a rename at the next restart, so the resource compares the pending name (`ComputerName`) with the active one (`ActiveComputerName`). `test` is in the desired state only once the active one matches.
- `set` renames only when the pending name differs, so rerunning it while a rename waits changes nothing, and just warns that a restart is needed.
- Every operation reports `_restartRequired` while the active name isn't the wanted one. So a `test` run shows ahead of time that `set` will need a restart. DSC only reports it; the run restarts ([install.md](install.md#what-needs-a-restart)).
- It uses `Rename-Computer`, not `Microsoft.Windows/Registry` ([reference](reference/windows.md#renaming-the-computer)).

Trade-off: `just check` fails until the restart, and `just` still picks the old name from `COMPUTERNAME` until then, so `install.cmd <host>` keeps passing the host. Revisit if a check shouldn't fail while a rename waits.

## PowerShell

`dsc/modules/system/powershell.dsc.yaml` installs PowerShell and keeps remoting off. `dsc/modules/home/powershell.dsc.yaml` does the rest. PowerShell facts are in [reference/powershell.md](reference/powershell.md).

- **PowerShell 7 is the MSIX,** which winget installs by default, with `useLatest`, so every `set` brings it to the latest stable release, and the Store may update it in between. 7.7.0 and later ship no MSI, so the MSI would have meant staying on 7.6 LTS. The MSIX is per user, and has no machine-wide features (event-log provider, `AllUsers` scopes, remoting endpoint). winfiles' own runs use mise's pwsh, and the profiles and module junctions are per-user, so none of that touches winfiles. Trade-off: the latest release and automatic updates, for those machine-wide features. Revisit if something needs pwsh 7 machine-wide (another account, a SYSTEM task, script block logging). An MSI left installed keeps `test` true on 7.6; uninstall it by hand.
- **Remoting off.** WinRM is kept stopped and Manual, which keeps remoting off for Windows PowerShell 5.1 and any pwsh 7. It's judged by the service alone, since listeners and session configurations need elevation to read. Trade-off: something that starts WinRM on demand makes `test` false, and `set` stops it. Revisit if something here needs WinRM.
- **Microsoft Update.** `modules/system/settings.dsc.yaml` registers Microsoft Update with Automatic Updates ("Receive updates for other Microsoft products"), which the PowerShell MSI's `ENABLE_MU` used to do. It's machine-wide, for other Microsoft software too.
- **Module folders.** PowerShell's CurrentUser scope always writes to `Documents\PowerShell\{Modules,Scripts}`. The home document replaces both folders with junctions to `~/.local/share/powershell/{Modules,Scripts}`, migrating existing contents and keeping clashes in `.bak` folders. It also points `PSModulePath` (in `powershell.config.json`) at `~/.local/share/powershell/Modules`. Trade-off: with the junctions, that setting is redundant in effect; it's kept because `Documents` is redirected to OneDrive, and it keeps module loading off the junction inside it. The cost: if the junction goes missing, CurrentUser installs land outside `PSModulePath`. Revisit if `Documents` stops being redirected.
- **PSGallery** is trusted with `Microsoft.PowerShell.PSResourceGet/Repository`, from the PSResourceGet 1.3.1 that mise's pwsh 7.7.0 bundles. `scripts/Invoke-Dsc.ps1` puts that module's folder on `DSC_RESOURCE_PATH`, since the discovery extension is deleted ([tooling.md](tooling.md)). The instance has no `uri`, although the schema requires one ([reference](reference/powershell.md#psresourceget-131)).
- **Modules** are saved with `Save-PSResource` into that path, through a `PowerShellScript`, not with `PSResourceList`, whose `test` is wrong in 1.3.1 ([reference](reference/powershell.md#psresourceget-131)). Trade-off: a script for 5 modules, rather than workarounds for upstream bugs. Revisit when a PSResourceGet with PowerShell/PSResourceGet#2048 ships in the pwsh that `mise.lock` pins. On switching, each module is reinstalled once.
- **Profiles.** `$PROFILE` can't be relocated, so the default profile files become stubs (starting `# Managed by winfiles (...)`) that repoint `$PROFILE` and dot-source `~/.config/powershell/`. `Winfiles/FileContentList` writes them, ignoring line endings and trailing whitespace when comparing, so any other edit to a stub makes `test` report false until the next `set`. `Microsoft.PowerShell/Profile` isn't used: its `get` is broken.
- **`Microsoft.DSC.Transitional/PowerShellScript`** is still used where nothing official does the job: the module path, the junctions, the modules, Microsoft Update and WSL's Hyper-V firewall ([reference](reference/powershell.md#where-transitionalpowershellscript-is-still-needed)). The remaining way off `Transitional` is `Winfiles/*` resources, which would get Pester tests; not decided yet.

## Left over from earlier versions

What a machine set up before a change still has, which winfiles doesn't remove:

- **`Microsoft.WinGet.Client` in `%ProgramFiles%\PowerShell\Modules`,** from before 2026-11-17. It's now saved with the home configuration's other modules. Remove it by hand from an elevated shell, or leave it: winfiles doesn't load it.
