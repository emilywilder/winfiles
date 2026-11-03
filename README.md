# Emily's personal configuration management for Windows

I do it for Linux and macOS, so why not?

> [!caution]
> This is very much a WIP and not for general use.

# Installation
From a vanilla Windows 11 install, in a normal (unelevated) terminal, from the repo:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-Winfiles.ps1 -HostName iris
```
It updates App Installer, installs [mise](https://mise.jdx.dev) with winget, then the tools mise provides for this repo (`just`, PowerShell 7, gsudo and DSC), then runs `just install iris`. Without `-HostName` it uses the computer name. Installing mise may ask for UAC for the Visual C++ runtime. `just install` asks for UAC once, right away, then installs WSL and applies the host's system configuration, `dsc/iris.system.dsc.yaml`. If Windows has a restart pending, it stops first: restart and run the script again (or `mise exec -- just install iris`). Nothing after the UAC prompt needs you: it goes on to apply your home configuration, `dsc/emily@iris.home.dsc.yaml`, which installs Scoop and its apps and WSL's NixOS distribution.
