# PowerShell

How PowerShell, its packages and its DSC resources behaved when checked, and what in winfiles relies on it. The design is in `docs/architecture.md`, "PowerShell".

## MSI and MSIX

- PowerShell 7.7.0 and later ship no MSI (Microsoft's install page and the v7.7.0 release assets, checked 2026-11-14). The MSI would mean staying on the 7.6 LTS line, which Microsoft Update patches but never moves past, until 7.6's support ends on 2028-11-14.
- The MSIX is per user, so other accounts and SYSTEM tasks don't get it. It has:
  - no `PowerShellCore` event-log provider (registering one would point at a version-numbered folder, and registration locks the DLL there);
  - no all-users profiles, `Set-ExecutionPolicy -Scope LocalMachine` or other `AllUsers` scopes;
  - no remoting endpoint;
  - a folder that changes with each version, so nothing should name a path to `pwsh.exe`.
- winget counts an MSI install as the same package and finds no MSI to upgrade it to, so an MSI left installed keeps `test` true on 7.6.

## CurrentUser installs

PowerShell's CurrentUser install scope always writes to `Documents\PowerShell\{Modules,Scripts}`, whatever `PSModulePath` says. On iris, `Documents` is redirected to OneDrive (checked 2026-10-28). pwsh 7.7.0 has no user content path setting that could move it, although PSResourceGet 1.3.1 has code for one.

## PSResourceGet 1.3.1

- 1.3.1 is the first stable release with DSC manifests: 1.3.0 went from rc2 straight to 1.3.1 (PSGallery, 2026-11-10). pwsh 7.7.0 bundles it.
- `Microsoft.PowerShell.PSResourceGet/Repository` for PSGallery works only without `uri`, although the schema requires one. `set` passes it to `Set-PSResourceRepository`, which refuses `-Uri` for PSGallery ("The PSGallery repository has a predefined Uri"), so `set` on an untrusted PSGallery failed with it. DSC 3.3.0 doesn't enforce the requirement. Its `test` is DSC's synthetic one, and `metadata.description` doesn't upset it. Checked 2026-11-16 on iris, with PSGallery untrusted for the run and `%LOCALAPPDATA%\PSResourceGet\PSResourceRepository.xml` restored afterwards. Not yet through a clean install in the test VM.
- `Microsoft.PowerShell.PSResourceGet/PSResourceList`'s `test` is wrong in two ways (checked 2026-11-16 on iris with `dsc resource test`):
  - an entry without `version` never counts as installed ("'' is not a valid version string");
  - only a list's first entry is checked (a `break` in `IsInDesiredState`), so an installed module followed by a missing one reports `inDesiredState: true`.
- Read from the code, not run: with more than one entry, `set` compares each desired module against every installed one, so it can install what's already there, and it uses the last entry's scope for all of them.
- Upstream PR PowerShell/PSResourceGet#2048 fixes the first two. It was open, with changes requested, on 2026-11-16.
- A workaround would be one list per module, each with a range such as `version: '[[0.0,)'`.
- Modules saved by `Save-PSResource` have no `PSGetModuleInfo.xml`, so `PSResourceList` would see them as missing and reinstall each once.

## Microsoft.PowerShell/Profile

Its `get` is broken (`JSON: EOF while parsing a value`) on a non-empty profile. It ships with PowerShell, not DSC, and fails under both DSC 3.2.3 and 3.3.0.

## Where Transitional/PowerShellScript is still needed

Checked 2026-11-16 against every resource DSC 3.3.0 finds here (DSC's own, App Installer's, pwsh 7.7.0's and `Winfiles/*`). Nothing:
- writes a setting into a JSON file (`PowerShell Module Path`);
- makes junctions (`Junction Default Install Folders`);
- registers a Windows Update service (`Microsoft Update`; `Microsoft.Windows/UpdateList` installs updates);
- manages WSL's Hyper-V firewall (`docs/reference/wsl.md`).

## WinRM

WSMan listeners and session configurations need elevation to read. `Microsoft.Windows/FirewallRuleList` finds rules by display name, which the two WinRM rules share.
