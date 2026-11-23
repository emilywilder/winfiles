# Invoke-Lint.ps1 with the real PSScriptAnalyzer (the pinned version, saved to ~/.cache/winfiles/modules on first
# use), on small scripts written to TestDrive:, and on the repo itself, which has to stay clean.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')

    # A script in TestDrive: with -Text, named -Name (a .Tests.ps1 name gets only the layout rules)
    function New-LintScript([string]$Text, [string]$Name = 'Sample.ps1') {
        $folder = New-Item -ItemType Directory (Join-Path $TestDrive "lint-$([guid]::NewGuid())")
        $file = Join-Path $folder $Name
        Set-Content -LiteralPath $file -Value $Text
        $file
    }

    $clean = @'
#Requires -Version 7.4

<#
.SYNOPSIS
Says hello, for the tests.

.EXAMPLE
./Sample.ps1

Says hello.
#>
[CmdletBinding()]
param()

Write-Output -InputObject 'hello'
'@
}

Describe 'Invoke-Lint.ps1' {
    It 'passes a script that keeps to the rules' {
        $result = Invoke-Script Invoke-Lint.ps1 (New-LintScript $clean)
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Contain 'No findings in 1 files'
    }

    It 'names the file, the line and the rule of a finding, and exits 1' {
        $braceOnNewLine = "if (`$true)`n{`n    'hello'`n}"
        $file = New-LintScript ($clean -replace "Write-Output -InputObject 'hello'", $braceOnNewLine)
        $result = Invoke-Script Invoke-Lint.ps1 $file
        $result.ExitCode | Should -Be 1
        ($result.Stdout -join "`n") | Should -BeLike "*${file}:16:*PSPlaceOpenBrace*"
    }

    It 'gives a test file only the layout rules' {
        # A function with no help, which only the full rules ask for
        $text = "function Get-Thing {`n    'thing'`n}"
        (Invoke-Script Invoke-Lint.ps1 (New-LintScript $text 'Sample.Tests.ps1')).ExitCode | Should -Be 0
        (Invoke-Script Invoke-Lint.ps1 (New-LintScript $text 'Sample.ps1')).ExitCode | Should -Be 1
    }

    It 'checks line length at 115' {
        $long = $clean -replace "'hello'", "'$('x' * 100)'"
        ($long -split "`n" | Where-Object { $_.Length -gt 115 }) | Should -Not -BeNullOrEmpty
        $output = (Invoke-Script Invoke-Lint.ps1 (New-LintScript $long)).Stdout -join "`n"
        $output | Should -BeLike '*PSAvoidLongLines*'
    }

    # The repo itself, as `winfiles.ps1 lint` checks it
    It 'finds nothing in the repo' {
        $result = Invoke-Script Invoke-Lint.ps1
        $result.ExitCode | Should -Be 0 -Because ($result.Stdout -join "`n")
    }
}
