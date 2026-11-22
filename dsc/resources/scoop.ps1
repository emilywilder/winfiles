#Requires -Version 7.4

<#
.SYNOPSIS
Implements Winfiles/Scoop (see scoop.dsc.resource.json): Scoop itself, installed with Scoop's own installer.

.DESCRIPTION
DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
Buckets and apps are Winfiles/ScoopPackageList's job. The installer refuses an elevated shell, so set exits with 3
there instead of trying. It adds Scoop's shims folder to the user PATH, which is allowed for Scoop; this script
doesn't touch PATH itself.

.EXAMPLE
'{}' | ./scoop.ps1 test

Reports whether Scoop is installed, from dsc/resources.
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
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\scripts\privilege.ps1')
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
        $installerUrl = if ($desired.installerUrl) { $desired.installerUrl } else { 'https://get.scoop.sh' }
        $root = Get-ScoopRoot


        function Test-Scoop {
            <#
            .SYNOPSIS
            Tests whether Scoop is installed under its root.
            #>
            [CmdletBinding()]
            [OutputType([bool])]
            param()

            Test-Path -Path (Join-Path -Path $root -ChildPath 'apps\scoop\current\bin\scoop.ps1')
        }


        $installed = Test-Scoop

        if ($Operation -eq 'set' -and -not $installed -and $PSCmdlet.ShouldProcess($root, 'Install Scoop')) {
            # WINFILES_ELEVATED ("true" or "false") stands in for the check in tests, as for Invoke-AsUser.ps1
            $isElevated = if ($env:WINFILES_ELEVATED) { $env:WINFILES_ELEVATED -eq 'true' } else { Test-Elevated }
            if ($isElevated) {
                throw (New-ResourceError -ExitCode 3 -Message ("Scoop's installer refuses an elevated shell. " +
                        'Run `just home`, which runs it unelevated from either kind of shell'))
            }
            # Download to a file instead of piping into Invoke-Expression, so the installer runs as a script
            $tempPath = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "scoop-$([guid]::NewGuid())"
            $tempDir = New-Item -ItemType Directory -Path $tempPath
            try {
                $installer = Join-Path -Path $tempDir -ChildPath 'install.ps1'
                Invoke-WebRequest -Uri $installerUrl -OutFile $installer
                # The installer reports through Write-Host and Write-Error. Send all of it to stderr, and keep its
                # errors non-terminating, like Invoke-Scoop in scooppackagelist.ps1
                & {
                    $ErrorActionPreference = 'Continue'
                    & $installer *>&1 | ForEach-Object -Process { [Console]::Error.WriteLine("$_") }
                }
            } finally {
                Remove-Item -LiteralPath $tempDir -Recurse -Force
            }
            $root = Get-ScoopRoot
            $installed = Test-Scoop
            if (-not $installed) {
                $message = "Scoop's installer finished but Scoop isn't at $root"
                throw (New-ResourceError -ExitCode 2 -Message $message)
            }
        }

        $state = [ordered]@{
            installerUrl = $installerUrl
            root         = $root
            installed    = $installed
        }
        if ($Operation -eq 'test') {
            $state['_inDesiredState'] = $installed
        }
        ConvertTo-Json -InputObject $state -Compress
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
