#!/usr/bin/env just --justfile

set windows-shell := ["pwsh.exe", "-NoLogo", "-Command"]

# Runs a script elevated in this console, under mise's pwsh
elevated_pwsh := "gsudo --direct mise exec -- pwsh -NoLogo -NoProfile"

[private]
default:
    @just --list

# A configuration is picked by host and user, like nixosConfigurations.<host> and homeConfigurations."<user>@<host>"
host := lowercase(env('COMPUTERNAME'))
user := env('USERNAME')

# Dependencies run in order, and each one skips what's already done, so this can be rerun at any point.
# The system configuration comes first, then the home one. While Windows has a restart pending (after enabling
# optional features, say), wsl-install exits with 3010 and stops here, so a clean install runs this twice, before
# and after the restart. Each run asks for UAC once, at the start: the home configuration, which also installs
# Scoop (its installer refuses elevation), needs no attention. DSC itself comes from mise.toml
# A package that fails doesn't stop the rest, so check comes last: its exit code is what reports the failure
# set up a clean Windows 11 install as a host's configurations describe (unelevated shell; rerun after the restart it asks for)
[windows]
install h=host u=user: (require ("dsc/" + h + ".system.dsc.yaml")) (require ("dsc/" + u + "@" + h + ".home.dsc.yaml")) (system h) (home u h) (check h u)

# All elevated steps in one gsudo call, so a run asks for UAC at most once, and their output and exit
# codes stay in this console. Already elevated, wsl-install runs wsl.exe here instead of in its own UAC window.
# Features come first: their restart leaves RebootPending set, so wsl-install stops before dsc-set-system.
# No exit message: when wsl-install stops for a restart, just's "recipe failed" lines would read as an error.
# A dsc-set-features or dsc-set-system failure is still reported, by the inner just
# apply a host's system configuration (elevates; exits 3010 while a restart is pending)
[windows]
[no-exit-message]
system h=host: (require ("dsc/" + h + ".system.dsc.yaml"))
    gsudo --direct mise exec -- just dsc-set-features {{h}} wsl-install dsc-set-system {{h}}

# Runs unelevated: Scoop's installer refuses an elevated shell
# apply a user's home configuration on a host (unelevated shell)
[windows]
home u=user h=host: (require ("dsc/" + u + "@" + h + ".home.dsc.yaml"))
    mise exec -- just dsc config set --file dsc/{{u}}@{{h}}.home.dsc.yaml

# Features need elevation even for get, so this leaves them out. See dsc/hosts/<host>/features.dsc.yaml
# No exit message: the script has already said what's wrong
# test a host's system and home configurations (lists what's missing; exits 1 if anything is)
[windows]
[no-exit-message]
check h=host u=user: (require ("dsc/" + h + ".system.dsc.yaml")) (require ("dsc/" + u + "@" + h + ".home.dsc.yaml"))
    mise exec -- pwsh -NoLogo -NoProfile -File ./scripts/Test-Winfiles.ps1 dsc/{{h}}.system.dsc.yaml dsc/{{u}}@{{h}}.home.dsc.yaml; exit $LASTEXITCODE

# list the system and home configurations in this repo
[windows]
hosts:
    @Get-ChildItem dsc -File -Filter *.dsc.yaml | ForEach-Object { $_.Name -replace '\.dsc\.yaml$' }

# Fails before UAC or any change when a host or user has no configuration
[private]
[windows]
[no-exit-message]
require file:
    @if (-not (Test-Path -LiteralPath '{{file}}')) { [Console]::Error.WriteLine("No configuration at {{file}}. These exist:"); just hosts; exit 1 }

# Optional features, outside the system configuration because their resource needs elevation even for get
[private]
[windows]
dsc-set-features h: (dsc "config" "set" "--file" ("dsc/hosts/" + h + "/features.dsc.yaml"))

# A host's system configuration (HKLM policies and settings, machine-wide winget installs, the WSL firewall)
[private]
[windows]
dsc-set-system h: (dsc "config" "set" "--file" ("dsc/" + h + ".system.dsc.yaml"))

#
# •───────•°•❀  wsl  ❀•°•───────•
#

# Run it before `dsc config set`: enabling the feature needs a restart. pwsh -Command reports a script's
# exit code as 1, so pass it on explicitly to keep the 3010. No exit message: the script explains its own
# failures and the restart, and just's "recipe failed" lines would make a restart read as an error
# install WSL and enable Virtual Machine Platform (elevates; exits 3010 while a restart is pending)
[windows]
[group("wsl")]
[no-exit-message]
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
    {{elevated_pwsh}} -File ./scripts/New-TestVm.ps1 -IsoPath '{{iso}}' {{args}}

# Copied over PowerShell Direct, so the VM needs no share or git. Replaces ~\src\winfiles in the VM
# copy this repo's working tree into a running test VM (elevates; -Ref <commit> packs a commit instead)
[windows]
[group("test")]
test-vm-copy name='winfiles-test' *args:
    {{elevated_pwsh}} -File ./scripts/Copy-RepoToTestVm.ps1 -Name '{{name}}' {{args}}

# Elevated in the VM with no UAC, so for checks, not for the bootstrap. -NoExit keeps the session the script enters
# open a PowerShell Direct session in a running test VM (elevates)
[windows]
[group("test")]
test-vm-shell name='winfiles-test':
    {{elevated_pwsh}} -NoExit -File ./scripts/Enter-TestVm.ps1 -Name '{{name}}'

# run a command in a running test VM, in ~\src\winfiles (elevates; e.g. just test-vm-run winfiles-test 'wsl -d NixOS -- uname -a')
[windows]
[group("test")]
test-vm-run name command:
    {{elevated_pwsh}} -File ./scripts/Enter-TestVm.ps1 -Name '{{name}}' -Command '{{replace(command, "'", "''")}}'; exit $LASTEXITCODE

#
# •───────•°•❀  dsc  ❀•°•───────•
#

# run dsc (from mise.toml) with discovery limited to DSC, App Installer and dsc/resources (e.g. just dsc config test --file dsc/iris.system.dsc.yaml)
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
