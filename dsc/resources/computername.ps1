#Requires -Version 7.4

<#
.SYNOPSIS
Implements Winfiles/ComputerName (see computername.dsc.resource.json): the computer's name.

.DESCRIPTION
DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
Microsoft.Windows/Registry was ruled out: the name lives in several places (the registry, the TCP/IP hostname, the
NetBIOS name), and Rename-Computer is what keeps them in step and validates the name. DSC 3.3.0 has no computer
resource of its own.
A rename only takes effect at the next restart. Windows keeps the name it's using in ActiveComputerName and the one
it will use in ComputerName. test is in the desired state only once the first matches, so a rename waiting for its
restart still reports false. set renames only when the second differs, so running it again while the rename waits
changes nothing, and warns instead, since a resource can't restart Windows.
Every operation tells DSC about the restart through _restartRequired, a top-level property DSC 3.3.0 collects into
the result's executionInformation.restartRequired (checked 2026-11-18: under _metadata.Microsoft.DSC it's ignored
with a warning). get says so while a rename waits. test and set say so while the active name isn't the wanted one,
which includes before the rename is made, so a test run shows ahead of time that set will need a restart. DSC only
reports it: it doesn't restart, so the install does (docs/run/restarts.md).

.EXAMPLE
'{"name":"iris"}' | ./computername.ps1 test

Reports whether the computer is named iris, from dsc/resources.
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


        # What these read is the registry, which the tests can't replace with files, so they're functions to mock
        function Get-ActiveComputerName {
            <#
            .SYNOPSIS
            Returns the name the computer is using now.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param()

            $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName'
            (Get-ItemProperty -Path $key).ComputerName
        }


        function Get-PendingComputerName {
            <#
            .SYNOPSIS
            Returns the name the computer will have after the next restart.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param()

            $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName'
            (Get-ItemProperty -Path $key).ComputerName
        }


        function Test-ComputerName {
            <#
            .SYNOPSIS
            Tests a name against what Rename-Computer accepts for a workgroup computer's NetBIOS name.
            #>
            [CmdletBinding()]
            [OutputType([bool])]
            param(
                # The name to test.
                [Parameter(Mandatory)]
                [AllowEmptyString()]
                [string]$Name
            )

            $Name -match '^(?!\d+$)[A-Za-z0-9][A-Za-z0-9-]{0,14}$'
        }


        function Get-State {
            <#
            .SYNOPSIS
            Returns the resource's state: the wanted name, the active one and the pending one.
            #>
            [CmdletBinding()]
            [OutputType([Collections.Specialized.OrderedDictionary])]
            param()

            [ordered]@{
                name        = $desired.name
                activeName  = Get-ActiveComputerName
                pendingName = Get-PendingComputerName
            }
        }


        $renameNeeded = $Operation -eq 'set' -and (Get-PendingComputerName) -ine $desired.name
        if ($renameNeeded -and -not (Test-ComputerName -Name $desired.name)) {
            throw (New-ResourceError -ExitCode 2 -Message ("'$($desired.name)' isn't a valid computer name: " +
                    'use 1 to 15 letters, digits and hyphens, not only digits'))
        }
        if ($renameNeeded -and $PSCmdlet.ShouldProcess($desired.name, 'Rename the computer')) {
            try {
                # -WarningAction: Rename-Computer warns "The changes will take effect after you restart", and pwsh
                # writes warnings to stdout, ahead of the JSON, which DSC then can't parse (seen 2026-11-18 in the
                # test VM: "JSON: expected value at line 1 column 1"). set warns about the restart itself, below
                Rename-Computer -NewName $desired.name -Force -WarningAction SilentlyContinue
            } catch {
                $failure = $_
                throw (New-ResourceError -ExitCode 2 -Message (
                        "Renaming the computer to '$($desired.name)' failed: $($failure.Exception.Message)"))
            }
        }

        $state = Get-State
        # A name Windows would refuse can't be reached by a restart, so it asks for none
        $restart = if ($Operation -eq 'get') {
            $state.activeName -ine $state.pendingName
        } else {
            (Test-ComputerName -Name $desired.name) -and $state.activeName -ine $desired.name
        }
        if ($restart) {
            $state['_restartRequired'] = @(@{ system = $state.activeName })
        }
        if ($Operation -eq 'test') {
            $state['_inDesiredState'] = $state.activeName -ieq $desired.name
        }
        if ($Operation -eq 'set' -and $restart) {
            Write-ResourceMessage -Level warn -Text (
                ("The computer will be named '$($state.pendingName)' after the next restart; " +
                "it's still '$($state.activeName)'"))
        }
        ConvertTo-Json -InputObject $state -Compress -Depth 3
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
