#Requires -Version 7.4

<#
.SYNOPSIS
Implements Winfiles.WinGet/Package (see wingetpackage.dsc.resource.json): Microsoft.WinGet/Package plus a stop-gap
_scope.

.DESCRIPTION
The stop-gap lasts until App Installer's resource has the canonical _scope PowerShell/DSC#828 proposes
(docs/config/winget.md). DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes
to stdout.
Everything but _scope goes to `winget dscv3 package`, as App Installer's manifest calls it, and its output comes back
with _scope added, so winget decides the state, and get and test ignore the scope a package is installed in. Only set
uses _scope: `winget dscv3` takes no scope, so a package that isn't installed is first installed with
`winget install --scope`, and `winget dscv3 package --set` then finds it there.

.EXAMPLE
'{"id":"GitHub.cli","_scope":"User"}' | ./wingetpackage.ps1 test

Reports whether GitHub CLI is installed, from dsc/resources.
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
    # For the run log (`just test-vm-log`): DSC prints a resource's messages to the console only, so a failure that
    # isn't also written here is missing from the log of the run it stopped (found 2026-11-19 in a test VM run)
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\scripts\winlog.ps1')
    $lines = [Collections.Generic.List[string]]::new()
}

process {
    $lines.Add($InputObject)
}

end {
    # A trap only covers the scope that declares it, so common.ps1 can't hold this one. The run log keeps the error
    # too; winget's own reason is on its stderr, which goes to DSC's, and in winget's log
    trap {
        $failure = $_
        Write-WinfilesLog -Phase winget -Message $failure.Exception.Message
        Exit-ResourceError -ErrorRecord $failure
    }

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    try {
        $desired = Read-ResourceInput -Line $lines
        $scope = $desired._scope
        $desired.PSObject.Properties.Remove('_scope')
        $upstream = ConvertTo-Json -InputObject $desired -Compress


        function Invoke-WinGetDsc {
            <#
            .SYNOPSIS
            Runs `winget dscv3 package --<operation>` with the instance without _scope.

            .DESCRIPTION
            Returns winget's exit code and its non-empty stdout lines: the state, then for test and set the
            differing properties. Its stderr goes straight to DSC's.
            #>
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param(
                # The operation to pass on.
                [Parameter(Mandatory)]
                [ValidateSet('get', 'test', 'set')]
                [string]$Operation
            )

            $output = @($upstream | winget dscv3 package "--$Operation")
            [pscustomobject]@{
                ExitCode = $LASTEXITCODE
                Lines    = @($output | Where-Object -FilterScript { "$_".Trim() })
            }
        }


        $installedHere = $false
        $installing = $Operation -eq 'set' -and $scope -and $desired._exist -ne $false
        if ($installing) {
            $before = Invoke-WinGetDsc -Operation get
            if ($before.ExitCode -ne 0) {
                throw (New-ResourceError -ExitCode $before.ExitCode -Message (
                        'winget dscv3 package --get {0} failed (0x{1:X8})' -f $desired.id, $before.ExitCode))
            }
            $installing = -not (ConvertFrom-Json -InputObject $before.Lines[0])._exist
        }
        if ($installing -and $PSCmdlet.ShouldProcess($desired.id, "Install with winget, scope $scope")) {
            # --exact matches the id's case, where matchOption's default ignores it: the documents spell ids as
            # winget does
            if ($desired.matchOption -and $desired.matchOption -notlike 'equals*') {
                throw "_scope needs matchOption equals or equalsCaseInsensitive, not $($desired.matchOption)"
            }
            $arguments = @(
                'install', '--id', $desired.id, '--exact', '--scope', "$scope".ToLower(), '--disable-interactivity'
            )
            if ($desired.source) {
                $arguments += '--source', $desired.source
            }
            if ($desired.version) {
                $arguments += '--version', $desired.version
            }
            switch ($desired.installMode ?? 'silent') {
                'silent' { $arguments += '--silent' }
                'interactive' { $arguments += '--interactive' }
            }
            if ($desired.acceptAgreements) {
                $arguments += '--accept-package-agreements', '--accept-source-agreements'
            }
            # winget's progress goes to stderr, which DSC logs at trace
            $output = @(& winget @arguments 2>&1 | ForEach-Object -Process { [Console]::Error.WriteLine($_); "$_" })
            if ($LASTEXITCODE -ne 0) {
                $last = $output | Where-Object -FilterScript { $_.Trim() } | Select-Object -Last 1
                throw (New-ResourceError -ExitCode 2 -Message (
                        'winget install --scope {0} {1} failed (0x{2:X8}): {3}' -f
                        "$scope".ToLower(), $desired.id, $LASTEXITCODE, $last))
            }
            $installedHere = $true
        }

        $run = Invoke-WinGetDsc -Operation $Operation
        if ($run.ExitCode -ne 0) {
            # winget's own code passes through, as from the get above
            throw (New-ResourceError -ExitCode $run.ExitCode -Message (
                    'winget dscv3 package --{0} {1} failed (0x{2:X8})' -f $Operation, $desired.id, $run.ExitCode))
        }
        for ($i = 0; $i -lt $run.Lines.Count; $i++) {
            if ($i -eq 0 -and $scope) {
                $state = ConvertFrom-Json -InputObject $run.Lines[0]
                Add-Member -InputObject $state -NotePropertyName _scope -NotePropertyValue $scope
                ConvertTo-Json -InputObject $state -Compress
            } elseif ($i -eq 1 -and $installedHere) {
                # winget dscv3 set found it installed and reports no change, but this set did change _exist
                $changed = @(ConvertFrom-Json -InputObject $run.Lines[1])
                if ($changed -notcontains '_exist') {
                    $changed = @('_exist') + $changed
                }
                ConvertTo-Json -InputObject $changed -Compress
            } else {
                $run.Lines[$i]
            }
        }
    } finally {
        $ErrorActionPreference = 'Continue'
    }

    # The manifest ends its command with `exit $LASTEXITCODE`, so always exit explicitly
    exit 0
}
