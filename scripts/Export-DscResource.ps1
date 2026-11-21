#Requires -Version 7.4

<#
.SYNOPSIS
Exports current state for every DSC resource that supports export, one YAML file per resource.

.DESCRIPTION
Discovers resources as `just dsc` does, so App Installer's Microsoft.WinGet/* resources are found, and skips those whose
export needs elevation when the shell isn't elevated. Each resource's executionInformation (the run's duration) is
left out, so an export only changes with the state. A resource that fails gets a log of its stderr instead of its
YAML.

.EXAMPLE
./scripts/Export-DscResource.ps1

Exports every exportable resource to ./exports.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    # The folder for the exports.
    [string]$OutputDirectory = (Join-Path -Path (Split-Path -Path $PSScriptRoot) -ChildPath 'exports'),

    # Resources to leave out, by type.
    [string[]]$Exclude = @('Microsoft.DSC.Debug/Echo', 'Microsoft.PowerShell/Profile')
)

$ErrorActionPreference = 'Stop'
try {
    $null = New-Item -ItemType Directory -Force -Path $OutputDirectory
    $invalidChars = [IO.Path]::GetInvalidFileNameChars()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $isElevated = ([Security.Principal.WindowsPrincipal]$identity).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    # Same discovery as `just dsc`, so App Installer's Microsoft.WinGet/* resources are found
    $invokeDsc = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-Dsc.ps1'


    function Remove-ExecutionInformation {
        <#
        .SYNOPSIS
        Returns the lines of an export without each resource's executionInformation block.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'It filters lines, and changes nothing')]
        [CmdletBinding()]
        [OutputType([string])]
        param(
            # The export's YAML lines.
            [Parameter(Position = 0)]
            [AllowEmptyCollection()]
            [string[]]$Lines = @()
        )

        $skipping = $false
        foreach ($line in $Lines) {
            if ($line -match '^  executionInformation:\s*$') {
                $skipping = $true
            } elseif (-not $skipping -or $line -notmatch '^ {3,}\S') {
                $skipping = $false
                $line
            }
        }
    }


    Write-Progress -Activity 'Exporting DSC resources' -Status 'Discovering resources'
    $resources = & $invokeDsc resource list --output-format json |
        ConvertFrom-Json |
        Where-Object -FilterScript {
            $_.kind -ne 'adapter' -and $_.capabilities -contains 'export' -and $_.type -notin $Exclude
        }

    $selected = foreach ($resource in $resources) {
        $isDism = $resource.manifest.export.executable -eq 'dism_dsc'
        # dism_dsc fails with ERROR_ELEVATION_REQUIRED even where the manifest doesn't ask for elevation
        $needsElevation = $isDism -or $resource.manifest.export.requireSecurityContext -eq 'elevated'
        if (-not $isElevated -and $needsElevation) {
            Write-Warning -Message "$($resource.type) skipped: export requires an elevated shell"
        } else {
            $resource
        }
    }

    $index = 0
    foreach ($resource in $selected) {
        $type = $resource.type
        $prefix = Join-Path -Path $OutputDirectory -ChildPath "dsc.resource.export.$($type.Split($invalidChars) -join '_')"
        Write-Progress -Activity 'Exporting DSC resources' -Status $type -PercentComplete (
            100 * $index++ / @($selected).Count)
        if (-not $PSCmdlet.ShouldProcess("$prefix.yaml", "Export $type")) {
            continue
        }
        Write-Verbose -Message "Exporting $type $($resource.version) from $($resource.directory)"
        $yaml = & $invokeDsc resource export --resource $type --output-format yaml 2> "$prefix.log"

        if ($LASTEXITCODE -ne 0) {
            Remove-Item -Path "$prefix.yaml" -ErrorAction Ignore
            Write-Warning -Message "$type failed (exit $LASTEXITCODE), see $prefix.log"
        } else {
            Remove-ExecutionInformation -Lines $yaml | Set-Content -Path "$prefix.yaml"
            if ((Get-Item -Path "$prefix.log").Length -eq 0) {
                Remove-Item -Path "$prefix.log"
            }
        }
    }
    Write-Progress -Activity 'Exporting DSC resources' -Completed
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
