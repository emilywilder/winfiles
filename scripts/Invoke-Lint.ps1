#Requires -Version 7.4

<#
.SYNOPSIS
Checks the PowerShell in the repo against the PoshCode style guide, with PSScriptAnalyzer, and exits 1 on a finding.

.DESCRIPTION
The rules are in PSScriptAnalyzerSettings.psd1 at the repo root, and the exceptions winfiles makes on purpose are in
docs/dev/style.md. Code outside the tests gets every rule. The tests (tests/ and surveys' *.Tests.ps1) get only the
layout rules (braces, indentation, whitespace, line length, aliases, casing), since helpers there keep positional
parameters and need no help or [CmdletBinding()]. PSScriptAnalyzer is a PowerShell module, which mise can't install,
so the pinned version is saved to ~/.cache/winfiles/modules on first use and imported from there, like Pester in
Invoke-Test.ps1. In PSScriptAnalyzer 1.25.0, PSUseCorrectCasing fails with a null reference in
CommandInfo.Parameters now and then when it runs alongside the other rules, which PSScriptAnalyzer runs in parallel
(a different file each run, seen 2026-11-21), and after that every file in the same process fails ("Get-Command is
not recognized"). So it runs in a call of its own, which didn't fail in three passes over the repo. Should a file
still fail, it and the rest are checked again in a new process, up to three times; a file that still fails counts
as a finding.

.EXAMPLE
./scripts/Invoke-Lint.ps1

Checks every PowerShell file the repo tracks.

.EXAMPLE
./scripts/Invoke-Lint.ps1 scripts/Invoke-Dsc.ps1

Checks one file.
#>
[CmdletBinding()]
param(
    # The files to check, relative to the repo root or absolute. By default, every .ps1 git tracks.
    [Parameter(Position = 0, ValueFromRemainingArguments)]
    [string[]]$Path = @()
)

$ErrorActionPreference = 'Stop'
try {
    # Bump by hand, after reading PSScriptAnalyzer's release notes
    $analyzerVersion = '1.25.0'
    $layoutRules = @(
        'PSPlaceOpenBrace', 'PSPlaceCloseBrace', 'PSUseConsistentIndentation', 'PSUseConsistentWhitespace'
        'PSAlignAssignmentStatement', 'PSAvoidTrailingWhitespace', 'PSAvoidSemicolonsAsLineTerminators'
        'PSAvoidLongLines', 'PSAvoidUsingCmdletAliases', 'PSUseCorrectCasing'
    )

    $repo = Split-Path -Path $PSScriptRoot
    $modules = Join-Path -Path $HOME -ChildPath '.cache/winfiles/modules'
    $manifest = Join-Path -Path $modules -ChildPath "PSScriptAnalyzer/$analyzerVersion/PSScriptAnalyzer.psd1"
    if (-not (Test-Path -Path $manifest)) {
        New-Item -ItemType Directory -Force -Path $modules | Out-Null
        $save = @{
            Name            = 'PSScriptAnalyzer'
            Version         = $analyzerVersion
            Repository      = 'PSGallery'
            TrustRepository = $true
            Path            = $modules
        }
        Save-PSResource @save
    }
    Import-Module -Name $manifest

    $settingsFile = Join-Path -Path $repo -ChildPath 'PSScriptAnalyzerSettings.psd1'
    $settings = Import-PowerShellDataFile -Path $settingsFile
    $casingRule = 'PSUseCorrectCasing'
    $all = $settings.Clone()
    $all.ExcludeRules = [string[]](@($settings.ExcludeRules) + $casingRule)
    $layout = @{
        IncludeRules = [string[]]@($layoutRules | Where-Object -FilterScript { $_ -ne $casingRule })
        Rules        = $settings.Rules
    }
    $casing = @{ IncludeRules = [string[]]@($casingRule); Rules = $settings.Rules }

    $files = @(if ($Path) { $Path } else { git -C $repo ls-files '*.ps1' })
    # Set for a process this script starts again after PSScriptAnalyzer failed, so the restarts stop at three
    $restarts = [int]$env:WINFILES_LINT_RESTARTS
    $findings = 0
    $index = 0
    $resumeFrom = -1
    while ($index -lt $files.Count -and $resumeFrom -lt 0) {
        $file = $files[$index]
        $full = if ([IO.Path]::IsPathRooted($file)) { $file } else { Join-Path -Path $repo -ChildPath $file }
        $isTest = $file -match '^tests[\\/]' -or $file -like '*.Tests.ps1'
        $rules = if ($isTest) { $layout } else { $all }
        try {
            $results = @(Invoke-ScriptAnalyzer -Path $full -Settings $rules -ErrorAction Stop) +
            @(Invoke-ScriptAnalyzer -Path $full -Settings $casing -ErrorAction Stop)
            foreach ($result in $results) {
                Write-Host -Object "${file}:$($result.Line):$($result.Column) $($result.RuleName): $($result.Message)"
                $findings++
            }
            $index++
        } catch {
            $failure = $_
            if ($restarts -lt 3) {
                $resumeFrom = $index
            } else {
                Write-Host -Object "${file}: PSScriptAnalyzer failed: $($failure.Exception.Message)" -ForegroundColor Red
                $findings++
                $index++
            }
        }
    }

    $code = if ($findings) { 1 } else { 0 }
    if ($resumeFrom -ge 0) {
        # A new process for the rest, which reports its own total
        $env:WINFILES_LINT_RESTARTS = $restarts + 1
        $rest = $files[$resumeFrom..($files.Count - 1)]
        & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -File $PSCommandPath @rest
        $code = [Math]::Max($code, $LASTEXITCODE)
        if ($findings) {
            Write-Host -Object "and $findings findings before PSScriptAnalyzer was restarted" -ForegroundColor Red
        }
    } elseif ($findings) {
        Write-Host -Object "$findings findings in $($files.Count) files" -ForegroundColor Red
    } else {
        Write-Host -Object "No findings in $($files.Count) files"
    }
    exit $code
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
