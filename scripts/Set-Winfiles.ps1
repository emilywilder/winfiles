#Requires -Version 7.4

<#
.SYNOPSIS
Applies one DSC configuration, keeping its results in ~/.local/state/winfiles/dsc, and exits with dsc's exit code.

.DESCRIPTION
It applies the document it is given, which has to be flat: Invoke-Configuration.ps1 flattens an entry into batches
(ConvertTo-FlatConfiguration.ps1) and runs this on each, so one dsc process runs every resource of a batch and its
progress bar names each resource rather than each Include. A document with an Include is refused, naming what to
run. Those results give each resource's duration. A resource that fails stops the configuration, and dsc exits
non-zero. It says when it starts and how it ended, with the time it took and what the resources left missing. A
failure or something left missing is printed; every event, with the phase ("[system] ..."), goes to
~/.local/state/winfiles/run.log.

.EXAMPLE
./scripts/Set-Winfiles.ps1 ~/.local/state/winfiles/flat/emily@iris.home.dsc.yaml

Applies emily@iris's flat home configuration.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # The document to apply, which has to be flat.
    [Parameter(Mandatory, Position = 0)]
    [string]$File
)

$ErrorActionPreference = 'Stop'
try {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'winlog.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'dsclog.ps1')

    # iris.system.dsc.yaml is "system" and emily@iris.home.dsc.yaml "home"; a batch of Invoke-Configuration.ps1
    # (iris.system.2-user.dsc.yaml) is "apply", the phase that script logs under
    $phase = ((Split-Path -Path $File -Leaf) -replace '\.dsc\.yaml$') -replace '^.*\.'
    if ($phase -match '^\d+-(elevated|user)$') {
        $phase = 'apply'
    }

    Write-WinfilesLog -Phase $phase -Message "applying $File"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $document = Get-RunDocument -File $File -Phase $phase
    if (-not $document) {
        exit 1
    }
    if (-not $PSCmdlet.ShouldProcess($File, 'dsc config set')) {
        exit 0
    }
    $json = Invoke-DscLogged -Operation set -File $document
    $exitCode = $LASTEXITCODE
    $took = Format-WinfilesDuration -Duration $timer.Elapsed

    if ($exitCode) {
        # Named, because features and system fail through the same script in one gsudo call, and the runner adds
        # no exit message
        $message = "${File}: dsc failed with exit code $exitCode after $took"
        Write-Host -Object $message -ForegroundColor Red
        Write-WinfilesLog -Phase $phase -Message $message
    } else {
        $resources = @()
        $notDone = @()
        try {
            $resources = @(Get-ResourceResult -Results ($json | ConvertFrom-Json).results)
            $notDone = @($resources | Where-Object -FilterScript {
                    Get-ResourceProblem -Resource $_ -State afterState
                })
        } catch {
            $failure = $_
            $message = "dsc's results couldn't be read: $($failure.Exception.Message)"
            Write-WinfilesLog -Phase $phase -Message $message
        }
        if ($notDone) {
            $message = ("done in $took, $($resources.Count) resources, " +
                "$($notDone.Count) not fully applied (winfiles.ps1 check lists them)")
            Write-Host -Object $message -ForegroundColor Yellow
            Write-WinfilesLog -Phase $phase -Message $message
            foreach ($resource in $notDone) {
                $problems = (Get-ResourceProblem -Resource $resource -State afterState) -join ', '
                $message = "  $($resource.type) '$($resource.name)': $problems"
                Write-Host -Object $message
                Write-WinfilesLog -Phase $phase -Message $message
            }
        } else {
            Write-WinfilesLog -Phase $phase -Message "done in $took, $($resources.Count) resources"
        }
    }
    exit $exitCode
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
