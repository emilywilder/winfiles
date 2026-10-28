#!/usr/bin/env just --justfile

set windows-shell := ["pwsh.exe", "-NoLogo", "-Command"]

[private]
default:
    @just --list

# Dependencies run in order, and each one skips what's already done, so this can be rerun at any point.
# The elevated steps come first, then the unelevated ones, following the split of dsc/winfiles.dsc.yaml.
# When Windows needs a restart for Virtual Machine Platform, wsl-install exits with 3010 and stops here, so
# a clean install runs this twice, before and after the restart. dsc-set-machine is the last UAC prompt:
# scoop-install (Scoop's installer refuses elevation) and the unelevated half need no attention.
# DSC itself comes from mise.toml
# set up a clean Windows 11 install as dsc/winfiles.dsc.yaml describes (unelevated shell; rerun after the restart it asks for)
[windows]
install: wsl-install dsc-set-machine scoop-install
    mise exec -- just dsc config set --file dsc/winfiles.user.dsc.yaml

# The elevated half of dsc/winfiles.dsc.yaml (HKLM Brave policies, machine-wide winget installs), through
# gsudo so its output and exit code stay in this console
[private]
[windows]
dsc-set-machine:
    gsudo --direct mise exec -- just dsc config set --file dsc/winfiles.machine.dsc.yaml

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

# run dsc (from mise.toml) with discovery limited to DSC, App Installer and dsc/resources (e.g. just dsc config test --file dsc/winfiles.dsc.yaml)
[windows]
[group("dsc")]
dsc *args:
    & ./scripts/Invoke-Dsc.ps1 {{args}}

# export every exportable DSC resource to YAML (default: ./exports)
[windows]
[group("dsc")]
dsc-export *args:
    & ./scripts/Export-DscResource.ps1 {{args}}
