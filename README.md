# Emily's personal configuration management for Windows

I do it for Linux and macOS, so why not?

> [!caution]
> This is very much a WIP and not for general use.

# Installation
From a vanilla Windows 11 install, in a normal (unelevated) terminal, from the repo:
```powershell
.\bootstrap.cmd iris
```
It runs `scripts\Install-Winfiles.ps1` under Windows PowerShell with the execution policy bypassed for that process, since a fresh install blocks `.ps1` scripts. It updates App Installer, installs [mise](https://mise.jdx.dev) with winget, then the tools mise provides for this repo (`just`, PowerShell 7, gsudo and DSC), then runs `just install iris`. Without a host it uses the computer name, lowercased.

> [!important]
> Always pass the host on a new install. Windows Setup gives the machine a generated name such as `DESKTOP-AB12CD3`, which matches no configuration. Without a host, the script installs its tools and then stops with an error before changing anything; rerun it with the host.

What has to be in place beforehand, and what the install sets up itself, is in [docs/dependencies.md](docs/dependencies.md). Two things are done by hand: virtualization has to be on in the firmware, and the repo has to get onto the machine without git.

 Installing mise may ask for UAC for the Visual C++ runtime. `just install` asks for UAC once, right away, then installs WSL and applies the host's system configuration, `dsc/iris.system.dsc.yaml`. If Windows has a restart pending, it stops first: restart and run the script again (or `mise exec -- just install iris`). Nothing after the UAC prompt needs you: it goes on to apply your home configuration, `dsc/emily@iris.home.dsc.yaml`, which installs Scoop and its apps and WSL's NixOS distribution.
