#Requires -Version 7.4

<#
.SYNOPSIS
Implements Winfiles/ScoopPackageList (see scooppackagelist.dsc.resource.json): Scoop buckets and apps.

.DESCRIPTION
DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
set installs the missing buckets, then the missing apps in one Scoop call, and fails with exit code 2, naming them,
when any of them is still missing afterwards.

.EXAMPLE
'{"packages":["git"]}' | ./scooppackagelist.ps1 test

Reports whether Scoop has git installed, from dsc/resources.
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
        $packages = @($desired.packages)
        $buckets = [ordered]@{}
        if ($desired.buckets) {
            foreach ($property in $desired.buckets.PSObject.Properties) {
                $buckets[$property.Name] = $property.Value
            }
        }

        $root = Get-ScoopRoot
        $scoop = Join-Path -Path $root -ChildPath 'apps\scoop\current\bin\scoop.ps1'


        # Read state from Scoop's folders: far faster than `scoop list` or `scoop export`, which load all of Scoop
        function Get-MissingBucket {
            <#
            .SYNOPSIS
            Returns the name of each wanted bucket that Scoop doesn't have.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param()

            @($buckets.Keys) | Where-Object -FilterScript {
                -not (Test-Path -Path (Join-Path -Path $root -ChildPath "buckets\$_"))
            }
        }


        function Get-MissingPackage {
            <#
            .SYNOPSIS
            Returns each wanted app, as it's listed, that isn't installed, or is installed from another bucket.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param()

            foreach ($package in $packages) {
                $bucket, $name = if ($package -match '/') { $package -split '/', 2 } else { $null, $package }
                # Scoop writes scoop-install.json; apps installed by older Scoop versions have install.json
                $installFile = @('scoop-install.json', 'install.json') |
                    ForEach-Object -Process { Join-Path -Path $root -ChildPath "apps\$name\current\$_" } |
                    Where-Object -FilterScript { Test-Path -Path $_ } |
                    Select-Object -First 1
                $installed = $installFile -and (
                    -not $bucket -or (Get-Content -Path $installFile -Raw | ConvertFrom-Json).bucket -eq $bucket)
                if (-not $installed) {
                    $package
                }
            }
        }


        function Invoke-Scoop {
            <#
            .SYNOPSIS
            Runs Scoop with its output on stderr and its errors non-terminating.

            .DESCRIPTION
            Scoop reports through Write-Host and Write-Error. Its line naming each app it starts on is raised to warn,
            because a slow download otherwise looks like a hang.
            #>
            [CmdletBinding()]
            param(
                # Scoop's arguments.
                [Parameter(Mandatory, ValueFromRemainingArguments)]
                [string[]]$ScoopArgument
            )

            $ErrorActionPreference = 'Continue'
            & $scoop @ScoopArgument *>&1 | ForEach-Object -Process {
                if ("$_" -like "Installing '*") {
                    Write-ResourceMessage -Level warn -Text "$_"
                } else {
                    [Console]::Error.WriteLine("$_")
                }
            }
        }


        # @() at each call: PowerShell unrolls function output, so 0 or 1 results wouldn't stay arrays
        $missingBuckets = @(Get-MissingBucket)
        $missing = @(Get-MissingPackage)

        $wanted = $missingBuckets + $missing
        if ($Operation -eq 'set' -and $wanted -and $PSCmdlet.ShouldProcess($wanted -join ', ', 'Install with Scoop')) {
            if (-not (Test-Path -Path $scoop)) {
                throw (New-ResourceError -ExitCode 3 -Message ("Scoop is not installed at $root; " +
                        'Winfiles/Scoop installs it, so make this list depend on one'))
            }
            # Adding a bucket other than main needs git, so a list that adds buckets should depend on one that
            # installs git. Scoop finds git through its shims, which its installer adds to the user PATH. A process
            # started before Scoop was installed (a fresh `just install`) doesn't have them, so add them for this
            # process only
            $shims = Join-Path -Path $root -ChildPath 'shims'
            if (($env:Path -split ';') -notcontains $shims) {
                $env:Path = "$shims;$env:Path"
            }
            foreach ($name in $missingBuckets) {
                $bucketArgs = @('bucket', 'add', $name) + @($buckets[$name] | Where-Object -FilterScript { $_ })
                Invoke-Scoop @bucketArgs
            }
            # One call installs the lot and checks for Scoop updates once; Scoop moves on past an app that fails
            if ($missing) {
                Invoke-Scoop install @missing
            }

            $failed = @(Get-MissingBucket) + @(Get-MissingPackage)
            if ($failed) {
                throw (New-ResourceError -ExitCode 2 -Message "Failed to install $($failed -join ', ')")
            }
            $missingBuckets = @()
            $missing = @()
        }

        $state = [ordered]@{
            packages       = $packages
            buckets        = $buckets
            missing        = $missing
            missingBuckets = $missingBuckets
        }
        if ($Operation -eq 'test') {
            $state['_inDesiredState'] = $missing.Count + $missingBuckets.Count -eq 0
        }
        ConvertTo-Json -InputObject $state -Compress -Depth 3
    } finally {
        $ErrorActionPreference = 'Continue'
    }

    # The manifest ends its command with `exit $LASTEXITCODE`, so always exit explicitly
    exit 0
}
