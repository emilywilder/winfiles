#!/usr/bin/env just --justfile

set windows-shell := ["pwsh.exe", "-NoLogo", "-Command"]

# Windows OS configuration
[group("modules")]
mod system
# Package management : scoop
[group("modules")]
mod scoop
# Package management : winget
[group("modules")]
mod winget
# PowerShell configuration
[group("modules")]
mod powershell

[private]
default:
    @just --list

# Install
[windows]
install: powershell::install scoop::import winget::install

#
# •───────•°•❀  dsc  ❀•°•───────•
#

# install DSC v3 under Windows PowerShell 5.1 (pass -FromGitHub to skip winget)
[windows]
[group("dsc")]
dsc-install *args:
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File install-dsc.ps1 {{args}}

# export every exportable DSC resource to YAML (default: ./exports)
[windows]
[group("dsc")]
dsc-export *args:
    & ./Export-DscResources.ps1 {{args}}
