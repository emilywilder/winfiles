# Show-RecipeHelp.ps1 reads the justfile beside its own folder, so each test runs a copy of it in a checkout in
# TestDrive:, with a justfile and scripts made for the test. just is the real one, from mise.toml.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')

    # A checkout holding -Justfile and, in scripts/, -Scripts (name → content) beside a copy of Show-RecipeHelp.ps1
    function New-Checkout([string]$Justfile, [hashtable]$Scripts = @{}) {
        $checkout = New-Item -ItemType Directory (Join-Path $TestDrive "checkout-$([guid]::NewGuid())")
        $folder = New-Item -ItemType Directory (Join-Path $checkout 'scripts')
        Copy-Item (Join-Path $repo 'scripts\Show-RecipeHelp.ps1') $folder
        Set-Content (Join-Path $checkout 'justfile') $Justfile
        foreach ($name in $Scripts.Keys) { Set-Content (Join-Path $folder $name) $Scripts[$name] }
        $checkout.FullName
    }

    function Show-RecipeHelp([string]$Checkout, [string]$Recipe) {
        Invoke-Child $Checkout @{} {
            pwsh -NoLogo -NoProfile -NonInteractive -File "$Checkout\scripts\Show-RecipeHelp.ps1" $Recipe
        }
    }

    # A script with help, a mandatory positional parameter, an optional one and a switch
    $tool = @'
#Requires -Version 7.4

<#
.SYNOPSIS
Does a thing for the tests.

.EXAMPLE
./scripts/Tool.ps1 -Name x
#>
param(
    [Parameter(Mandatory)]
    [string] $Name,
    [int] $Count,
    [switch] $Force
)
'@

    $other = @'
#Requires -Version 7.4

<#
.SYNOPSIS
Does another thing.
#>
param([string] $Path)
'@

    $justfile = @'
set windows-shell := ["pwsh.exe", "-NoLogo", "-NoProfile", "-Command"]
prefix := "pwsh"

plain:
    & ./scripts/Tool.ps1 -Name x

tool name *args:
    & ./scripts/Tool.ps1 -Name '{{name}}' {{args}}

both *args:
    & ./scripts/Tool.ps1 {{args}}
    & ./scripts/Other.ps1 {{args}}
    & ./scripts/Tool.ps1 {{args}}

interpolated *args:
    {{prefix}} -File ./scripts/Other.ps1 {{args}}
'@

    $checkout = New-Checkout $justfile @{ 'Tool.ps1' = $tool; 'Other.ps1' = $other }
}

Describe 'Show-RecipeHelp.ps1' {
    It 'prints nothing for a recipe without *args' {
        $result = Show-RecipeHelp $checkout plain
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -BeNullOrEmpty
    }

    # just --usage, which `just help` runs first, has already said the recipe doesn't exist
    It 'prints nothing for a recipe that does not exist' {
        $result = Show-RecipeHelp $checkout missing
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -BeNullOrEmpty
    }

    It "shows the help of the script a recipe's *args go to" {
        $result = Show-RecipeHelp $checkout tool
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Contain '    Does a thing for the tests.'
    }

    It 'names the script by file name, without its folder' {
        $text = (Show-RecipeHelp $checkout tool).Stdout -join "`n"
        $text | Should -BeLike "*NAME`n    Tool.ps1`n*"
        $text | Should -Not -BeLike "*$checkout*"
    }

    It 'gives the Get-Help commands under REMARKS a ./scripts/ path' {
        (Show-RecipeHelp $checkout tool).Stdout -join "`n" |
            Should -BeLike '*type: "Get-Help ./scripts/Tool.ps1 -Examples"*'
    }

    It "shows SYNTAX one parameter per line, in Get-Help's notation" {
        $lines = (Show-RecipeHelp $checkout tool).Stdout
        $start = [array]::IndexOf($lines, 'SYNTAX')
        $lines[($start + 1)..($start + 5)] | Should -Be @(
            '    Tool.ps1'
            '        [-Name] <String>'
            '        [[-Count] <Int32>]'
            '        [-Force]'
            '        [<CommonParameters>]'
        )
        # The section's blank lines stay, and nothing else comes before the next heading
        $next = $start + 6
        while ($lines[$next] -notmatch '^[A-Z][A-Z ]*$') { $next++ }
        $next | Should -BeGreaterThan ($start + 6)
        $lines[($start + 6)..($next - 1)] | Should -Not -Match '\S'
    }

    It 'shows each script a recipe runs once, in order' {
        $lines = (Show-RecipeHelp $checkout both).Stdout
        $names = for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -eq 'NAME') { $lines[$i + 1] } }
        $names | Should -Be @('    Tool.ps1', '    Other.ps1')
    }

    It 'finds a script in a line that also has interpolations' {
        (Show-RecipeHelp $checkout interpolated).Stdout | Should -Contain '    Does another thing.'
    }
}

# The recipe itself, against the real justfile: read-only, since `help` only prints
Describe 'just help' {
    It "shows a recipe's usage, then the help of its scripts" {
        $result = Invoke-Child $repo @{} { just help test-vm-copy }
        $result.ExitCode | Should -Be 0
        $result.Stdout[0] | Should -BeLike 'Usage: just test-vm-copy*'
        $result.Stdout | Should -Contain '    Copy-RepoToTestVm.ps1'
    }

    It 'shows only the usage of a recipe without *args' {
        $result = Invoke-Child $repo @{} { just help hosts }
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Not -Contain 'SYNOPSIS'
    }

    It "fails for a recipe that doesn't exist, with just's own message" {
        $result = Invoke-Child $repo @{} { just help no-such-recipe }
        $result.ExitCode | Should -Not -Be 0
        $result.Stderr -join "`n" | Should -BeLike "*no-such-recipe*"
    }
}
