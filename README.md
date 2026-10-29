# Emily's personal configuration management for Windows

I do it for Linux and macOS, so why not?

> [!caution]
> This is very much a WIP and not for general use.

# Installation
From a vanilla Windows 11 install, in a normal (unelevated) terminal ([mise](https://mise.jdx.dev) provides `just`, PowerShell 7, gsudo and DSC for this repo):
```powershell
winget install --id jdx.mise --exact --source winget --accept-package-agreements
# open a new terminal so mise is on PATH, then from the repo:
mise trust; mise install
mise exec -- just install
```
`just install` asks for UAC once, right away, then installs WSL and applies the elevated half of `dsc/winfiles.dsc.yaml`. If Windows needs a restart for WSL, it stops first: restart and run `mise exec -- just install` again. Nothing after the UAC prompt needs you: it goes on to apply the unelevated half, which installs Scoop and its apps and WSL's NixOS distribution.
