# Shared by Set-Winfiles.ps1 and Test-Winfiles.ps1, which dot-source it.
# Runs `dsc config <operation>` on a document and returns its JSON, keeping a copy in ~/.local/state/winfiles/dsc,
# outside the repo because Copy-RepoToTestVm.ps1 replaces the repo. DSC's own messages still go to the console.
# $LASTEXITCODE is left as dsc's. The JSON has each resource's duration, the only record of how long a run took.

# An Include's result is the list of results from its document, so this returns the results of the resources inside.
# After a `test` that list is the result itself; after a `set` it's the result's afterState (DSC 3.3.0, seen in a
# vm-quick install 2026-11-16, where reading only the first shape counted a home configuration's Includes as its
# resources and missed what its lists left missing)
function Get-ResourceResult($Results) {
    foreach ($resource in $Results) {
        if ($resource.result -is [array]) { Get-ResourceResult $resource.result }
        elseif ($resource.type -eq 'Microsoft.DSC/Include' -and $resource.result.afterState -is [array]) { Get-ResourceResult $resource.result.afterState }
        else { $resource }
    }
}

# The restarts the resources in a result report: each one's executionInformation.restartRequired, which DSC 3.3.0
# fills from the `_restartRequired` a resource returns (checked 2026-11-18). Only a resource's own entry has it: the
# configuration's top-level executionInformation.restartRequired is empty when the resource is inside an Include, as the
# real documents have it, and so is the Include's. So this reads what Get-ResourceResult flattens, which also works on a
# document that has been flattened. Returns objects with the resource's Type and Name and the System it asks to restart
function Get-RestartReport($Results) {
    foreach ($resource in Get-ResourceResult $Results) {
        foreach ($restart in @($resource.executionInformation.restartRequired)) {
            if ($restart) { [pscustomobject]@{ Type = $resource.type; Name = $resource.name; System = $restart.system } }
        }
    }
}
# What a resource's state says is wrong, for a list of results: the lists name what's wrong in their own properties
# (missing, missingBuckets, outOfDate); other resources only have differingProperties. A package resource's _exist is
# reported as its id instead, as the lists name their missing ids. $State is the state to read: actualState after a
# test, afterState after a set
function Get-ResourceProblem($Resource, [string]$State) {
    $found = $Resource.result.$State
    $problems = @($found.missing) + @($found.missingBuckets) + @($found.outOfDate) + @($Resource.result.differingProperties) |
        Where-Object { $_ }
    if ($Resource.type -in 'Microsoft.WinGet/Package', 'Winfiles.WinGet/Package') {
        $problems = $problems | ForEach-Object { if ($_ -eq '_exist' -and $found.id) { $found.id } else { $_ } }
    }
    $problems
}

# The document to give dsc for -File: a flat copy of it (ConvertTo-FlatConfiguration.ps1), kept in
# ~/.local/state/winfiles/flat under the same name, so a kept result is still named after the document; or -File
# itself with -NoFlatten. It logs which under -Phase, and needs winlog.ps1 dot-sourced. When the document can't be
# flattened it prints and logs why, and returns nothing.
function Get-RunDocument([string]$File, [string]$Phase, [switch]$NoFlatten) {
    if ($NoFlatten) {
        Write-WinfilesLog $Phase "not flattened: dsc runs $File itself"
        return $File
    }
    # USERPROFILE rather than $HOME, as in winlog.ps1: Set-System.ps1's tests run it in their own process, where $HOME
    # can't be pointed elsewhere
    try {
        $flat = & (Join-Path $PSScriptRoot 'ConvertTo-FlatConfiguration.ps1') $File
    } catch {
        # Its messages start with the document already
        $message = "${File}: couldn't flatten it: $($_.Exception.Message -replace "^$([regex]::Escape($File)): ")"
        Write-Host $message -ForegroundColor Red
        Write-WinfilesLog $Phase $message
        return
    }
    Write-WinfilesLog $Phase "flattened to $flat"
    $flat
}

function Invoke-DscLogged {
    param([string]$Operation, [string]$File)
    $json = & (Join-Path $PSScriptRoot 'Invoke-Dsc.ps1') config $Operation --output-format json --file $File
    $exitCode = $LASTEXITCODE
    if ($json) {
        $folder = New-Item -ItemType Directory -Force (Join-Path $HOME '.local\state\winfiles\dsc')
        $document = (Split-Path $File -Leaf) -replace '\.dsc\.yaml$'
        $json | Set-Content (Join-Path $folder ('{0:yyyyMMdd-HHmmss}-{1}-{2}.json' -f (Get-Date), $Operation, $document))
    }
    $global:LASTEXITCODE = $exitCode
    $json
}
