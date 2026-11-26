# PowerShell

How PowerShell, its packages and its DSC resources behaved when checked, and what in winfiles relies on it. The design is in `docs/config/powershell.md`.

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
- Read from `psresourceget.ps1`, not run:
  - `set` compares each desired module with every one `get` returns, and a different name counts as not in the desired state. So with several modules installed, it queues every entry for `Install-PSResource -Reinstall`, installed or not.
  - `set` uses the last entry's scope for all of them.
  - `test` doesn't return after finding the repository missing: it carries on, and could write a second result.
- Upstream PR PowerShell/PSResourceGet#2048 was open, with changes requested, on 2026-11-25 (last activity seen: 2026-11-12), and 1.3.1 was still the latest release. Its description says it fixes both `test` bugs, and `set`'s comparison and scope; its diff wasn't read, and it doesn't mention the missing repository.
- Its schema has a `scope` (`CurrentUser` or `AllUsers`) but no install path.
- A workaround would be one list per module, each with a range such as `version: '[[0.0,)'`.
- `Save-PSResource` writes `PSGetModuleInfo.xml` only with `-IncludeXml`. Without it, `Get-PSResource` doesn't list the module, by `-Path` or by `-Scope CurrentUser`; with it, `-Path` lists it with `Repository` `PSGallery`. `PSResourceList`'s `get` looks modules up with `Get-PSResource -Scope` and keeps those from its repository, so it would see one saved without the XML as missing. Checked 2026-11-25 on iris, pwsh 7.7.0: PSFzf 2.7.12 saved each way into an empty folder, and iris's four modules in `CurrentUser`, where only the one with the XML was listed. The other three were then saved again at the same versions with `-IncludeXml`: no file changed or went missing, the XML was added, and `-Scope CurrentUser` listed all four with `Repository` `PSGallery`. `PSResourceList` itself wasn't run, with or without the XML.

## Microsoft.PowerShell/Profile

Its `get` is broken (`JSON: EOF while parsing a value`) on a non-empty profile. It ships with PowerShell, not DSC, and fails under both DSC 3.2.3 and 3.3.0.

## Where Transitional/PowerShellScript is still needed

Checked 2026-11-16 against every resource DSC 3.3.0 finds here (DSC's own, App Installer's, pwsh 7.7.0's and `Winfiles/*`). Nothing:
- writes a setting into a JSON file (`PowerShell Module Path`);
- makes junctions (`Junction Default Install Folders`);
- registers a Windows Update service (`Microsoft Update`; `Microsoft.Windows/UpdateList` installs updates);
- manages WSL's Hyper-V firewall (`docs/reference/wsl.md`).

Each host's module list uses it too. `PSResourceList` does that job, but not yet correctly ([above](#psresourceget-131)).

## WinRM

WSMan listeners and session configurations need elevation to read. `Microsoft.Windows/FirewallRuleList` finds rules by display name, which the two WinRM rules share.
