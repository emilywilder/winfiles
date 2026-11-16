# Emily's personal configuration management for Windows

I do it for Linux and macOS, so why not?

> [!caution]
> This is very much a WIP and not for general use.

# Installation
From a vanilla Windows 11 install, in a normal (unelevated) terminal, from the repo:
```powershell
.\bootstrap.cmd
```
The bootstrap runs `scripts\Initialize-Winfiles.ps1` under Windows PowerShell with the execution policy bypassed for that process, since a fresh install blocks `.ps1` scripts. It checks the machine first and changes nothing if something's wrong. Then it updates App Installer, installs [mise](https://mise.jdx.dev) with winget (which may ask for UAC for the Visual C++ runtime), and the tools mise provides for this repo (`just`, PowerShell 7, gsudo, yq and DSC). It doesn't apply any configuration. When it's done, open a new terminal in the repo and install a host:
```powershell
mise exec -- just install iris
```

> [!important]
> Always pass the host on a new install. Windows Setup gives the machine a generated name such as `DESKTOP-AB12CD3`, which matches no configuration. Without a host, `just install` stops with an error before changing anything. `mise exec -- just hosts` lists the hosts.

What has to be in place beforehand, what the bootstrap leaves behind, and what the install sets up itself, is in [docs/dependencies.md](docs/dependencies.md). Two things are done by hand: virtualization has to be on in the firmware, and the repo has to get onto the machine without git.

`just install` asks for UAC once, right away, then installs WSL and applies the host's system configuration, `dsc/iris.system.dsc.yaml`. If Windows has a restart pending, it stops first: restart and run the same command again. Nothing after the UAC prompt needs you: it goes on to apply your home configuration, `dsc/emily@iris.home.dsc.yaml`, which installs Scoop and its apps and WSL's NixOS distribution.
