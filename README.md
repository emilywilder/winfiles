# Emily's personal configuration management for Windows

I do it for Linux and macOS, so why not?

> [!caution]
> This is very much a WIP and not for general use.

# Installation
From a vanilla Windows 11 install, in a normal (unelevated) terminal, from the repo:
```powershell
.\bootstrap.cmd
```
The bootstrap runs `scripts\Initialize-Winfiles.ps1` under Windows PowerShell with the execution policy bypassed for that process, since a fresh install blocks `.ps1` scripts. It checks the machine first and changes nothing if something's wrong. Then it updates App Installer, installs [mise](https://mise.jdx.dev) with winget (which may ask for UAC for the Visual C++ runtime), and the tools mise provides for this repo (PowerShell 7, gsudo, yq and DSC), and lists the configurations in the repo. It doesn't apply any configuration. When it's done, install a host, from the same terminal or any other:
```powershell
.\install.cmd iris
```

> [!important]
> Always pass the host on a new install. Windows Setup gives the machine a generated name such as `DESKTOP-AB12CD3`, which matches no configuration. Without a host, the install stops with an error before changing anything, and lists the hosts.

What has to be in place beforehand is in [docs/dev/dependencies.md](docs/dev/dependencies.md), what the install sets up itself is in [docs/dev/installed-by-install.md](docs/dev/installed-by-install.md), and what the bootstrap leaves behind is in [docs/run/bootstrap.md](docs/run/bootstrap.md#what-it-leaves-behind). Two things are done by hand: virtualization has to be on in the firmware, and the repo has to get onto the machine without git.

`winfiles.ps1 install` asks for UAC once, right away, then installs WSL and applies the host's system configuration, `dsc/iris.system.dsc.yaml`. If Windows has a restart pending, it stops first: restart and run the same command again (`install.cmd` continues at the next sign-in, once you press Enter in the window it opens). Nothing after the UAC prompt needs you: it goes on to apply your home configuration, `dsc/emily@iris.home.dsc.yaml`, which installs Scoop and its apps and your WSL distributions (NixOS, from `dsc/users/emily@iris/wsl.dsc.yaml`).
