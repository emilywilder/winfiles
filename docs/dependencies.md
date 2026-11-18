# What `just install` depends on

What has to be in place when `just install <host>` starts, and what it installs itself on the way. Traced from the justfile, `scripts/` and `dsc/` on 2026-11-15. Update it when a recipe, script or document starts relying on something new.

The split matters for the bootstrap (`bootstrap.cmd`): everything in the first section is the bootstrap's job (or the machine's), and nothing in the second is. The bootstrap reads nothing from `dsc/` and doesn't run `just install`; `install.cmd` does.

## Before `just install` starts

### Tools

| Tool | What needs it | Provided by |
|---|---|---|
| mise, `min_version` in `mise.toml` or later | `scripts/Invoke-Clean.ps1` runs each step under `mise exec`, and `system` runs `mise exec` again under gsudo. It has to be on the user `PATH`, where winget puts it, and have trusted the repo | winget, `jdx.mise` (the bootstrap) |
| Visual C++ 2015+ x64 runtime | `mise.exe` imports `VCRUNTIME140.dll`. Without it mise exits with `0xC0000135` (DLL not found), checked in the test VM on 2026-11-15. None of the tools below need it | winget, as a dependency of `jdx.mise` |
| just | Runs the recipes | `mise.toml` |
| pwsh 7.4 or later | The shell of every recipe line (`windows-shell`). `Set-Winfiles.ps1`, `Test-Winfiles.ps1`, `Invoke-Dsc.ps1` and `Show-PostInstall.ps1` require 7.4. DSC only discovers `Microsoft.DSC.Transitional/PowerShellScript` and the `Winfiles/*` resources when `tryWhich('pwsh')` finds it | `mise.toml` |
| gsudo | The one UAC prompt of `system`, which keeps the elevated output in the same console | `mise.toml` |
| DSC 3.3.0 | Applies and tests every configuration | `mise.toml`. Its postinstall hook runs Windows PowerShell 5.1 |

`yq` is in `mise.toml` too, but only `just manual` uses it; `just install` doesn't.

### Built into Windows

- **winget (App Installer).** The `winget` command, and the `Microsoft.WinGet/Package` and `Microsoft.WinGet/Source` DSC resources, which `Invoke-Dsc.ps1` finds in App Installer's install folder (`Get-AppxPackage Microsoft.DesktopAppInstaller`). It has to be new enough: with 1.26.509, from an image that hadn't been through Windows Update, the WinGet module fails when elevated and `Microsoft.WinGet/Source` can't add `msstore` back. 1.29 works. The bootstrap updates it.
- **The inbox `wsl.exe`.** `dsc/resources/wsl.ps1` (`Winfiles/Wsl`) runs `wsl --install --no-distribution` with it. The resource never runs it to ask for a version: with no WSL package it waits 60 seconds for a key press that would install WSL (seen on a fresh install, 2026-11-17). The version comes from the file version of `Program Files\WSL\wsl.exe`, or from the package's registration under `AppxAllUserStore`, and without either there is no WSL. `dsc/resources/wsldistribution.ps1` reads it the same way.
- **`whoami.exe`.** `Winfiles/Wsl` asks `whoami.exe /groups` whether the shell is elevated (the High mandatory level, S-1-16-12288), rather than the .NET principal, so a test can mock it. It only asks when there is something to install.
- **Windows PowerShell 5.1.** For DSC's postinstall hook, and for `install.cmd`, which runs `scripts/Invoke-Install.ps1` under it (and `scripts/Resume-Winfiles.ps1` after a restart). That runs `scripts/Start-Clean.ps1`, also under 5.1, to find mise on the registry's `PATH` and start `scripts/Invoke-Clean.ps1`, and `just install` through it, under mise's pwsh. The bootstrap runs under it too (`scripts/Initialize-Winfiles.ps1`). The recipes themselves don't. A script that takes both pass-through arguments (`ValueFromRemainingArguments`) and another parameter needs `[CmdletBinding(PositionalBinding = $false)]`: 5.1 binds positional arguments to the other parameters first, so `Invoke-Install.ps1`'s first argument, the host, went to `-RunOnceKey` (found 2026-11-16, when it created a file named after the host).
- **PowerShell modules that ship with Windows or pwsh:**
  - CIM (`Win32_OptionalFeature`), for Virtual Machine Platform.
  - Appx (`Get-AppxPackage`), to find App Installer, and `Add-AppxPackage`, for the bootstrap to register an App Installer update winget left staged.
  - NetSecurity's Hyper-V firewall cmdlets (`*-NetFirewallHyperVProfile`, `*-NetFirewallHyperVVMSetting`, `*-NetFirewallHyperVRule`), in `modules/system/wsl.dsc.yaml`. They're only in recent Windows 11 releases.
  - `Invoke-WebRequest`, `Restart-Computer` and `Test-NetConnection` (the resume, to wait for winget's source).
  - `Save-PSResource` (PSResourceGet), which ships with pwsh 7.
  - PSResourceGet 1.3.1 or later in mise's pwsh (bundled from pwsh 7.7.0), for the `Microsoft.PowerShell.PSResourceGet/Repository` resource that trusts PSGallery. An older one has no DSC manifests, and the home configuration fails with "Resource not found".
- **The registry.** `Component Based Servicing\RebootPending` for a pending restart, WSL's per-user `Lxss` registration under HKCU, and `install.cmd`'s per-user `RunOnce` value (`HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce\winfiles`), which stays only while a restart is pending.

### The machine and the account

- **Windows 11.** Pro on iris, since it enables Hyper-V.
- **Virtualization on in the firmware,** for Virtual Machine Platform and WSL 2. In a test VM, nested virtualization (`just test-vm` sets it).
- **An administrator account, in an unelevated terminal.** `system` asks for UAC, and Scoop's installer refuses an elevated shell.
- **Network access** to:
  - GitHub: mise, the tools in `mise.toml`, Scoop and its buckets, WSL images.
  - The winget source and its download servers.
  - PSGallery, for the PowerShell modules the home configuration saves.
  - `get.scoop.sh`.
- **The repo.** A fresh machine has no git, so it arrives some other way: a downloaded archive, or `just test-vm-copy` for the test VM.

Nothing in the repo does the firmware setting or getting the repo onto the machine; they're done by hand.

## Installed by `just install` on the way

In the order the recipes run them. Each skips what's already done.

1. **`system`** (elevated, one UAC prompt, `scripts/Set-System.ps1`):
   1. `dsc/<host>.restart.dsc.yaml`, tested first and then applied where it differs:
      - The host's optional features (Virtual Machine Platform, plus Hyper-V on iris). Enabling one leaves a restart pending.
      - WSL (`Winfiles/Wsl`).
      - The computer's name (`Winfiles/ComputerName`).
   2. The gate: while Windows has a restart pending, the run restarts it (when this run made it pending) or stops, with 3010, so a clean install runs `just install` twice. One restart covers all three.
   3. `dsc/<host>.system.dsc.yaml`, the system configuration:
      - The PowerShell 7 MSIX (`Microsoft.WinGet/Package`).
      - The machine-wide winget packages (runtimes, base with gsudo, and the rest).
      - Policies and settings in the registry, and `msstore` made explicit.
      - WSL's Hyper-V firewall settings.
2. **`home`** (unelevated):
   - Scoop (`Winfiles/Scoop`, from its own installer).
   - git through Scoop, which adding buckets needs, then the buckets and apps, including `just` and `yq` in `modules/home/dev.dsc.yaml`.
   - The per-user winget packages, including `jdx.mise` in `modules/home/base.dsc.yaml`.
   - PowerShell's profiles, module junctions and modules.
   - `.wslconfig` and `.wslgconfig`.
   - The WSL distribution (NixOS, or Alpine on vm-quick). It needs Virtual Machine Platform enabled, WSL 2.4.4 or later and no restart pending, and downloads its image.
3. **`check`** and **`post-install`** install nothing.

## Handed over, and installed twice

- `jdx.mise` is handed over: the bootstrap installs it with winget, naming it itself, and `modules/home/base.dsc.yaml` lists the same package, so from the first `just home` the configuration manages the bootstrap's copy. That's how Nix's installer and nix-darwin split it too: the installer installs Nix from its own release, and the configuration then manages that Nix. The list only installs, so it doesn't upgrade mise; `min_version` in `mise.toml` stops a run on an older one with the `winget upgrade jdx.mise` hint.
- `Microsoft.VCRedist.2015+.x64` comes with `jdx.mise`, as its dependency. Nothing in the configuration relies on it: vm-quick's "already installed" package is Edge, which Windows ships.
- `just`, `gsudo`, `yq` and pwsh are installed twice, as different copies: `mise.toml` provides the ones the run uses, and the configurations install their own (Scoop's `just` and `yq`, winget's `gerardog.gsudo`, the PowerShell MSIX). The recipes use `mise.toml`'s, through `Invoke-Clean.ps1`, which also ignores any mise configuration other than the repo's `mise.toml`, with a warning.

## What the bootstrap leaves behind

Nothing removes these. To undo a bootstrap on a machine that `just install` hasn't touched:

- The App Installer update. Leave it: it's Windows' own package, and Windows Update or the Store would update it anyway.
- `winget uninstall --id jdx.mise --exact`, which also takes mise's folder off the user `PATH`. Once `just home` has run, the home configuration installs it again; take it out of `modules/home/base.dsc.yaml` first to keep it gone.
- The Visual C++ runtime, `Microsoft.VCRedist.2015+.x64`. Usually leave it: it's shared, and other programs may need it.
- `%LOCALAPPDATA%\mise`, the tools `mise install` downloaded, and `~\.local\state\mise`, which holds the repo's trust.

The bootstrap changes no `PATH` itself; winget's change for mise is the only one. Like Nix's installer, which prints `uninstall_directions`, this is a list, not a script.
