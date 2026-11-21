# Shared by the Winfiles/* resource scripts, which dot-source it in their begin block.


function Read-ResourceInput {
    <#
    .SYNOPSIS
    Reads the instance DSC piped to the resource on stdin, from the lines the resource's pipeline parameter collected.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # The lines of JSON, as the manifest's `$input | ./<script>.ps1` passes them on, one at a time.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Line
    )

    ConvertFrom-Json -InputObject ($Line -join "`n")
}


function Write-ResourceMessage {
    <#
    .SYNOPSIS
    Writes a message DSC shows: a JSON line on stderr, named by its level.

    .DESCRIPTION
    DSC logs plain stderr lines at trace only, and on a non-zero exit shows only the exit code and the manifest's
    description for it (checked 2026-11-21, DSC 3.3.0), so anything meant to be seen needs this form. warn is the
    lowest level DSC shows by default (demos/dsc-messages/README.md). Each line is flushed as it's written.
    #>
    [CmdletBinding()]
    param(
        # The level DSC files the message under.
        [Parameter(Mandatory)]
        [ValidateSet('error', 'warn', 'info', 'debug', 'trace')]
        [string]$Level,

        # The message.
        [Parameter(Mandatory)]
        [string]$Text
    )

    [Console]::Error.WriteLine((ConvertTo-Json -InputObject @{ $Level = $Text } -Compress))
    [Console]::Error.Flush()
}


function New-ResourceError {
    <#
    .SYNOPSIS
    Makes the error a resource throws when an operation fails, carrying the exit code its manifest documents.

    .EXAMPLE
    throw (New-ResourceError -Message 'Scoop is not installed' -ExitCode 3)

    Ends the resource, through its trap, with the message shown by DSC and exit code 3.
    #>
    [CmdletBinding()]
    [OutputType([Management.Automation.ErrorRecord])]
    param(
        # What went wrong, for the person running DSC.
        [Parameter(Mandatory)]
        [string]$Message,

        # The exit code: one of the manifest's exitCodes, or a tool's own code passed through. 0 and 1 are taken, by
        # success and by an unexpected error.
        [Parameter(Mandatory)]
        [ValidateScript({ $_ -notin 0, 1 })]
        [int]$ExitCode
    )

    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['ExitCode'] = $ExitCode
    [Management.Automation.ErrorRecord]::new($exception, "Winfiles.Resource.$ExitCode", 'InvalidOperation', $null)
}


function Exit-ResourceError {
    <#
    .SYNOPSIS
    Reports an error to DSC and ends the resource with its exit code: the one New-ResourceError gave it, otherwise 1.

    .DESCRIPTION
    Each resource script calls this from its own trap, because a trap only covers the scope that declares it, even
    when dot-sourced.
    #>
    [CmdletBinding()]
    param(
        # The error the trap caught.
        [Parameter(Mandatory)]
        [Management.Automation.ErrorRecord]$ErrorRecord
    )

    Write-ResourceMessage -Level error -Text $ErrorRecord.Exception.Message
    $exitCode = $ErrorRecord.Exception.Data['ExitCode']
    exit ($exitCode ?? 1)
}
