#Requires -Version 5.1

<#
.SYNOPSIS
    Bootstraps winfiles on a fresh Windows 11 install: winget, mise and the
    repo's tools, so install.cmd (`winfiles.ps1 install <host>`) can run. It
    doesn't run it.

.DESCRIPTION
    Runs under the built-in Windows PowerShell 5.1, since nothing else is
    installed yet. Run it unelevated: mise's trust and tools are per user, and
    the install asks for UAC itself. It reads nothing from dsc/: the machine
    configuration is the install's business.
    1. Checks, before changing anything: an unelevated shell, x64 (mise.lock
       only covers windows-x64), Windows 11, winget found, and mise.toml and
       mise.lock next to scripts/. It lists every problem, then stops.
    2. Updates App Installer, which provides winget and the WinGet DSC module
       that the install relies on. A new Windows image can ship one too old:
       with 1.26.509 the WinGet module fails when elevated (0x800706BA), and
       setting the msstore source explicit removes the source and fails.
       `--source winget` keeps winget away from the msstore source, which
       stops to ask for its terms on a fresh install;
       `--accept-package-agreements` accepts the licence. If winget reports
       success but the old version is still registered, the update is only
       staged (Windows can't swap App Installer while winget runs from it),
       so it registers the update with Add-AppxPackage -RegisterByFamilyName
       rather than leave it to the next sign-in, mid-install.
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
    6. `mise trust` and `mise install`: pwsh, gsudo, yq and DSC.
    7. Runs `mise exec -- pwsh -File winfiles.ps1 hosts`, which checks that
       mise's pwsh runs a command, and lists the hosts install.cmd can take.
    8. Prints the command to run next.
    Each step skips what's already done, so it's safe to run again.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Initialize-Winfiles.ps1

    Bootstraps winfiles from this checkout, as bootstrap.cmd does.
#>
[CmdletBinding()]
param(
    # Only steps 4 to 8: no checks and no App Installer update. The script passes this when it starts itself again
    # after the update.
    [switch]$MiseOnly
)

$ErrorActionPreference = 'Stop'
try {
    $repo = Split-Path -Path $PSScriptRoot


    function Update-ProcessPath {
        <#
        .SYNOPSIS
        Reloads PATH for this process from the machine and user values, never changing the persistent one.
        #>
        [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
        param()

        if ($PSCmdlet.ShouldProcess('PATH of this process', 'Reload')) {
            $env:Path = ([Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User'))
        }
    }


    function Get-AppInstallerVersion {
        <#
        .SYNOPSIS
        Returns the version of App Installer registered for this user.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param()

        (Get-AppxPackage -Name Microsoft.DesktopAppInstaller |
            Sort-Object -Property { [version]$_.Version } |
            Select-Object -Last 1).Version
    }


    function Invoke-Native {
        <#
        .SYNOPSIS
        Runs a native command, and writes an error, which stops the script, when it exits non-zero.
        #>
        [CmdletBinding()]
        param(
            # The command.
            [Parameter(Mandatory, Position = 0)]
            [string]$Command,

            # Its arguments.
            [Parameter(Position = 1)]
            [string[]]$Arguments = @()
        )

        & $Command @Arguments
        if ($LASTEXITCODE) {
            Write-Error -Message "$Command $Arguments exited with code $LASTEXITCODE"
        }
    }


    if (-not $MiseOnly) {
        $problems = @()
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $isAdmin = ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) {
            $problems += ('This is an elevated shell. Run it from an unelevated terminal: ' +
                'mise''s trust and tools are per user, and the install asks for UAC itself.')
        }
        # A 32-bit PowerShell on 64-bit Windows reports x86 here and AMD64 in PROCESSOR_ARCHITEW6432
        $architecture = if ($env:PROCESSOR_ARCHITEW6432) {
            $env:PROCESSOR_ARCHITEW6432
        } else {
            $env:PROCESSOR_ARCHITECTURE
        }
        if ($architecture -ne 'AMD64') {
            $problems += ("This is a $architecture machine. " +
                'winfiles needs x64: mise.lock only has windows-x64 downloads.')
        }
        $build = [Environment]::OSVersion.Version.Build
        if ($build -lt 22000) {
            $problems += "This is Windows build $build. winfiles needs Windows 11 (build 22000 or later)."
        }
        if (-not (Get-Command -Name winget -ErrorAction SilentlyContinue)) {
            $problems += ('winget wasn''t found. It comes with App Installer: ' +
                'install or update App Installer from the Microsoft Store, then run this again.')
        }
        foreach ($file in 'mise.toml', 'mise.lock') {
            if (-not (Test-Path -Path (Join-Path -Path $repo -ChildPath $file))) {
                $problems += "$file is missing from $repo. Run this from a complete copy of the repo."
            }
        }
        if ($problems) {
            foreach ($problem in $problems) {
                Write-Host -Object "  - $problem" -ForegroundColor Red
            }
            throw 'Nothing was changed. Fix the problems above, then run this again.'
        }

        # After the checks, so a run that stops at them leaves no run log
        . (Join-Path -Path $PSScriptRoot -ChildPath 'winlog.ps1')
        Write-WinfilesLog -Phase bootstrap -Message 'started: checks passed'
        Write-Host -Object 'The bootstrap will:'
        Write-Host -Object '  1. Update App Installer (winget) with winget'
        Write-Host -Object ('  2. Install mise with winget, unless it''s installed. ' +
            'winget may ask for UAC for the Visual C++ runtime mise needs')
        Write-Host -Object ('  3. Trust this repo''s mise.toml and install its tools ' +
            '(pwsh, gsudo, yq, DSC) for this user')
        Write-Host -Object 'It changes nothing else, and doesn''t apply any configuration.'
        Write-Host -Object ''

        Write-WinfilesLog -Phase bootstrap -Message 'step 1 of 3: updating App Installer with winget'
        $before = Get-AppInstallerVersion
        $installArguments = @(
            'install', '--id', 'Microsoft.AppInstaller', '--exact', '--source', 'winget'
            '--accept-package-agreements'
        )
        & winget @installArguments
        $exitCode = $LASTEXITCODE
        # 0x8A15000F: the source's data is missing ("Failed when opening source(s)"), seen as the first winget call
        # on a test VM just restored from a checkpoint (2026-11-19), and gone at the next try. Update the sources
        # and try once more
        if ($exitCode -eq -1978335217) {
            Write-Host -Object ('winget says its source data is missing (0x8A15000F). ' +
                'Updating its sources and trying once more.')
            Write-WinfilesLog -Phase bootstrap -Message ('winget says its source data is missing (0x8A15000F): ' +
                'updating its sources and trying once more')
            & winget source update
            & winget @installArguments
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq -1978335217) {
                Write-Error -Message ("winget's source data is still missing (0x8A15000F) " +
                    "after updating its sources. Try the 'winget source reset' command, as winget suggests, " +
                    'then run this again.')
            }
        }
        # 0x8A15002B: no newer version is available, so it's up to date
        if ($exitCode -and $exitCode -ne -1978335189) {
            Write-Error -Message "Updating App Installer failed with code $exitCode"
        }
        # winget can report success with the update only staged: Windows couldn't swap it in while this winget,
        # from App Installer, was running (0x80073D02 in winget's log), and registers it at the next sign-in
        # instead. That swap then raced the install's system step after the WSL restart (test VM, 2026-11-17).
        # winget has exited now, so register it here
        if (-not $exitCode -and (Get-AppInstallerVersion) -eq $before) {
            Write-WinfilesLog -Phase bootstrap -Message ("App Installer's update is staged, " +
                "but $before is still registered: registering the update")
            $register = @{
                RegisterByFamilyName     = $true
                MainPackage              = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'
                ForceApplicationShutdown = $true
            }
            Add-AppxPackage @register
            $after = Get-AppInstallerVersion
            if ($after -eq $before) {
                throw ("winget updated App Installer, but $before is still registered. " +
                    'Restart Windows, then run this again.')
            }
            Write-WinfilesLog -Phase bootstrap -Message "registered App Installer $after"
        }

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -MiseOnly
        exit $LASTEXITCODE
    }

    . (Join-Path -Path $PSScriptRoot -ChildPath 'winlog.ps1')
    # mise may be installed already, by an earlier run, with this terminal opened before it
    Update-ProcessPath
    if (Get-Command -Name mise -ErrorAction SilentlyContinue) {
        Write-WinfilesLog -Phase bootstrap -Message 'step 2 of 3: mise is installed, skipping'
    } else {
        Write-WinfilesLog -Phase bootstrap -Message ('step 2 of 3: installing mise with winget ' +
            '(it may ask for UAC to install the Visual C++ runtime mise needs)')
        Invoke-Native -Command winget -Arguments @(
            'install', '--id', 'jdx.mise', '--exact', '--source', 'winget', '--accept-package-agreements'
        )
        Update-ProcessPath
        if (-not (Get-Command -Name mise -ErrorAction SilentlyContinue)) {
            throw 'winget installed mise, but it isn''t on PATH. Open a new terminal and run this script again.'
        }
    }

    Set-Location -Path $repo
    $message = 'step 3 of 3: mise trust and mise install (pwsh, gsudo, yq, DSC)'
    Write-WinfilesLog -Phase bootstrap -Message $message
    Invoke-Native -Command mise -Arguments @('trust')
    Invoke-Native -Command mise -Arguments @('install')

    Write-Host -Object ''
    Write-WinfilesLog -Phase bootstrap -Message 'checking that the tools run a command (winfiles.ps1 hosts)'
    Write-Host -Object 'The configurations in this repo:'
    $runner = Join-Path -Path $repo -ChildPath 'winfiles.ps1'
    $hosts = @('exec', '--', 'pwsh', '-NoLogo', '-NoProfile', '-File', $runner, 'hosts')
    Invoke-Native -Command mise -Arguments $hosts

    Write-Host -Object ''
    Write-WinfilesLog -Phase bootstrap -Message 'done: App Installer, mise and the repo''s tools are ready'
    Write-Host -Object ''
    Write-Host -ForegroundColor Green -Object (
        'Install a host from the list above (iris.system is host iris), from this terminal or any other:')
    Write-Host -Object ''
    Write-Host -Object "    cd $repo"
    Write-Host -Object '    .\install.cmd <host>'
    Write-Host -Object ''
    Write-Host -Object 'Run the same command again after the restart it asks for.'
    exit 0
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
