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
# and after the restart (which system starts itself when this run made it pending). The steps all run under one
# elevation, so each run asks for UAC once, at the start (install-elevated), after require has checked the
# configurations exist. The home step drops back to unelevated for itself, since Scoop's installer refuses elevation,
# and needs no attention. From an already elevated shell there is no prompt. DSC itself comes from mise.toml
# A package that fails doesn't stop the rest, so check comes after them: its exit code is what reports the failure.
# post-install only runs once check has passed
# Its own first and last lines mark a run in ~/.local/state/winfiles/run.log: the last one only prints when every
# step before it has passed, so a run that stops (for a restart, or a failed check) never says it finished
# set up a clean Windows 11 install as a host's configurations describe (from either kind of shell; rerun after the restart it asks for)
[windows]
install h=host u=user: (require ("dsc/" + h + ".system.dsc.yaml")) (require ("dsc/" + u + "@" + h + ".home.dsc.yaml")) (install-started h) (install-elevated h u)
    @. ./scripts/winlog.ps1; Write-WinfilesLog install 'finished for host {{h}}: system, home and check all passed'

# What install does, in order, once it is elevated: each step still goes through the helper that gives it the privilege
# it needs, so system runs as it is and home drops to unelevated. Run by install-elevated, not by hand
[private]
[windows]
[no-exit-message]
install-steps h u: (system h) (home u h) (check h u) (post-install h)

# The one UAC prompt of an install, which keeps the elevated output and exit code in this console. Exit 3010 from a
# step (a restart is pending) comes back out of here unchanged, as it did from system, so install.cmd can resume
# No exit message: the step that failed has already said so
[private]
[windows]
[no-exit-message]
install-elevated h u:
    @. ./scripts/privilege.ps1; if (-not (Test-Elevated)) { Write-Host 'Asking for UAC once, for the whole install: the Windows features in dsc/hosts/{{h}}/features.dsc.yaml, WSL, the computer name, the system configuration, and then the home one, which runs unelevated' }
    & ./scripts/Invoke-Clean.ps1 pwsh -NoLogo -NoProfile -File ./scripts/Invoke-AsAdmin.ps1 just flat={{flat}} install-steps {{h}} {{u}}; exit $LASTEXITCODE

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
# Invoke-AsAdmin.ps1 does the one gsudo call (`gsudo --direct mise exec -- pwsh ...`) from an unelevated shell, and
# runs the script as it is from an elevated one
# The first line says what the UAC prompt is for before it appears, when there is one
# apply a host's system configuration (elevates unless already elevated; exits 3010 while a restart is pending)
[windows]
[no-exit-message]
system h=host: (require ("dsc/" + h + ".restart.dsc.yaml")) (require ("dsc/" + h + ".system.dsc.yaml"))
    @. ./scripts/privilege.ps1; if (-not (Test-Elevated)) { Write-Host 'Asking for UAC once, for the elevated steps: the Windows features in dsc/hosts/{{h}}/features.dsc.yaml, WSL, the computer name, and dsc/{{h}}.system.dsc.yaml' }
    & ./scripts/Invoke-Clean.ps1 pwsh -NoLogo -NoProfile -File ./scripts/Invoke-AsAdmin.ps1 pwsh -NoLogo -NoProfile -File ./scripts/Set-System.ps1 {{h}} {{no_flatten}}; exit $LASTEXITCODE
# Runs unelevated: Scoop's installer refuses an elevated shell. Invoke-AsUser.ps1 runs it as it is from an unelevated
# shell, and through `gsudo -i Medium` from an elevated one, so this works from either
# No exit message: Set-Winfiles.ps1 has already said what failed, naming the document
# apply a user's home configuration on a host (runs unelevated, from either kind of shell)
[windows]
[no-exit-message]
home u=user h=host: (require ("dsc/" + u + "@" + h + ".home.dsc.yaml"))
    & ./scripts/Invoke-Clean.ps1 pwsh -NoLogo -NoProfile -File ./scripts/Invoke-AsUser.ps1 pwsh -NoLogo -NoProfile -File ./scripts/Set-Winfiles.ps1 dsc/{{u}}@{{h}}.home.dsc.yaml {{no_flatten}}; exit $LASTEXITCODE

# Features need elevation even for get, so this leaves them out. See dsc/hosts/<host>/features.dsc.yaml
# It runs unelevated from either kind of shell (Invoke-AsUser.ps1), so an install, which is elevated by now, tests
# the same way a plain `just check` does
# No exit message: the script has already said what's wrong
# test a host's system and home configurations (lists what's missing; exits 1 if anything is)
[windows]
[no-exit-message]
check h=host u=user: (require ("dsc/" + h + ".system.dsc.yaml")) (require ("dsc/" + u + "@" + h + ".home.dsc.yaml"))
    & ./scripts/Invoke-Clean.ps1 pwsh -NoLogo -NoProfile -File ./scripts/Invoke-AsUser.ps1 pwsh -NoLogo -NoProfile -File ./scripts/Test-Winfiles.ps1 dsc/{{h}}.system.dsc.yaml dsc/{{u}}@{{h}}.home.dsc.yaml {{no_flatten}}; exit $LASTEXITCODE

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

# Through a scheduled task in the VM, so a UAC prompt still shows on the VM's desktop and the resume after a restart still
# needs a sign-in and Enter there (exits 3010 when the command restarts the VM). Windows PowerShell 5.1 runs the command
# run a command in a running test VM without elevation, as bootstrap.cmd and install.cmd need (elevates here; e.g. just test-vm-unelevated winfiles-test '.\install.cmd vm-quick')
[windows]
[group("test")]
[no-exit-message]
test-vm-unelevated name command:
    {{elevated_pwsh}} -File ./scripts/Enter-TestVm.ps1 -Name '{{name}}' -Unelevated -Command '{{replace(command, "'", "''")}}'; exit $LASTEXITCODE

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

# Writes where system, home and check do, so `just dsc config test --file <the printed path>` runs what they run.
# No exit message: the script has already said what it refused
# write a document's flat copy, with its Includes replaced by their resources, and print its path (e.g. just flatten dsc/iris.system.dsc.yaml)
[windows]
[group("dsc")]
[no-exit-message]
flatten *args:
    & ./scripts/Invoke-Clean.ps1 pwsh -NoLogo -NoProfile -File ./scripts/ConvertTo-FlatConfiguration.ps1 {{args}}; exit $LASTEXITCODE

# export every exportable DSC resource to YAML (default: ./exports)
[windows]
[group("dsc")]
dsc-export *args:
    & ./scripts/Export-DscResource.ps1 {{args}}
