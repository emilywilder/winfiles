#!/usr/bin/env just --justfile

set windows-shell := ["pwsh.exe", "-NoLogo", "-Command"]

[private]
default:
    @just --list

# Dependencies run in order, and each one skips what's already done, so this can be rerun at any point.
# The elevated steps come first, then the unelevated ones, following the split of dsc/winfiles.dsc.yaml.
# While Windows has a restart pending (after enabling Virtual Machine Platform, say), wsl-install exits with 3010 and stops here, so
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

# Run it before `dsc config set`: enabling the feature needs a restart. pwsh -Command reports a script's
# exit code as 1, so pass it on explicitly to keep the 3010
# install WSL and enable Virtual Machine Platform (elevates; exits 3010 while a restart is pending)
[windows]
[group("wsl")]
wsl-install:
    & ./scripts/Install-Wsl.ps1; exit $LASTEXITCODE

#
# •───────•°•❀  test  ❀•°•───────•
#

# Windows Sandbox can't run WSL2, so a clean install is tested in a Hyper-V VM with nested virtualization
# create a Hyper-V test VM from a Windows 11 ISO (elevates; skips if the VM exists)
[windows]
[group("test")]
test-vm iso *args:
    gsudo --direct mise exec -- pwsh -NoLogo -NoProfile -File ./scripts/New-TestVm.ps1 -IsoPath '{{iso}}' {{args}}

# Copied over PowerShell Direct, so the VM needs no share or git. Replaces ~\src\winfiles in the VM
# copy this repo's working tree into a running test VM (elevates; -Ref <commit> packs a commit instead)
[windows]
[group("test")]
test-vm-copy name='winfiles-test' *args:
    gsudo --direct mise exec -- pwsh -NoLogo -NoProfile -File ./scripts/Copy-RepoToTestVm.ps1 -Name '{{name}}' {{args}}

#
# •───────•°•❀  dsc  ❀•°•───────•
#

# run dsc (from mise.toml) with discovery limited to DSC, App Installer and dsc/resources (e.g. just dsc config test --file dsc/winfiles.dsc.yaml)
[windows]
[group("dsc")]
dsc *args:
    & ./scripts/Invoke-Dsc.ps1 {{args}}

# A visual check of how dsc shows messages from resources, for comparing DSC versions (see tests/dsc-messages/README.md).
# Discovery is limited to dsc's own folder and tests/dsc-messages, so Test/SlowList never reaches the real configuration
# run `dsc config set` on a dummy document in tests/dsc-messages (e.g. just dsc-messages machine-info -l info)
[windows]
[group("test")]
dsc-messages doc *args:
    @$env:DSC_RESOURCE_PATH = (Split-Path (Get-Command dsc -CommandType Application | Select-Object -First 1).Source) + ';{{justfile_directory()}}\tests\dsc-messages'; dsc {{args}} config set --file '{{justfile_directory()}}\tests\dsc-messages\{{doc}}.dsc.yaml'; exit $LASTEXITCODE

# export every exportable DSC resource to YAML (default: ./exports)
[windows]
[group("dsc")]
dsc-export *args:
    & ./scripts/Export-DscResource.ps1 {{args}}
