#Requires -Version 7.4

<#
.SYNOPSIS
Uninstalls every package the winget-paths survey installs, in a test VM, so its next run starts clean.

.DESCRIPTION
The survey runs it unelevated before each path and at the end; run it by hand from the VM's desktop, unelevated,
after an interrupted run. It uninstalls the per-user packages itself, since winget refuses to uninstall a per-user
package from an elevated process (0x8A15007D, 2026-11-17), then starts itself elevated through a UAC prompt for
what's left: machine-wide packages, and Microsoft.UI.Xaml.2.6, which winget reports uninstalled but keeps listing
when unelevated (2026-11-17). An uninstaller can raise its own UAC prompt (VS Code's, after an elevated install),
so it names each uninstall before starting it. Exits 1, naming them, if any package is still installed.
Refuses to run elevated, and on anything but a Hyper-V guest.

.EXAMPLE
mise exec -- pwsh -NoProfile -File winget-paths/Clear-WinGetPath.ps1

From surveys/: uninstalls what the survey left installed.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # Set when it starts itself elevated for the second pass.
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
try {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'WinGetPaths.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\scripts\winlog.ps1')

    Assert-TestVm
    $isElevated = Test-Elevated
    if ($isElevated -and -not $Elevated) {
        Write-Host -Object ('Run this unelevated: winget won''t uninstall per-user packages elevated. ' +
            'It asks for UAC itself.')
        exit 1
    }
    $context = if ($isElevated) { 'elevated' } else { 'unelevated' }


    function Remove-Listed {
        <#
        .SYNOPSIS
        Uninstalls each id winget lists in one of the scopes, and waits up to 30s for it to go: some uninstallers
        return first.
        #>
        [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
        param(
            # The scopes to uninstall from.
            [Parameter(Mandatory)]
            [ValidateSet('user', 'machine')]
            [string[]]$Scope
        )

        foreach ($id in Get-WinGetPathId) {
            $installedIn = Get-InstalledScope -Id $id
            if ($installedIn -notin $Scope -or -not $PSCmdlet.ShouldProcess($id, "Uninstall ($installedIn)")) {
                continue
            }
            Write-Host -Object "Uninstalling $id ($installedIn, $context)..."
            $uninstall = @(
                'uninstall', '--id', $id, '--exact', '--source', 'winget', '--scope', $installedIn, '--silent'
                '--accept-source-agreements', '--disable-interactivity'
            )
            $output = winget @uninstall 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -eq 0) {
                $clock = [Diagnostics.Stopwatch]::StartNew()
                while ((Get-InstalledScope -Id $id) -eq $installedIn -and $clock.Elapsed.TotalSeconds -lt 30) {
                    Start-Sleep -Seconds 3
                }
            }
            $last = $output | Where-Object -FilterScript { "$_".Trim() } | Select-Object -Last 1
            $message = "clear $context ${id} ($installedIn): exit $exitCode, $last"
            Write-WinfilesLog -Phase winget-paths -Message $message
        }
    }


    if ($Elevated) {
        # Everything still listed: machine-wide packages, and MSIX ones such as UI.Xaml, which elevated winget does
        # remove
        Remove-Listed -Scope user, machine
        exit 0
    }

    Remove-Listed -Scope user
    $left = @(Get-WinGetPathId | Where-Object -FilterScript { Get-InstalledScope -Id $_ })
    if ($left) {
        Write-Host -Object "Asking for elevation to uninstall $($left -join ', ')"
        $pwsh = (Get-Process -Id $PID).Path
        try {
            $arguments = '-NoLogo', '-NoProfile', '-File', "`"$PSCommandPath`"", '-Elevated'
            Start-Process -FilePath $pwsh -Verb RunAs -Wait -ArgumentList $arguments
        } catch {
            $failure = $_
            Write-Host -Object "The elevated pass didn't run: $($failure.Exception.Message)"
        }
    }

    $left = @(Get-WinGetPathId | ForEach-Object -Process {
            $installedIn = Get-InstalledScope -Id $_
            if ($installedIn) {
                "$_ ($installedIn)"
            }
        })
    if ($left) {
        Write-WinfilesLog -Phase winget-paths -Message "clear left installed: $($left -join ', ')"
        Write-Host -Object ("Still installed: $($left -join ', '). " +
            'See the clear lines in run.log (winfiles.ps1 test-vm-log).')
        exit 1
    }
    Write-WinfilesLog -Phase winget-paths -Message 'clear: none of the suite''s packages are installed'
    Write-Host -Object 'None of the suite''s packages are installed.'
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
