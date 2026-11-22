#Requires -Version 7.4

<#
.SYNOPSIS
Implements Winfiles.Scoop/Bucket (see scoopbucket.dsc.resource.json): one Scoop bucket, added.

.DESCRIPTION
DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
State comes from the bucket's folder under the Scoop root, not from running Scoop; the repository it was added
from isn't checked. set adds a missing bucket with `scoop bucket add <name> [<source>]`, and fails with exit code 2
when it's still missing afterwards. It never removes one.

.EXAMPLE
'{"name":"extras","source":"https://github.com/ScoopInstaller/Extras"}' | ./scoopbucket.ps1 test

Reports whether Scoop has the extras bucket, from dsc/resources.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # The DSC operation.
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('get', 'test', 'set')]
    [string]$Operation,

    # A line of the instance's JSON, from DSC on stdin.
    [Parameter(ValueFromPipeline)]
    [AllowEmptyString()]
    [string]$InputObject
)

begin {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'common.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'scooproot.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'scoopcommand.ps1')
    $lines = [Collections.Generic.List[string]]::new()
}

process {
    $lines.Add($InputObject)
}

end {
    # A trap only covers the scope that declares it, so common.ps1 can't hold this one
    trap { Exit-ResourceError -ErrorRecord $_ }

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    try {
        $desired = Read-ResourceInput -Line $lines
        $name = $desired.name
        if ($desired._exist -eq $false) {
            throw (New-ResourceError -ExitCode 4 -Message ("Winfiles.Scoop/Bucket doesn't remove buckets: " +
                    "remove $name with scoop bucket rm, and drop _exist"))
        }
        $root = Get-ScoopRoot
        $folder = Join-Path -Path $root -ChildPath "buckets\$name"

        $exist = Test-Path -Path $folder
        $changed = @()
        if ($Operation -eq 'set' -and -not $exist -and $PSCmdlet.ShouldProcess($name, 'Add the Scoop bucket')) {
            # Adding any bucket other than main needs git: make this depend on a Winfiles.Scoop/Package for git
            $bucketArgs = @('bucket', 'add', $name) + @($desired.source | Where-Object -FilterScript { $_ })
            Invoke-Scoop -Root $root -ScoopArgument $bucketArgs
            $exist = Test-Path -Path $folder
            if (-not $exist) {
                throw (New-ResourceError -ExitCode 2 -Message "Failed to add the $name bucket")
            }
            $changed = @('_exist')
        }

        $state = [ordered]@{ name = $name; _exist = $exist }
        # @(): an if unrolls what it returns, so an empty list would become $null
        $diff = @(if ($Operation -eq 'set') { $changed } elseif (-not $exist) { '_exist' })
        Write-ResourceState -Operation $Operation -State $state -Property $diff
    } catch {
        # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
        $failure = $_
        throw $failure
    } finally {
        $ErrorActionPreference = 'Continue'
    }

    # The manifest ends its command with `exit $LASTEXITCODE`, so always exit explicitly
    exit 0
}
