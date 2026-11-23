#Requires -Version 7.4

<#
.SYNOPSIS
Runs `dsc config set` on one of the dummy documents in demos/dsc-messages, to watch how DSC shows its messages.

.DESCRIPTION
The first argument names the document, without .dsc.yaml (machine-info, say); the rest go to dsc before
`config set` (-l info, say). Discovery is limited to dsc's own folder and this one, so Test/SlowList never reaches
the real configuration, and the Winfiles/* resources aren't found. See README.md.
There's no param() block, for the reason Invoke-Dsc.ps1 gives: dsc's own dash arguments pass on as they are.

.EXAMPLE
mise exec -- pwsh -NoProfile -File dsc-messages/Invoke-DscMessage.ps1 machine-info -l info

From demos/: applies machine-info.dsc.yaml at the info level.
#>

$ErrorActionPreference = 'Stop'
try {
    if (-not $args) {
        [Console]::Error.WriteLine('Name a document in demos/dsc-messages, such as machine-warn.')
        exit 2
    }
    $document = Join-Path -Path $PSScriptRoot -ChildPath "$($args[0]).dsc.yaml"
    $dscArguments = @($args | Select-Object -Skip 1)
    $dsc = Get-Command -Name dsc -CommandType Application | Select-Object -First 1
    $env:DSC_RESOURCE_PATH = (Split-Path -Path $dsc.Source) + ";$PSScriptRoot"
    & $dsc.Source @dscArguments config set --file $document
    exit $LASTEXITCODE
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
