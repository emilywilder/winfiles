#!/usr/bin/env just --justfile

# No profile: it costs about 5s per recipe line, and no recipe needs it
set windows-shell := ["pwsh.exe", "-NoLogo", "-NoProfile", "-Command"]

# Runs a script elevated in this console, under mise's pwsh
elevated_pwsh := "gsudo --direct mise exec -- pwsh -NoLogo -NoProfile"

[private]
default:
    @just --list

# A configuration is picked by host and user, like nixosConfigurations.<host> and homeConfigurations."<user>@<host>"
host := lowercase(env('COMPUTERNAME'))
user := env('USERNAME')

# system, home and check give dsc a flat copy of each document, with its Includes replaced by their resources
# (scripts/ConvertTo-FlatConfiguration.ps1, docs/install.md). `just flat=false <recipe> ...` runs the documents
# themselves instead, Includes and all; install passes it to each step
flat := "true"
no_flatten := if flat == "true" { "" } else if flat == "false" { "-NoFlatten" } else { error("flat must be true or false, not '" + flat + "'") }

# Dependencies run in order, and each one skips what's already done, so this can be rerun at any point.
# Each goes through scripts/Invoke-Clean.ps1, so nothing from the calling shell reaches the run.
# The system configuration comes first, then the home one. While Windows has a restart pending (after enabling
# optional features, say), system exits with 3010 and stops here, so a clean install runs this twice, before
# and after the restart (which system starts itself when this run made it pending). Each run asks for UAC
# once, at the start: the home configuration, which also installs Scoop (its installer refuses elevation), needs
# no attention. DSC itself comes from mise.toml
# A package that fails doesn't stop the rest, so check comes after them: its exit code is what reports the failure.
# post-install only runs once check has passed
# Its own first and last lines mark a run in ~/.local/state/winfiles/run.log: the last one only prints when every
# step before it has passed, so a run that stops (for a restart, or a failed check) never says it finished
# set up a clean Windows 11 install as a host's configurations describe (unelevated shell; rerun after the restart it asks for)
[windows]
install h=host u=user: (require ("dsc/" + h + ".system.dsc.yaml")) (require ("dsc/" + u + "@" + h + ".home.dsc.yaml")) (install-started h) (system h) (home u h) (check h u) (post-install h)
    @. ./scripts/winlog.ps1; Write-WinfilesLog install 'finished for host {{h}}: system, home and check all passed'

[private]
[windows]
install-started h:
    @. ./scripts/winlog.ps1; Write-WinfilesLog install 'started for host {{h}}: system, then home, then check'

# One gsudo call, so a run asks for UAC at most once, and its output and exit code stay in this console.
# scripts/Set-System.ps1 tests dsc/<host>.restart.dsc.yaml (the optional features, WSL and the computer's name) to see
# what needs a restart, applies what differs, and restarts once, before anything installs, if Windows then has one
# pending: installers refuse to run while it is. It exits 3010 then, and install.cmd continues after the restart.
# Then it applies dsc/<host>.system.dsc.yaml (docs/install.md).
# No exit message: when it stops for a restart, just's "recipe failed" lines would read as an error. A failure is
# reported by Set-Winfiles.ps1, which names the document.
# '--' is quoted because PowerShell drops a bare one on its way to a script
# The first line says what the UAC prompt is for before it appears
# apply a host's system configuration (elevates; exits 3010 while a restart is pending)
[windows]
[no-exit-message]
system h=host: (require ("dsc/" + h + ".restart.dsc.yaml")) (require ("dsc/" + h + ".system.dsc.yaml"))
    @Write-Host 'Asking for UAC once, for the elevated steps: the Windows features in dsc/hosts/{{h}}/features.dsc.yaml, WSL, the computer name, and dsc/{{h}}.system.dsc.yaml'
    & ./scripts/Invoke-Clean.ps1 gsudo --direct mise exec '--' pwsh -NoLogo -NoProfile -File ./scripts/Set-System.ps1 {{h}} {{no_flatten}}; exit $LASTEXITCODE
# Runs unelevated: Scoop's installer refuses an elevated shell
# No exit message: Set-Winfiles.ps1 has already said what failed, naming the document
# apply a user's home configuration on a host (unelevated shell)
[windows]
[no-exit-message]
home u=user h=host: (require ("dsc/" + u + "@" + h + ".home.dsc.yaml"))
    & ./scripts/Invoke-Clean.ps1 pwsh -NoLogo -NoProfile -File ./scripts/Set-Winfiles.ps1 dsc/{{u}}@{{h}}.home.dsc.yaml {{no_flatten}}; exit $LASTEXITCODE

# Features need elevation even for get, so this leaves them out. See dsc/hosts/<host>/features.dsc.yaml
# No exit message: the script has already said what's wrong
# test a host's system and home configurations (lists what's missing; exits 1 if anything is)
[windows]
[no-exit-message]
check h=host u=user: (require ("dsc/" + h + ".system.dsc.yaml")) (require ("dsc/" + u + "@" + h + ".home.dsc.yaml"))
    & ./scripts/Invoke-Clean.ps1 pwsh -NoLogo -NoProfile -File ./scripts/Test-Winfiles.ps1 dsc/{{h}}.system.dsc.yaml dsc/{{u}}@{{h}}.home.dsc.yaml {{no_flatten}}; exit $LASTEXITCODE

# Outside DSC, so check keeps meaning "what winfiles can apply by itself". See dsc/hosts/<host>/manual.yaml
# No exit message: the script has already said what failed
# download the installers of what a host installs by hand and is missing (never runs them)
[windows]
[no-exit-message]
manual h=host: (require ("dsc/" + h + ".system.dsc.yaml"))
    & ./scripts/Invoke-Clean.ps1 pwsh -NoLogo -NoProfile -File ./scripts/Get-ManualInstaller.ps1 dsc/hosts/{{h}}/manual.yaml; exit $LASTEXITCODE

# Prints the `# post-install:` comments in dsc/hosts/<host>/
# show what a host still needs done by hand after an install
[windows]
[no-exit-message]
post-install h=host: (require ("dsc/" + h + ".system.dsc.yaml"))
    @& ./scripts/Invoke-Clean.ps1 pwsh -NoLogo -NoProfile -File ./scripts/Show-PostInstall.ps1 dsc/hosts/{{h}}; exit $LASTEXITCODE

# Reads installed manifests without running Scoop. Not part of install: most notes are optional, and printing
# them on every run would bury the post-install ones
# show the notes Scoop's installed apps suggest acting on (registry imports, profile hooks), for review
[windows]
[no-exit-message]
scoop-notes:
    @& ./scripts/Invoke-Clean.ps1 pwsh -NoLogo -NoProfile -File ./scripts/Show-ScoopNotes.ps1; exit $LASTEXITCODE

# list the system and home configurations in this repo
[windows]
hosts:
    @Get-ChildItem dsc -File -Filter *.dsc.yaml | Where-Object Name -notlike '*.restart.dsc.yaml' | ForEach-Object { $_.Name -replace '\.dsc\.yaml$' }

# Rerun from another checkout to point it there. Doesn't touch PATH: the pwsh profile owns it
# No exit message: the script has already said what's wrong
# write winfiles-rebuild, which runs this checkout's recipes from any directory (default: ~/bin)
[windows]
[no-exit-message]
install-rebuild dir=(home_directory() / "bin"):
    @& ./scripts/Install-Rebuild.ps1 '{{dir}}'

# A recipe with *args passes them on to a script, so Get-Help shows that script's parameters too
# No exit message: for an unknown recipe, just --usage has already said so
# show a recipe's arguments and their defaults, and the help of the scripts its *args go to (e.g. just help test-vm)
[windows]
[no-exit-message]
help recipe:
    @just --usage '{{recipe}}'
    @& ./scripts/Show-RecipeHelp.ps1 '{{recipe}}'; exit $LASTEXITCODE

# Fails before UAC or any change when a host or user has no configuration
[private]
[windows]
[no-exit-message]
require file:
    @if (-not (Test-Path -LiteralPath '{{file}}')) { [Console]::Error.WriteLine("No configuration at {{file}}. These exist:"); just hosts; exit 1 }

#
# •───────•°•❀  test  ❀•°•───────•
#

# Resources run against fakes in tests/fakes, so this changes nothing on the machine and needs no VM.
# No exit message: Pester has already listed what failed
# run the Pester tests (unelevated; e.g. just test tests/resources/wingetpackage.Tests.ps1)
[windows]
[group("test")]
[no-exit-message]
test *paths:
    & ./scripts/Invoke-Clean.ps1 pwsh -NoLogo -NoProfile -File ./scripts/Invoke-Tests.ps1 {{paths}}; exit $LASTEXITCODE

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

# No exit message: the script has already said what's wrong
# follow a running test VM's run.log, across restarts; -All adds winget's and the installers' logs (elevates; -Tail <lines>)
[windows]
[group("test")]
[no-exit-message]
test-vm-log name='winfiles-test' *args:
    {{elevated_pwsh}} -File ./scripts/Watch-TestVmLog.ps1 -Name '{{name}}' {{args}}; exit $LASTEXITCODE

#
# •───────•°•❀  dsc  ❀•°•───────•
#

# run dsc (from mise.toml) with discovery limited to DSC, App Installer and dsc/resources (e.g. just dsc config test --file dsc/iris.system.dsc.yaml)
[windows]
[group("dsc")]
dsc *args:
    & ./scripts/Invoke-Dsc.ps1 {{args}}

# export every exportable DSC resource to YAML (default: ./exports)
[windows]
[group("dsc")]
dsc-export *args:
    & ./scripts/Export-DscResource.ps1 {{args}}
