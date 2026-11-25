#Requires -Version 7.4

<#
.SYNOPSIS
Prints what a host and its user still need done by hand after an install.

.DESCRIPTION
A note is a YAML comment in a host's entries, the documents they include, or dsc/hosts/<host>/manual.yaml, that
starts with `# post-install: ` and runs to the end of that block of comment lines, so the text lives once, beside
the setting it's about. Each path given is read in turn: the YAML files in a folder and its subfolders, or a file
and every document it includes, at any depth, with each configurationFile resolved from that file's folder as DSC
does. A document reached twice is read once. One that doesn't exist is skipped. No notes prints nothing.

.EXAMPLE
./scripts/Show-PostInstall.ps1 dsc/hosts/iris/manual.yaml dsc/iris.system.dsc.yaml dsc/emily@iris.home.dsc.yaml

Prints what iris and emily@iris still need done by hand.
#>
[CmdletBinding()]
param(
    # The folders, or YAML files, to read notes from.
    [Parameter(Mandatory, ValueFromRemainingArguments)]
    [string[]]$Path
)


function Get-IncludedFile {
    <#
    .SYNOPSIS
    Returns a YAML file, then every document it includes, depth first, each resolved from the root folder.

    .DESCRIPTION
    The file is read with yq, so an Include is found however its YAML is written. A file yq can't read fails.
    #>
    [CmdletBinding()]
    [OutputType([IO.FileInfo])]
    param(
        # The file to read.
        [Parameter(Mandatory)]
        [IO.FileInfo]$File,

        # The folder its configurationFile paths resolve from: the first file's own, as DSC does for nested ones.
        [Parameter(Mandatory)]
        [string]$Root
    )

    $File
    $document = Invoke-Yq -Arguments '-o', 'json', '.', $File.FullName | ConvertFrom-Json
    # manual.yaml is a list, so it has no resources and includes nothing
    foreach ($resource in $document.resources) {
        if ($resource.type -ne 'Microsoft.DSC/Include') {
            continue
        }
        $included = Join-Path -Path $Root -ChildPath $resource.properties.configurationFile
        if (Test-Path -LiteralPath $included -PathType Leaf) {
            Get-IncludedFile -File (Get-Item -LiteralPath $included) -Root $Root
        }
    }
}


$ErrorActionPreference = 'Stop'
try {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'yq.ps1')
    $pattern = '(?m)^[ \t]*# post-install: (.*(?:\r?\n[ \t]*#.*)*)'
    $files = foreach ($item in $Path) {
        if (Test-Path -LiteralPath $item -PathType Container) {
            Get-ChildItem -LiteralPath $item -Filter *.yaml -Recurse
        } elseif (Test-Path -LiteralPath $item -PathType Leaf) {
            $file = Get-Item -LiteralPath $item
            Get-IncludedFile -File $file -Root $file.DirectoryName
        }
    }
    $read = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $notes = foreach ($file in $files) {
        if (-not $read.Add($file.FullName)) {
            continue
        }
        foreach ($match in [regex]::Matches((Get-Content -LiteralPath $file.FullName -Raw), $pattern)) {
            $match.Groups[1].Value -replace '\r' -replace '(?m)^[ \t]*# ?'
        }
    }
    if ($notes) {
        Write-Host -Object "`nStill to do by hand:"
        foreach ($note in $notes) {
            Write-Host -Object "`n$note"
        }
    }
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
