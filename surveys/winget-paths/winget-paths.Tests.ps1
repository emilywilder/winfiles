# A survey (surveys/README.md, winget-paths/README.md): how each way of driving winget installs the same packages. It
# installs and uninstalls real packages, so BeforeAll refuses any machine that isn't a Hyper-V guest, and `just test`
# never runs it (it only looks in tests/). Start it unelevated, from the VM's desktop, through a recipe, which sets
# WINFILES_WINGET_PATHS_CONTEXT to the context the installs run in:
#   mise exec -- just -f surveys/justfile winget-paths                       # unelevated, then elevated
#   mise exec -- just -f surveys/justfile winget-paths-context elevated      # one context
# For each path in turn it clears the survey's packages (Clear-WinGetPaths.ps1, unelevated, with a UAC prompt for its
# elevated pass), then runs Install-WinGetPathCase.ps1 for that path: directly, or through UAC for the elevated context.
# Each It checks one package's result. It's attended: answer the UAC prompts. Every result is also kept in
# ~/.local/state/winfiles/winget-paths/<time>-<context>.json, to copy out of the VM.
#   cli       winget install, as bootstrap.cmd uses it
#   cli-user  the same with --scope user, the install a stop-gap _scope would make
#   dsc       Microsoft.WinGet/Package through DSC (winget dscv3 package --set)
#   com       Install-WinGetPackage from Microsoft.WinGet.Client, as Winfiles/WinGetPackageList uses it. Whether it
#             ran in-process (WindowsPackageManager.dll loaded) or through WindowsPackageManagerServer is recorded

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'WinGetPaths.ps1')
    $paths = foreach ($path in 'cli', 'cli-user', 'dsc', 'com') {
        @{ Path = $path; Packages = @(Get-WinGetPathPackage | Where-Object { $path -ne 'cli-user' -or $_.HasUser }) }
    }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'WinGetPaths.ps1')
    Assert-TestVm
    # Elevated, winget won't uninstall per-user packages (0x8A15007D, 2026-11-17), so the clears need an unelevated
    # parent; the elevated context only elevates the installs
    if (Test-Elevated) { throw 'Start the survey unelevated: the elevated context runs its installs through UAC itself' }
    $script:context = $env:WINFILES_WINGET_PATHS_CONTEXT
    if ($context -notin 'unelevated', 'elevated') {
        throw "WINFILES_WINGET_PATHS_CONTEXT is '$context', not unelevated or elevated: run it through surveys/justfile"
    }
    $script:elevated = $context -eq 'elevated'
    $dsc = Get-Command dsc -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    if (-not $dsc) { throw 'dsc is not on PATH: run under mise exec' }
    $script:dscDirectory = Split-Path $dsc.Source
    $script:pwsh = (Get-Process -Id $PID).Path
    $script:results = [Collections.Generic.List[object]]::new()

    # Throws unless none of the survey's packages is left
    function Clear-Survey {
        & $pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'Clear-WinGetPaths.ps1') | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'Clear-WinGetPaths.ps1 left packages installed (see above), so this path would not start clean' }
    }

    # Runs one path's installs in the survey's context, and returns their results by id
    function Invoke-PathCase([string]$Path) {
        $file = Join-Path $TestDrive "$Path.json"
        $script = Join-Path $PSScriptRoot 'Install-WinGetPathCase.ps1'
        if ($elevated) {
            try {
                Start-Process $pwsh -Verb RunAs -Wait -ArgumentList '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
                    "`"$script`"", '-Path', $Path, '-ResultFile', "`"$file`"", '-DscDirectory', "`"$dscDirectory`""
            } catch {
                throw "The elevated install process for $Path didn't start: $($_.Exception.Message)"
            }
        } else {
            & $pwsh -NoLogo -NoProfile -NonInteractive -File $script -Path $Path -ResultFile $file | Out-Host
        }
        if (-not (Test-Path $file)) { throw "The install process for $Path recorded no results" }
        $byId = @{}
        foreach ($result in Get-Content $file -Raw | ConvertFrom-Json) {
            $results.Add($result)
            $byId[$result.id] = $result
        }
        $byId
    }
}

AfterAll {
    if ($results) {
        $folder = New-Item -ItemType Directory -Force (Join-Path $HOME '.local\state\winfiles\winget-paths')
        $file = Join-Path $folder ('{0:yyyyMMdd-HHmmss}-{1}.json' -f (Get-Date), $context)
        ConvertTo-Json -InputObject $results.ToArray() -Depth 4 | Set-Content $file
        Write-Host "winget path results: $file"
    }
    # Leave the VM clean for the next run
    if ($pwsh) { Clear-Survey }
}

Describe '<Path>' -ForEach $paths {
    BeforeAll {
        Clear-Survey
        $script:run = Invoke-PathCase $Path
    }

    It 'installs <Id> (<Case>)' -ForEach $Packages {
        $result = $run[$Id]
        $result | Should -Not -BeNullOrEmpty -Because 'the install process recorded nothing for it'
        $result.timedOut | Should -BeFalse -Because 'an install that waits 15 minutes is stuck, probably on a prompt'
        if ($Bogus) {
            $result.exitCode | Should -Not -Be 0 -Because 'an id with no match is a failure'
        } elseif ($Picks -eq 'machine' -and $Path -ne 'cli-user' -and -not $elevated) {
            # Every path raised UAC here (2026-11-17). Dismissed, the installer exits 1602 (0x8A15010C); approved, it installs
            $result.uac | Should -BeTrue -Because 'winget picks a machine-wide installer, which needs elevation'
            if ($result.exitCode -eq 0) { $result.scope | Should -Be 'machine' }
        } elseif ($Path -eq 'com' -and $Also) {
            # Known fault: Install-WinGetPackage fails to install UI.Xaml 2.6 as a dependency, in either context, where
            # the CLI and winget dscv3 manage it (0x8A150110; 2026-11-03, and both contexts 2026-11-17, winget 1.29.380).
            # Revisit the UI.Xaml ordering in docs/architecture.md if this starts passing
            $result.exitCode | Should -Not -Be 0
            $result.output -join "`n" | Should -Match '0x8A150110'
        } else {
            $result.exitCode | Should -Be 0 -Because (($result.output | Select-Object -Last 5) -join ' / ')
            $result.scope | Should -Not -BeNullOrEmpty -Because 'winget should list what it installed'
            $expected = if ($Path -eq 'cli-user') { 'user' } else { $Picks }
            $result.scope | Should -Be $expected -Because 'that is the scope winget picked on 2026-11-17'
            if ($Also) { $result.alsoScope | Should -Not -BeNullOrEmpty -Because "$Also is a dependency of $Id" }
        }
    }
}
