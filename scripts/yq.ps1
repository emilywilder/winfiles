# Shared by the scripts that read or write YAML with yq, which dot-source it (ConvertTo-FlatConfiguration.ps1).
# Invoke-Yq is the one place that settles how yq's text crosses into PowerShell.


function Invoke-Yq {
    <#
    .SYNOPSIS
    Runs yq, on -InputText when it's given, and returns its output as one string; throws when yq fails.

    .DESCRIPTION
    yq writes UTF-8, and PowerShell decodes a native command's output with the console's code page, which is not
    UTF-8 in every terminal (437 in a default conhost): accented letters and dashes came back mangled, and a
    document written from them was wrong. The console's output encoding is set to UTF-8 for the call only, and
    left alone where there's no console to set.

    .EXAMPLE
    Invoke-Yq -Arguments '-o', 'json', '.', dsc/iris.system.dsc.yaml | ConvertFrom-Json
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # yq's arguments.
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        # Text for yq's stdin.
        [string]$InputText
    )

    $previous = [Console]::OutputEncoding
    $changed = $false
    try {
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        $changed = $true
    } catch {
        $failure = $_
        Write-Verbose -Message "The console's output encoding wasn't changed: $($failure.Exception.Message)"
    }
    try {
        $output = if ($PSBoundParameters.ContainsKey('InputText')) {
            $InputText | & yq @Arguments
        } else {
            & yq @Arguments
        }
    } finally {
        if ($changed) {
            [Console]::OutputEncoding = $previous
        }
    }
    if ($LASTEXITCODE) {
        throw "yq $Arguments failed with exit code $LASTEXITCODE"
    }
    $output -join "`n"
}
