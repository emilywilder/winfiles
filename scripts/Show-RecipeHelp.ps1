#Requires -Version 7.4

<#
.SYNOPSIS
Shows Get-Help for the scripts a just recipe passes its *args to, for `just help`.

.DESCRIPTION
A recipe with *args passes them on to a script, so that script's parameters are part of the recipe's
usage. The scripts come from the recipe's body in just's JSON dump, where *args is a parameter of kind
"star". A recipe without *args shows nothing.
Get-Help names a script by its full path. That's cut to the file name, except in the Get-Help commands
under REMARKS, which get ./scripts/ so they run from the repo root. SYNTAX is rebuilt from the help's
syntax data with one parameter per line, in Get-Help's notation, since Get-Help has no option for it.

.EXAMPLE
./scripts/Show-RecipeHelp.ps1 test-vm
#>
param(
    [Parameter(Mandatory)]
    [string] $Recipe
)

$root = Split-Path $PSScriptRoot
$dump = just --justfile (Join-Path $root justfile) --dump --dump-format json | ConvertFrom-Json
$r = $dump.recipes.$Recipe
if (-not $r -or $r.parameters.kind -notcontains 'star') { exit 0 }

# Each body line is a list of text fragments and interpolations; only the text names scripts
$scripts = $r.body | ForEach-Object { $_ } | Where-Object { $_ -is [string] } |
    Select-String -AllMatches 'scripts/[\w-]+\.ps1' | ForEach-Object { $_.Matches.Value } | Select-Object -Unique

$folder = [regex]::Escape($PSScriptRoot + '\')

# A parameter as Get-Help writes it: brackets around an optional parameter, and around the name of a positional one
function Format-SyntaxParameter($parameter) {
    $name = "-$($parameter.name)"
    if ($parameter.position -ne 'named') { $name = "[$name]" }
    if ($parameter.parameterValue) { $name += " <$($parameter.parameterValue)>" }
    if ($parameter.required -eq 'true') { $name } else { "[$name]" }
}

foreach ($script in $scripts) {
    $help = Get-Help (Join-Path $root $script)
    $lines = ($help | Out-String) -replace "Get-Help $folder", 'Get-Help ./scripts/' -replace $folder, '' -split '\r?\n'

    # SYNTAX runs from its heading to the next one; its blank lines stay, its syntax lines are replaced
    $start = [array]::IndexOf($lines, 'SYNTAX')
    if ($start -ge 0) {
        $end = $start + 1
        while ($end -lt $lines.Count -and $lines[$end] -notmatch '^[A-Z][A-Z ]*$') { $end++ }
        $section = $lines[($start + 1)..($end - 1)]
        $common = $section -match '\[<CommonParameters>\]'
        $syntax = foreach ($item in $help.syntax.syntaxItem) {
            '    ' + (Split-Path $item.name -Leaf)
            foreach ($parameter in $item.parameter) { '        ' + (Format-SyntaxParameter $parameter) }
            if ($common) { '        [<CommonParameters>]' }
        }
        $blank = @($section | Where-Object { $_ -notmatch '\S' })
        $lines = @($lines[0..$start]) + @($syntax) + $blank + @($lines[$end..($lines.Count - 1)])
    }

    $lines
}
