# Shared by the Winfiles.Scoop/Package and Winfiles.Scoop/Bucket scripts, which dot-source it after common.ps1 and
# scooproot.ps1.


function Invoke-Scoop {
    <#
    .SYNOPSIS
    Runs Scoop from a Scoop root, with its output on stderr and its errors non-terminating.

    .DESCRIPTION
    Fails with exit code 3 when Scoop isn't installed there: Winfiles/Scoop installs it. Scoop reports through
    Write-Host and Write-Error, all of which stays plain, so DSC shows it at trace only; its progress bar already
    names the app or bucket being installed.
    Adding a bucket other than main needs git, which Scoop finds through its shims. Its installer adds them to the
    user PATH, but a process started before Scoop was installed (a fresh `just install`) doesn't have them, so this
    adds them for this process only.
    #>
    [CmdletBinding()]
    param(
        # The Scoop root, from Get-ScoopRoot.
        [Parameter(Mandatory)]
        [string]$Root,

        # Scoop's arguments.
        [Parameter(Mandatory)]
        [string[]]$ScoopArgument
    )

    $scoop = Join-Path -Path $Root -ChildPath 'apps\scoop\current\bin\scoop.ps1'
    if (-not (Test-Path -Path $scoop)) {
        throw (New-ResourceError -ExitCode 3 -Message ("Scoop is not installed at $Root; " +
                'Winfiles/Scoop installs it, so make this resource depend on it'))
    }
    $shims = Join-Path -Path $Root -ChildPath 'shims'
    if (($env:Path -split ';') -notcontains $shims) {
        $env:Path = "$shims;$env:Path"
    }

    $ErrorActionPreference = 'Continue'
    & $scoop @ScoopArgument *>&1 | ForEach-Object -Process { [Console]::Error.WriteLine("$_") }
}


function Write-ResourceState {
    <#
    .SYNOPSIS
    Writes a Scoop resource's result to stdout: the state, then the properties that differ (test) or changed (set).

    .DESCRIPTION
    Both manifests return stateAndDiff. get writes the state only, and test adds _inDesiredState to it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The DSC operation.
        [Parameter(Mandatory)]
        [ValidateSet('get', 'test', 'set')]
        [string]$Operation,

        # The state.
        [Parameter(Mandatory)]
        [Collections.Specialized.OrderedDictionary]$State,

        # The properties that differ, for test, or that set changed.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Property
    )

    if ($Operation -eq 'test') {
        $State['_inDesiredState'] = $Property.Count -eq 0
    }
    ConvertTo-Json -InputObject $State -Compress
    if ($Operation -ne 'get') {
        ConvertTo-Json -InputObject @($Property) -Compress
    }
}
