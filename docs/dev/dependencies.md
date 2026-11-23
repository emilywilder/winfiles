# What `winfiles.ps1 install` depends on

What has to be in place when `winfiles.ps1 install <host>` starts. What it installs itself on the way is in [installed-by-install.md](installed-by-install.md), and what the bootstrap leaves behind is in [run/bootstrap.md](../run/bootstrap.md#what-it-leaves-behind). Traced from the commands, `scripts/` and `dsc/` on 2026-11-15, and updated for `winfiles.ps1` on 2026-11-22. Update it when a command, script or document starts relying on something new.

The split matters for the bootstrap (`bootstrap.cmd`): everything here is the bootstrap's job (or the machine's), and nothing in [installed-by-install.md](installed-by-install.md) is. The bootstrap reads nothing from `dsc/` and doesn't run `winfiles.ps1 install`; `install.cmd` does.

## Tools

| Tool | What needs it | Provided by |
|---|---|---|
| mise, `min_version` in `mise.toml` or later | `scripts/Invoke-Clean.ps1` runs each step under `mise exec`, and `system` runs `mise exec` again under gsudo. It has to be on the user `PATH`, where winget puts it, and have trusted the repo | winget, `jdx.mise` (the bootstrap) |
| Visual C++ 2015+ x64 runtime | `mise.exe` imports `VCRUNTIME140.dll`. Without it mise exits with `0xC0000135` (DLL not found), checked in the test VM on 2026-11-15. None of the tools below need it | winget, as a dependency of `jdx.mise` |
| pwsh 7.4 or later | Runs `winfiles.ps1` (the command runner, `commands.jsonc`) and every script it starts. `Set-Winfiles.ps1`, `Test-Winfiles.ps1`, `Invoke-Dsc.ps1` and `Show-PostInstall.ps1` require 7.4. DSC only discovers `Microsoft.DSC.Transitional/PowerShellScript` and the `Winfiles/*` resources when `tryWhich('pwsh')` finds it | `mise.toml` |
| gsudo | The one UAC prompt of `system`, which keeps the elevated output in the same console, and, from an elevated shell, `gsudo -i Medium` for the steps that need an unelevated process (`scripts/Invoke-AsAdmin.ps1`, `scripts/Invoke-AsUser.ps1`) | `mise.toml` |
| DSC 3.3.0 | Applies and tests every configuration | `mise.toml`. Its postinstall hook runs Windows PowerShell 5.1 |

`yq`, also from `mise.toml`, reads and writes the documents for `scripts/ConvertTo-FlatConfiguration.ps1`, which `Invoke-Configuration.ps1` runs before every `winfiles.ps1 system`, `home`, `check` and `install`, and reads `manual.yaml` for `winfiles.ps1 manual`.

## Built into Windows

- **winget (App Installer).** The `winget` command, and the `Microsoft.WinGet/Package` and `Microsoft.WinGet/Source` DSC resources, which `Invoke-Dsc.ps1` finds in App Installer's install folder (`Get-AppxPackage Microsoft.DesktopAppInstaller`). It has to be new enough: 1.26 fails elevated, and 1.29 works ([reference](../reference/winget.md#app-installer-126-elevated)). The bootstrap updates it.
- **The inbox `wsl.exe`.** `dsc/resources/wsl.ps1` (`Winfiles.Wsl/Wsl`) runs `wsl --install --no-distribution` with it. Neither WSL resource runs it to ask for a version ([reference](../reference/wsl.md#the-inbox-wslexe)).
- **`whoami.exe`.** `Winfiles.Wsl/Wsl` asks `whoami.exe /groups` whether the shell is elevated (the High mandatory level, S-1-16-12288), rather than the .NET principal, so a test can mock it. It only asks when there is something to install.
- **Windows PowerShell 5.1.** For DSC's postinstall hook, and for `install.cmd`, which runs `scripts/Invoke-Install.ps1` under it (and `scripts/Resume-Winfiles.ps1` after a restart). That runs `scripts/Start-Winfiles.ps1`, also under 5.1, to find mise on the registry's `PATH` and start `scripts/Invoke-Clean.ps1`, and `winfiles.ps1 install` through it, under mise's pwsh. The bootstrap runs under it too (`scripts/Initialize-Winfiles.ps1`). The commands themselves don't. For what 5.1 does differently, see [reference/windows.md](../reference/windows.md#windows-powershell-51-passing-arguments).
- **PowerShell modules that ship with Windows or pwsh:**
  - CIM (`Win32_OptionalFeature`), for Virtual Machine Platform.
  - Appx (`Get-AppxPackage`), to find App Installer, and `Add-AppxPackage`, for the bootstrap to register an App Installer update winget left staged.
  - NetSecurity's Hyper-V firewall cmdlets (`*-NetFirewallHyperVProfile`, `*-NetFirewallHyperVVMSetting`, `*-NetFirewallHyperVRule`), in `modules/system/wsl.dsc.yaml`. They're only in recent Windows 11 releases.
  - `Invoke-WebRequest`, `Restart-Computer` and `Test-NetConnection` (the resume, to wait for winget's source).
  - `Save-PSResource` (PSResourceGet), which ships with pwsh 7.
  - PSResourceGet 1.3.1 or later in mise's pwsh (bundled from pwsh 7.7.0), for the `Microsoft.PowerShell.PSResourceGet/Repository` resource that trusts PSGallery. An older one has no DSC manifests, and the home configuration fails with "Resource not found".
- **The registry.** `Component Based Servicing\RebootPending` for a pending restart, WSL's per-user `Lxss` registration under HKCU, and `install.cmd`'s per-user `RunOnce` value (`HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce\winfiles`), which stays only while a restart is pending.

## The machine and the account

- **Windows 11.** Pro on iris, since it enables Hyper-V.
- **Virtualization on in the firmware,** for Virtual Machine Platform and WSL 2. In a test VM, nested virtualization (`winfiles.ps1 test-vm` sets it).
- **An administrator account.** `winfiles.ps1 install` asks for UAC once, at its start (none from an elevated terminal), and runs `home` unelevated, since Scoop's installer refuses an elevated shell. The bootstrap still needs an unelevated terminal.
- **Network access** to:
  - GitHub: mise, the tools in `mise.toml`, Scoop and its buckets, WSL images.
  - The winget source and its download servers.
  - PSGallery, for the PowerShell modules the home configuration saves.
  - `get.scoop.sh`.
- **The repo.** A fresh machine has no git, so it arrives some other way: a downloaded archive, or `winfiles.ps1 test-vm-copy` for the test VM.

Nothing in the repo does the firmware setting or getting the repo onto the machine; they're done by hand.

## For working on winfiles

Not needed by `winfiles.ps1 install`. Both are PowerShell modules, which mise can't install, so the script that uses each pins its version and saves it to `~/.cache/winfiles/modules` from PSGallery on first use, whatever else is on `PSModulePath`.

| Module | What needs it | Pinned in |
|---|---|---|
| Pester 6.2.0 | `winfiles.ps1 test` | `scripts/Invoke-Test.ps1` |
| PSScriptAnalyzer 1.25.0 | `winfiles.ps1 lint`, and `tests/scripts/Invoke-Lint.Tests.ps1` | `scripts/Invoke-Lint.ps1` |
