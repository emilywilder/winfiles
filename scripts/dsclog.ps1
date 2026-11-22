# Shared by Set-Winfiles.ps1, Test-Winfiles.ps1, Set-RestartStage.ps1 and Find-RestartResource.ps1, which
# dot-source it, after winlog.ps1.
# Invoke-DscLogged runs `dsc config <operation>` on a document and returns its JSON, keeping a copy in
# ~/.local/state/winfiles/dsc, outside the repo because Copy-RepoToTestVm.ps1 replaces the repo. DSC's own messages
# still go to the console. $LASTEXITCODE is left as dsc's. The JSON has each resource's duration, the only record
# of how long a run took.


function Get-ResourceResult {
    <#
    .SYNOPSIS
    Returns the results of the resources in a list of DSC results, with each Include's replaced by those inside it.

    .DESCRIPTION
    An Include's result is the list of results from its document. After a `test` that list is the result itself;
    after a `set` it's the result's afterState (DSC 3.3.0, seen in a vm-quick install 2026-11-16, where reading
    only the first shape counted a home configuration's Includes as its resources and missed what its lists left
    missing).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # The results, from a configuration's JSON or an Include's.
        [Parameter(Position = 0)]
        [AllowNull()]
        [object[]]$Results
    )

    foreach ($resource in $Results) {
        if ($resource.result -is [array]) {
            Get-ResourceResult -Results $resource.result
        } elseif ($resource.type -eq 'Microsoft.DSC/Include' -and $resource.result.afterState -is [array]) {
            Get-ResourceResult -Results $resource.result.afterState
        } else {
            $resource
        }
    }
}


function Get-RestartReport {
    <#
    .SYNOPSIS
    Returns the restarts the resources in a list of results report, with each resource's Type and Name and the
    System it asks to restart.

    .DESCRIPTION
    Each resource's executionInformation.restartRequired, which DSC 3.3.0 fills from the `_restartRequired` a
    resource returns (checked 2026-11-18). Only a resource's own entry has it: the configuration's top-level
    executionInformation.restartRequired is empty when the resource is inside an Include, as the real documents
    have it, and so is the Include's. So this reads what Get-ResourceResult flattens, which also works on a
    document that has been flattened.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # The results, from a configuration's JSON.
        [Parameter(Position = 0)]
        [AllowNull()]
        [object[]]$Results
    )

    foreach ($resource in Get-ResourceResult -Results $Results) {
        foreach ($restart in @($resource.executionInformation.restartRequired)) {
            if ($restart) {
                [pscustomobject]@{ Type = $resource.type; Name = $resource.name; System = $restart.system }
            }
        }
    }
}


function Get-ResourceProblem {
    <#
    .SYNOPSIS
    Returns what a resource's result says is wrong.

    .DESCRIPTION
    Winfiles/FileContentList names what's wrong in its own outOfDate; other resources only have
    differingProperties. A package or bucket resource's _exist is reported as what it names instead (a winget id,
    a Scoop app or bucket), so a missing one is named.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # A resource's result, from Get-ResourceResult.
        [Parameter(Mandatory, Position = 0)]
        [pscustomobject]$Resource,

        # The state to read: actualState after a test, afterState after a set.
        [Parameter(Mandatory, Position = 1)]
        [ValidateSet('actualState', 'afterState')]
        [string]$State
    )

    $found = $Resource.result.$State
    $problems = (@($found.outOfDate) + @($Resource.result.differingProperties)) | Where-Object -FilterScript { $_ }
    $label = switch ($Resource.type) {
        { $_ -in 'Microsoft.WinGet/Package', 'Winfiles.WinGet/Package' } { $found.id }
        { $_ -in 'Winfiles.Scoop/Package', 'Winfiles.Scoop/Bucket' } { $found.name }
    }
    if ($label) {
        $problems = $problems | ForEach-Object -Process { if ($_ -eq '_exist') { $label } else { $_ } }
    }
    $problems
}


function Get-RunDocument {
    <#
    .SYNOPSIS
    Returns the document to give dsc, which has to be flat (no Includes), or nothing, saying why it refuses.

    .DESCRIPTION
    These scripts run what Invoke-Configuration.ps1 gives them, a batch it has flattened already; flattening is its
    job and `just flatten`'s (ConvertTo-FlatConfiguration.ps1), not theirs. A document with an Include fails here,
    naming what to run instead, rather than give dsc the Includes and lose the per-resource progress bar and the
    privilege batches. It prints and logs under -Phase why it refuses.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The document.
        [Parameter(Mandatory, Position = 0)]
        [string]$File,

        # The run log phase.
        [Parameter(Mandatory, Position = 1)]
        [string]$Phase
    )

    $problem = if (-not (Test-Path -LiteralPath $File -PathType Leaf)) {
        "$File doesn't exist"
    } else {
        $includes = & yq '[.resources[] | select(.type == "Microsoft.DSC/Include")] | length' $File
        if ($LASTEXITCODE) {
            "yq couldn't read it (exit code $LASTEXITCODE)"
        } elseif ([int]$includes) {
            ("it has $includes Include$(if ([int]$includes -ne 1) { 's' }), which this script doesn't flatten: " +
            'run it through scripts/Invoke-Configuration.ps1, or give this a flat copy from just flatten')
        }
    }
    if ($problem) {
        $message = "${File}: $problem"
        Write-Host -Object $message -ForegroundColor Red
        Write-WinfilesLog -Phase $Phase -Message $message
    } else {
        $File
    }
}


function Invoke-DscLogged {
    <#
    .SYNOPSIS
    Runs `dsc config <operation>` on a document and returns its JSON, keeping a copy in
    ~/.local/state/winfiles/dsc.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The dsc config operation.
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('get', 'test', 'set')]
        [string]$Operation,

        # The document.
        [Parameter(Mandatory, Position = 1)]
        [string]$File
    )

    $invokeDsc = Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-Dsc.ps1'
    $json = & $invokeDsc config $Operation --output-format json --file $File
    $exitCode = $LASTEXITCODE
    if ($json) {
        $folderPath = Join-Path -Path $HOME -ChildPath '.local\state\winfiles\dsc'
        $folder = New-Item -ItemType Directory -Force -Path $folderPath
        $document = (Split-Path -Path $File -Leaf) -replace '\.dsc\.yaml$'
        $name = '{0:yyyyMMdd-HHmmss}-{1}-{2}.json' -f (Get-Date), $Operation, $document
        Set-Content -Path (Join-Path -Path $folder -ChildPath $name) -Value $json
    }
    $Global:LASTEXITCODE = $exitCode
    $json
}
