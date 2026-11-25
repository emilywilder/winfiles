# PowerShell

`dsc/modules/system/powershell.dsc.yaml` installs PowerShell and keeps remoting off. `dsc/modules/home/powershell.dsc.yaml` sets up the user's module folders, PSGallery and profiles, and each host lists the modules it wants. PowerShell's behaviour is in [reference/powershell.md](../reference/powershell.md).

## System

- **PowerShell 7 is the MSIX,** which winget installs by default, with `useLatest`, so every `set` brings it to the latest stable release, and the Store may update it in between. 7.7.0 and later ship no MSI, so the MSI would have meant staying on 7.6 LTS. The MSIX is per user, and has no machine-wide features (event-log provider, `AllUsers` scopes, remoting endpoint). winfiles' own runs use mise's pwsh, and the profiles and module junctions are per-user, so none of that touches winfiles. Trade-off: the latest release and automatic updates, for those machine-wide features. Revisit if something needs pwsh 7 machine-wide (another account, a SYSTEM task, script block logging). An MSI left installed keeps `test` true on 7.6; uninstall it by hand.
- **Remoting off.** WinRM is kept stopped and Manual, which keeps remoting off for Windows PowerShell 5.1 and any pwsh 7. It's judged by the service alone, since listeners and session configurations need elevation to read. Trade-off: something that starts WinRM on demand makes `test` false, and `set` stops it. Revisit if something here needs WinRM.
- **Microsoft Update.** `modules/system/settings.dsc.yaml` registers Microsoft Update with Automatic Updates ("Receive updates for other Microsoft products"), which the PowerShell MSI's `ENABLE_MU` used to do. It's machine-wide, for other Microsoft software too.

## Home

- **Module folders.** PowerShell's CurrentUser scope always writes to `Documents\PowerShell\{Modules,Scripts}`. The home document replaces both folders with junctions to `~/.local/share/powershell/{Modules,Scripts}`, migrating existing contents and keeping clashes in `.bak` folders. It also points `PSModulePath` (in `powershell.config.json`) at `~/.local/share/powershell/Modules`. Trade-off: with the junctions, that setting is redundant in effect; it's kept because `Documents` is redirected to OneDrive, and it keeps module loading off the junction inside it. The cost: if the junction goes missing, CurrentUser installs land outside `PSModulePath`. Revisit if `Documents` stops being redirected.
- **PSGallery** is trusted with `Microsoft.PowerShell.PSResourceGet/Repository`, from the PSResourceGet 1.3.1 that mise's pwsh 7.7.0 bundles. `scripts/Invoke-Dsc.ps1` puts that module's folder on `DSC_RESOURCE_PATH`, since the discovery extension is deleted ([dev/tooling.md](../dev/tooling.md)). The instance has no `uri`, although the schema requires one ([reference](../reference/powershell.md#psresourceget-131)).
- **Modules** are each host's choice, in `dsc/hosts/<host>/home/powershell-modules.dsc.yaml` (four on iris and on vm-quick), which the home entry includes after the `PowerShell` Include. They're saved with `Save-PSResource` into `Documents\PowerShell\Modules`, the junction to that path, through a `PowerShellScript`, not with `PSResourceList`, whose `test` is wrong in 1.3.1 ([reference](../reference/powershell.md#psresourceget-131)). They go through the junction because the module's `modulePath` parameter can't be declared again in the host's document; the entry's `dependsOn` makes sure the junction is there. Trade-off: a script for a few modules, rather than workarounds for upstream bugs. Revisit when a PSResourceGet with PowerShell/PSResourceGet#2048 ships in the pwsh that `mise.lock` pins. On switching, each module is reinstalled once.
- **Profiles.** `$PROFILE` can't be relocated, so the default profile files become stubs (starting `# Managed by winfiles (...)`) that repoint `$PROFILE` and dot-source `~/.config/powershell/`. `Winfiles/FileContentList` writes them, ignoring line endings and trailing whitespace when comparing, so any other edit to a stub makes `test` report false until the next `set`. `Microsoft.PowerShell/Profile` isn't used: its `get` is broken.

## Transitional/PowerShellScript

`Microsoft.DSC.Transitional/PowerShellScript` is still used where nothing official does the job: the module path, the junctions, the modules, Microsoft Update and WSL's Hyper-V firewall ([reference](../reference/powershell.md#where-transitionalpowershellscript-is-still-needed)). The remaining way off `Transitional` is `Winfiles/*` resources, which would get Pester tests; not decided yet.

## Left over from earlier versions

What a machine set up before a change still has, which winfiles doesn't remove:

- **`Microsoft.WinGet.Client` in `%ProgramFiles%\PowerShell\Modules`,** from before 2026-11-17. It's now saved with the home configuration's other modules. Remove it by hand from an elevated shell, or leave it: winfiles doesn't load it.
