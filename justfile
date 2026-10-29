#!/usr/bin/env just --justfile

set windows-shell := ["pwsh.exe", "-NoLogo", "-Command"]

[private]
default:
    @just --list

# Dependencies run in order, and each one skips what's already done, so this can be rerun at any point.
# The elevated steps come first, then the unelevated ones, following the split of dsc/winfiles.dsc.yaml.
# When Windows needs a restart for Virtual Machine Platform, wsl-install exits with 3010 and stops here, so
# a clean install runs this twice, before and after the restart. Each run asks for UAC once, at the start:
# the unelevated half, which also installs Scoop (its installer refuses elevation), needs no attention.
# DSC itself comes from mise.toml
# set up a clean Windows 11 install as dsc/winfiles.dsc.yaml describes (unelevated shell; rerun after the restart it asks for)
[windows]
install: elevated
    mise exec -- just dsc config set --file dsc/winfiles.user.dsc.yaml

# Both elevated steps in one gsudo call, so a run asks for UAC at most once, and their output and exit
# codes stay in this console. Already elevated, wsl-install runs wsl.exe here instead of in its own UAC window
[private]
[windows]
elevated:
    gsudo --direct mise exec -- just wsl-install dsc-set-machine

# The elevated half of dsc/winfiles.dsc.yaml (HKLM Brave policies, machine-wide winget installs)
[private]
[windows]
dsc-set-machine: (dsc "config" "set" "--file" "dsc/winfiles.machine.dsc.yaml")

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
# •───────•°•❀  test  ❀•°•───────•
#

# Windows Sandbox can't run WSL2, so a clean install is tested in a Hyper-V VM with nested virtualization
# create a Hyper-V test VM from a Windows 11 ISO (elevates; skips if the VM exists)
[windows]
[group("test")]
test-vm iso *args:
    gsudo --direct mise exec -- pwsh -NoLogo -NoProfile -File ./scripts/New-TestVm.ps1 -IsoPath '{{iso}}' {{args}}

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
