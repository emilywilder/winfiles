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
