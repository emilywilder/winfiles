# What the real justfile's recipes would run, read with `just --dry-run`, which prints each line and runs none of
# them, so nothing here elevates or changes the machine. just is the real one, from mise.toml, as in
# Show-RecipeHelp.Tests.ps1.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')

    # The lines `just --dry-run <recipe> <arguments>` would run, in order (just prints them on stderr)
    function Get-RecipeLine([string]$Recipe, [string[]]$Arguments = @('iris', 'emily')) {
        $result = Invoke-Child $repo @{} { just --dry-run $Recipe @Arguments }
        $result.ExitCode | Should -Be 0
        @($result.Stderr | Where-Object { $_ })
    }
}

Describe 'install' {
    BeforeAll { $lines = Get-RecipeLine 'install' }

    It 'checks both configurations exist before anything asks for UAC, then logs that it started' {
        $lines[0] | Should -Match "Test-Path -LiteralPath 'dsc/iris\.system\.dsc\.yaml'"
        $lines[1] | Should -Match "Test-Path -LiteralPath 'dsc/emily@iris\.home\.dsc\.yaml'"
        $lines[2] | Should -Match "Write-WinfilesLog install 'started for host iris"
    }

    It 'runs every step under one elevation, with a single call to Invoke-AsAdmin.ps1' {
        $elevating = @($lines | Where-Object { $_ -match 'Invoke-AsAdmin\.ps1' })
        $elevating | Should -HaveCount 1
        $elevating[0] | Should -Match 'Invoke-AsAdmin\.ps1 just install-steps iris emily'
    }

    It 'says what the UAC prompt is for only when the shell is not elevated' {
        $says = @($lines | Where-Object { $_ -match 'Asking for UAC once' })
        $says | Should -HaveCount 1
        $says[0] | Should -Match 'if \(-not \(Test-Elevated\)\)'
    }

    It 'only logs that it finished after the elevated steps' {
        $lines[-1] | Should -Match "Write-WinfilesLog install 'finished for host iris"
        $lines[-2] | Should -Match 'Invoke-AsAdmin\.ps1 just install-steps'
    }
}

Describe 'install-steps' {
    BeforeAll { $lines = Get-RecipeLine 'install-steps' }

    It 'applies system and home as one aggregate, then checks, then prints the post-install notes' {
        $steps = @($lines | Where-Object { $_ -match 'Invoke-Clean\.ps1' })
        $steps | Should -HaveCount 3
        $documents = 'dsc/iris\.system\.dsc\.yaml dsc/emily@iris\.home\.dsc\.yaml'
        $steps[0] | Should -Match "Invoke-Configuration\.ps1 set $documents"
        $steps[1] | Should -Match "Invoke-Configuration\.ps1 test $documents"
        $steps[2] | Should -Match 'Show-PostInstall\.ps1'
    }

    It ('leaves the privilege of each batch to Invoke-Configuration.ps1, ' +
        'so the recipes name no helper but the check''s elevation') {
        $steps = @($lines | Where-Object { $_ -match 'Invoke-Clean\.ps1' })
        $steps[0] | Should -Not -Match 'Invoke-As'
        $steps[1] | Should -Match 'Invoke-AsAdmin\.ps1 pwsh .*Invoke-Configuration\.ps1 test'
    }
}

Describe 'the recipes that apply or test a configuration' {
    It 'never call gsudo themselves, so <Recipe> works from an elevated or an unelevated shell' -ForEach @(
        @{ Recipe = 'install'; Arguments = 'iris', 'emily' }
        @{ Recipe = 'install-steps'; Arguments = 'iris', 'emily' }
        @{ Recipe = 'system'; Arguments = 'iris' }
        @{ Recipe = 'home'; Arguments = 'emily', 'iris' }
        @{ Recipe = 'check'; Arguments = 'iris', 'emily' }
    ) {
        Get-RecipeLine $Recipe $Arguments | Where-Object { $_ -match 'gsudo' } | Should -BeNullOrEmpty
    }
}

# install-elevated runs install-steps in a second just, through Invoke-AsAdmin.ps1, and Invoke-Install.ps1 resumes
# after a restart only when the code a step stopped with (3010, or 194 once mise exec has cut it to its low byte)
# arrives unchanged. A justfile of the same shape, with the real helper and no elevation, shows what comes out
Describe 'an exit code from the steps of an install' {
    It 'comes out of the outer just as it went in (<code>)' -ForEach @(
        @{ code = 3010 }, @{ code = 194 }, @{ code = 1 }, @{ code = 0 }
    ) {
        $folder = New-Item -ItemType Directory (Join-Path $TestDrive "nested-$([guid]::NewGuid())")
        $helper = Join-Path $repo 'scripts\Invoke-AsAdmin.ps1'
        Set-Content (Join-Path $folder 'justfile') @"
set windows-shell := ["pwsh.exe", "-NoLogo", "-NoProfile", "-Command"]

[no-exit-message]
outer:
    & '$helper' just inner; exit `$LASTEXITCODE

[no-exit-message]
inner:
    exit $code
"@
        $environment = @{ WINFILES_ELEVATED = 'true'; USERPROFILE = $folder.FullName }
        $result = Invoke-Child $folder $environment { just outer }
        $result.ExitCode | Should -Be $code
    }
}
