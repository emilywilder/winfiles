#Requires -Version 7.4

<#
.SYNOPSIS
Implements Winfiles.Scoop/Package (see scooppackage.dsc.resource.json): one Scoop app, installed.

.DESCRIPTION
DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
State comes from the app's folder under the Scoop root, not from running Scoop, which is far slower. An app
installed from another bucket than the one given differs in bucket. set installs a missing app with
`scoop install [<bucket>/]<name>`, and fails with exit code 2 when it's still missing or from another bucket
afterwards. It never uninstalls.

.EXAMPLE
'{"name":"meld","bucket":"extras"}' | ./scooppackage.ps1 test

Reports whether Meld is installed from the extras bucket, from dsc/resources.
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
        $bucket = $desired.bucket
        $app = if ($bucket) { "$bucket/$name" } else { $name }
        if ($desired._exist -eq $false) {
            throw (New-ResourceError -ExitCode 4 -Message (
                    "Winfiles.Scoop/Package doesn't uninstall: remove $app with scoop uninstall, and drop _exist"))
        }
        $root = Get-ScoopRoot


        function Get-PackageState {
            <#
            .SYNOPSIS
            Returns the app's state, and the properties that differ from the desired one.
            #>
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param()

            # Scoop writes scoop-install.json; apps installed by older Scoop versions have install.json
            $installFile = @('scoop-install.json', 'install.json') |
                ForEach-Object -Process { Join-Path -Path $root -ChildPath "apps\$name\current\$_" } |
                Where-Object -FilterScript { Test-Path -Path $_ } |
                Select-Object -First 1
            $state = [ordered]@{ name = $name }
            $differing = @()
            if ($installFile) {
                $installedBucket = (Get-Content -Path $installFile -Raw | ConvertFrom-Json).bucket
                if ($installedBucket) {
                    $state['bucket'] = $installedBucket
                }
                if ($bucket -and $installedBucket -ne $bucket) {
                    $differing += 'bucket'
                }
            } else {
                $differing += '_exist'
            }
            $state['_exist'] = [bool]$installFile
            [pscustomobject]@{ State = $state; Differing = $differing }
        }


        $found = Get-PackageState
        $changed = @()
        if ($Operation -eq 'set' -and $found.Differing -contains '_exist' -and
            $PSCmdlet.ShouldProcess($app, 'Install with Scoop')) {
            Invoke-Scoop -Root $root -ScoopArgument 'install', $app
            $found = Get-PackageState
            if ($found.Differing -contains '_exist') {
                throw (New-ResourceError -ExitCode 2 -Message "Failed to install $app")
            }
            $changed = @('_exist')
        }
        # Scoop won't install an app that's already there from another bucket, so set doesn't try
        if ($Operation -eq 'set' -and $found.Differing -contains 'bucket') {
            throw (New-ResourceError -ExitCode 2 -Message (
                    "$name is installed from $($found.State.bucket ?? 'no bucket'), not $bucket; " +
                    'scoop uninstall it first'))
        }

        # @(): an if unrolls what it returns, so an empty list would become $null
        $diff = @(if ($Operation -eq 'set') { $changed } else { $found.Differing })
        Write-ResourceState -Operation $Operation -State $found.State -Property $diff
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
