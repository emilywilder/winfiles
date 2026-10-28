# Emily's personal configuration management for Windows

I do it for Linux and macOS, so why not?

> [!caution]
> This is very much a WIP and not for general use.

# Installation
1. Install dsc from vanilla Windows 11 install ([mise](https://mise.jdx.dev) provides `just`)
    ```powershell
    winget install jdx.mise
    mise trust; mise install
    mise exec -- just dsc-install
    ```
2. Install WSL and enable Virtual Machine Platform, then restart
    ```powershell
    mise exec -- just wsl-install
    ```
3. Install PowerShell 7 and modules
    ```powershell
    dsc config set --file .\dsc\powershell\pwsh.dsc.yaml
    ```
