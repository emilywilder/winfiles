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
# •───────•°•❀  wsl  ❀•°•───────•
#

# Runs as a script so it works before pwsh is installed. Run it before `dsc config set`: enabling the feature needs a restart
# install WSL and enable Virtual Machine Platform under Windows PowerShell 5.1 (elevates; restart afterwards)
[windows]
[group("wsl")]
[extension(".ps1")]
[script("powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File")]
wsl-install:
    & '{{justfile_directory()}}\scripts\Install-Wsl.ps1'

#
# •───────•°•❀  dsc  ❀•°•───────•
#

# Runs as a script so a clean install needs only just, not pwsh
# install DSC v3 under Windows PowerShell 5.1 (pass -FromGitHub to skip winget)
[windows]
[group("dsc")]
[extension(".ps1")]
[script("powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File")]
dsc-install *args:
    & '{{justfile_directory()}}\scripts\Install-Dsc.ps1' {{args}}

# run dsc with discovery limited to DSC, App Installer, dsc/resources and pwsh (e.g. just dsc config test --file dsc/winfiles.dsc.yaml)
[windows]
[group("dsc")]
dsc *args:
    & ./scripts/Invoke-Dsc.ps1 {{args}}

# just dsc using the GitHub release of DSC from mise.dsc.toml (the Store package's dism_dsc refuses to run)
[windows]
[group("dsc")]
dsc-github *args:
    mise -E dsc exec -- pwsh -NoLogo -NoProfile -File ./scripts/Invoke-Dsc.ps1 {{args}}

# export every exportable DSC resource to YAML (default: ./exports)
[windows]
[group("dsc")]
dsc-export *args:
    & ./scripts/Export-DscResource.ps1 {{args}}

# dsc-export using the GitHub release of DSC from mise.dsc.toml (exports the dism_dsc resources too)
[windows]
[group("dsc")]
dsc-export-github *args:
    mise -E dsc exec -- pwsh -NoLogo -NoProfile -File ./scripts/Export-DscResource.ps1 {{args}}
