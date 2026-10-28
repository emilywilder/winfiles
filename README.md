# Emily's personal configuration management for Windows

I do it for Linux and macOS, so why not?

> [!caution]
> This is very much a WIP and not for general use.

# Installation
From a vanilla Windows 11 install, in a normal (unelevated) terminal ([mise](https://mise.jdx.dev) provides `just`, PowerShell 7 and gsudo for this repo):
```powershell
winget install jdx.mise
# open a new terminal so mise is on PATH, then from the repo:
mise trust; mise install
mise exec -- just install
```
`just install` asks for UAC right away to install WSL. If Windows then needs a restart, it stops: restart and run `mise exec -- just install` again. It then installs DSC and Scoop and asks for UAC once more to apply `dsc/winfiles.dsc.yaml`. Nothing after that prompt needs you.
