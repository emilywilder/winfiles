#Requires -Version 5.1

<#
.SYNOPSIS
    Bootstraps winfiles on a fresh Windows 11 install: winget, mise and the
    repo's tools, so install.cmd (`just install <host>`) can run. It doesn't
    run it.

.DESCRIPTION
    Runs under the built-in Windows PowerShell 5.1, since nothing else is
    installed yet. Run it unelevated: mise's trust and tools are per user, and
    `just install` asks for UAC itself. It reads nothing from dsc/: the machine
    configuration is the install's business.
    1. Checks, before changing anything: an unelevated shell, x64 (mise.lock
       only covers windows-x64), Windows 11, winget found, and mise.toml and
       mise.lock next to scripts/. It lists every problem, then stops.
    2. Updates App Installer, which provides winget and the WinGet DSC module
       that `just install` relies on. A new Windows image can ship one too old:
       with 1.26.509 the WinGet module fails when elevated (0x800706BA), and
       setting the msstore source explicit removes the source and fails.
       `--source winget` keeps winget away from the msstore source, which
       stops to ask for its terms on a fresh install;
       `--accept-package-agreements` accepts the licence.
    3. Starts itself again in a new process (-MiseOnly) for the rest: in the
       test VM, a `winget install` in the same process right after App
       Installer updated itself failed twice out of twice ("Unrecognized
       command", 2026-11-15), and in a new process it worked.
    4. Installs mise with winget (jdx.mise), unless it's already installed.
       winget may ask for UAC to install the Visual C++ runtime mise needs.
       The home configuration lists the same package and manages it from then
       on.
    5. Reloads PATH for this process from the machine and user values: winget
       adds mise's folder to the user PATH and makes no link to it. This only
       changes this process's PATH, never the persistent one.
    6. `mise trust` and `mise install`: just, pwsh, gsudo, yq and DSC.
    7. Runs `mise exec -- just hosts`, which checks that mise's just and pwsh
       run a recipe, and lists the hosts install.cmd can take.
    8. Prints the command to run next.
    Each step skips what's already done, so it's safe to run again.

.PARAMETER MiseOnly
    Only steps 4 to 8: no checks and no App Installer update. The script passes
    this when it starts itself again after the update.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Initialize-Winfiles.ps1
#>
[CmdletBinding()]
param(
    [switch]$MiseOnly
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot

function Update-ProcessPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
        [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Invoke-Native([string]$Command, [string[]]$Arguments) {
    & $Command @Arguments
    if ($LASTEXITCODE) {
        Write-Error "$Command $Arguments exited with code $LASTEXITCODE"
    }
}

if (-not $MiseOnly) {
    $problems = @()
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        $problems += 'This is an elevated shell. Run it from an unelevated terminal: mise''s trust and tools are per user, and just install asks for UAC itself.'
    }
    # A 32-bit PowerShell on 64-bit Windows reports x86 here and AMD64 in PROCESSOR_ARCHITEW6432
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($architecture -ne 'AMD64') {
        $problems += "This is a $architecture machine. winfiles needs x64: mise.lock only has windows-x64 downloads."
    }
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 22000) {
        $problems += "This is Windows build $build. winfiles needs Windows 11 (build 22000 or later)."
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        $problems += 'winget wasn''t found. It comes with App Installer: install or update App Installer from the Microsoft Store, then run this again.'
    }
    foreach ($file in 'mise.toml', 'mise.lock') {
        if (-not (Test-Path (Join-Path $repo $file))) {
            $problems += "$file is missing from $repo. Run this from a complete copy of the repo."
        }
    }
    if ($problems) {
        foreach ($problem in $problems) { Write-Host "  - $problem" -ForegroundColor Red }
        throw 'Nothing was changed. Fix the problems above, then run this again.'
    }

    # After the checks, so a run that stops at them leaves no run log
    . (Join-Path $PSScriptRoot 'winlog.ps1')
    Write-WinfilesLog bootstrap 'started: checks passed'
    Write-Host 'The bootstrap will:'
    Write-Host '  1. Update App Installer (winget) with winget'
    Write-Host '  2. Install mise with winget, unless it''s installed. winget may ask for UAC for the Visual C++ runtime mise needs'
    Write-Host '  3. Trust this repo''s mise.toml and install its tools (just, pwsh, gsudo, yq, DSC) for this user'
    Write-Host 'It changes nothing else, and doesn''t apply any configuration.'
    Write-Host ''

    Write-WinfilesLog bootstrap 'step 1 of 3: updating App Installer with winget'
    & winget install --id Microsoft.AppInstaller --exact --source winget --accept-package-agreements
    # 0x8A15002B: no newer version is available, so it's up to date
    if ($LASTEXITCODE -and $LASTEXITCODE -ne -1978335189) {
        Write-Error "Updating App Installer failed with code $LASTEXITCODE"
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -MiseOnly
    exit $LASTEXITCODE
}

. (Join-Path $PSScriptRoot 'winlog.ps1')
# mise may be installed already, by an earlier run, with this terminal opened before it
Update-ProcessPath
if (Get-Command mise -ErrorAction SilentlyContinue) {
    Write-WinfilesLog bootstrap 'step 2 of 3: mise is installed, skipping'
} else {
    Write-WinfilesLog bootstrap 'step 2 of 3: installing mise with winget (it may ask for UAC to install the Visual C++ runtime mise needs)'
    Invoke-Native winget @('install', '--id', 'jdx.mise', '--exact', '--source', 'winget', '--accept-package-agreements')
    Update-ProcessPath
    if (-not (Get-Command mise -ErrorAction SilentlyContinue)) {
        throw 'winget installed mise, but it isn''t on PATH. Open a new terminal and run this script again.'
    }
}

Set-Location $repo
Write-WinfilesLog bootstrap 'step 3 of 3: mise trust and mise install (just, pwsh, gsudo, yq, DSC)'
Invoke-Native mise @('trust')
Invoke-Native mise @('install')

Write-Host ''
Write-WinfilesLog bootstrap 'checking that the tools run a recipe (just hosts)'
Write-Host 'The configurations in this repo:'
Invoke-Native mise @('exec', '--', 'just', 'hosts')

Write-Host ''
Write-WinfilesLog bootstrap 'done: App Installer, mise and the repo''s tools are ready'
Write-Host ''
Write-Host 'Install a host from the list above (iris.system is host iris), from this terminal or any other:' -ForegroundColor Green
Write-Host ''
Write-Host "    cd $repo"
Write-Host '    .\install.cmd <host>'
Write-Host ''
Write-Host 'Run the same command again after the restart it asks for.'
exit 0
