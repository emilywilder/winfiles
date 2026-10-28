#!/usr/bin/env just --justfile

set windows-shell := ["pwsh.exe", "-NoLogo", "-Command"]

[private]
default:
    @just --list

#
# •───────•°•❀  install  ❀•°•───────•
#

# Dependencies run in order, and each one skips what's already done, so this can be rerun at any point.
# wsl-install goes first: it's the elevated step with nothing before it, so its UAC prompt comes right away.
# When Windows needs a restart for Virtual Machine Platform it exits with 3010 and stops here, so a clean
# install runs this twice, before and after the restart. dsc-install and scoop-install don't need elevation
# (Scoop's installer refuses it), but the composition needs both, so they run before it. Its `set` runs
# elevated (HKLM Brave policies, machine-wide winget installs) through gsudo in this console: that's the
# last UAC prompt, and nothing after it needs attention
# set up a clean Windows 11 install as dsc/winfiles.dsc.yaml describes (unelevated shell; rerun after the restart it asks for)
[windows]
[group("install")]
install: wsl-install dsc-install scoop-install
    gsudo --direct mise exec -- just dsc config set --file dsc/winfiles.dsc.yaml

#
# •───────•°•❀  wsl  ❀•°•───────•
#

# Runs as a script so it works before pwsh is installed. Run it before `dsc config set`: enabling the feature needs a restart
# install WSL and enable Virtual Machine Platform under Windows PowerShell 5.1 (elevates; exits 3010 until you restart)
[windows]
[group("wsl")]
[extension(".ps1")]
[script("powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File")]
wsl-install:
    & '{{justfile_directory()}}\scripts\Install-Wsl.ps1'

#
# •───────•°•❀  scoop  ❀•°•───────•
#

# Runs as a script so it works before pwsh is installed. Run it from an unelevated shell: Scoop's installer refuses to run elevated
# install Scoop under Windows PowerShell 5.1 (buckets and apps come from dsc/packages/scoop.dsc.yaml)
[windows]
[group("scoop")]
[extension(".ps1")]
[script("powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File")]
scoop-install *args:
    & '{{justfile_directory()}}\scripts\Install-Scoop.ps1' {{args}}

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
