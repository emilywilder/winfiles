# Emily's personal configuration management for Windows

I do it for Linux and macOS, so why not?

> [!caution]
> This is very much a WIP and not for general use.

# Installation
1. Install dsc from vanilla Windows 11 install
    ```powershell
   powershell -ExecutionPolicy Bypass -File .\install-dsc.ps1
   ```
2. Install PowerShell 7 and modules
    ```powershell
    dsc config set --file .\dsc\powershell\pwsh.dsc.yaml
    ```
3. Install WSL
    ```powershell
    wsl --install
    ```
