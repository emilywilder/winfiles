# Set-System.ps1 runs in this process, so its restarts can be mocked: a test must never reach the real Restart-Computer.
# dsc is the fake in tests/fakes, answering per document and operation. What Windows says about a pending restart is a
# hashtable (not $fake: that is the name of the helpers' parameter, which would shadow it): the servicing key is read once before anything is applied and once at the gate, so Servicing is a list of
# answers, the last of which repeats; and the two names of the computer, as in restart.Tests.ps1.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
    $script:file = Join-Path $repo 'scripts\Set-System.ps1'
    # Mutated, never replaced, so the mocks see the same table the tests change
    $machine = @{ Servicing = @($false); Calls = 0; Active = 'IRIS'; Pending = 'IRIS'; Warnings = @() }

    function Invoke-SetSystem([switch]$NoFlatten) {
        $saved = @{ PATH = $env:PATH; USERPROFILE = $env:USERPROFILE; WINFILES_FAKE_DSC = $env:WINFILES_FAKE_DSC }
        foreach ($name in $dsc.Environment.Keys) { Set-Item "env:$name" $dsc.Environment[$name] }
        try {
            $output = & $file iris -NoFlatten:$NoFlatten *>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output; Log = @(Get-Content (Join-Path $dsc.Home '.local\state\winfiles\run.log') -ErrorAction Ignore) }
        } finally {
            foreach ($name in $saved.Keys) { Set-Item "env:$name" $saved[$name] }
        }
    }

    # What dsc was asked to do, as "<operation> <document>". dsc is given the flat copy of each document (Get-RunDocument in
    # dsclog.ps1), which has the document's name, so that is reported as "flat/<name>"
    function Get-Calls {
        @(Get-FakeDscCalls $dsc | ForEach-Object {
            $file = $_.args[5]
            $document = if ($file -like '*\winfiles\flat\*') { 'flat/' + (Split-Path $file -Leaf) } else { $file }
            "$($_.args[1]) $document"
        })
    }

    # The restart document as `test` finds it: features and WSL differing and asking for a restart, the name already right
    function Set-RestartDocument([switch]$InDesiredState) {
        $resources = if ($InDesiredState) {
            @(New-DscResult Microsoft.Windows/OptionalFeatureList Features
                New-DscResult Winfiles/Wsl WSL
                New-DscResult Winfiles/ComputerName 'Computer Name')
        } else {
            @(New-DscResult Microsoft.Windows/OptionalFeatureList Features -Differs
                New-DscResult Winfiles/Wsl WSL -Differs -RestartSystem IRIS
                New-DscResult Winfiles/ComputerName 'Computer Name')
        }
        # Inside Includes, the way the real document has them
        Set-FakeDscResult $dsc iris.restart.dsc.yaml @(New-DscInclude Features $resources[0]; New-DscInclude WSL $resources[1]; New-DscInclude 'Computer Name' $resources[2]) -Operation test
    }
}

Describe 'Set-System.ps1' {
    BeforeEach {
        $script:dsc = New-FakeDsc
        $machine.Servicing = @($false); $machine.Calls = 0; $machine.Active = 'IRIS'; $machine.Pending = 'IRIS'; $machine.Warnings = @()
        Set-RestartDocument
        Set-FakeDscResult $dsc iris.restart.dsc.yaml @(New-DscResult Winfiles/Wsl WSL) -Operation set
        Set-FakeDscResult $dsc iris.system.dsc.yaml @(New-DscResult Test/Thing one)
        Mock Test-Path {
            $answers = @($machine.Servicing)
            $answer = $answers[[Math]::Min($machine.Calls, $answers.Count - 1)]
            $machine.Calls++
            $answer
        } -ParameterFilter { $Path -like '*RebootPending' }
        # Every other path is the real file system's, such as the fake dsc's record of its calls. The flattener asks with
        # -LiteralPath, which leaves $Path empty, so the path is whichever of the two was given
        Mock Test-Path {
            $target = if ($LiteralPath) { $LiteralPath } else { $Path }
            [IO.File]::Exists($target) -or [IO.Directory]::Exists($target)
        } -ParameterFilter { ($LiteralPath ?? $Path) -notlike '*RebootPending' }
        Mock Get-ItemProperty {
            $key = if ($Path -like '*\ActiveComputerName') { 'Active' } else { 'Pending' }
            [pscustomobject]@{ ComputerName = $machine[$key] }
        }
        Mock Write-Warning { $machine.Warnings += $Message }
        Mock Start-Sleep {}
        Mock Restart-Computer {}
    }

    It 'applies only the system document when nothing needs a restart or a change' {
        Set-RestartDocument -InDesiredState
        $result = Invoke-SetSystem
        $result.ExitCode | Should -Be 0
        Get-Calls | Should -Be 'test flat/iris.restart.dsc.yaml', 'set flat/iris.system.dsc.yaml'
        Should -Invoke Restart-Computer -Times 0 -Exactly
    }

    It 'tests and applies the documents themselves with -NoFlatten' {
        $result = Invoke-SetSystem -NoFlatten
        $result.ExitCode | Should -Be 0
        Get-Calls | Should -Be 'test dsc/iris.restart.dsc.yaml', 'set dsc/iris.restart.dsc.yaml', 'set dsc/iris.system.dsc.yaml'
    }

    It 'says before applying anything which resource will need a restart, even inside an Include' {
        $result = Invoke-SetSystem
        $result.Output | Should -BeLike "*a restart will be needed by: Winfiles/Wsl 'WSL'*"
        ($result.Log -join "`n") | Should -BeLike "*a restart will be needed by: Winfiles/Wsl 'WSL'*"
    }

    It 'applies what differs, then restarts once and stops with 3010 before the system document, when the run made a restart pending' {
        $machine.Servicing = @($false, $true)
        $result = Invoke-SetSystem
        $result.ExitCode | Should -Be 3010
        Get-Calls | Should -Be 'test flat/iris.restart.dsc.yaml', 'set flat/iris.restart.dsc.yaml'
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 30 }
        Should -Invoke Restart-Computer -Times 1 -Exactly
        $machine.Warnings | Should -BeLike "Applied Microsoft.Windows/OptionalFeatureList 'Features', Winfiles/Wsl 'WSL'. *Restarting in 30 seconds*"
    }

    It 'only asks for the restart when one was already pending before anything was applied' {
        $machine.Servicing = @($true)
        $result = Invoke-SetSystem
        $result.ExitCode | Should -Be 3010
        Should -Invoke Restart-Computer -Times 0 -Exactly
        $machine.Warnings | Should -BeLike '*Windows has a restart pending. Restart.*'
        Get-Calls | Should -Not -Contain 'set flat/iris.system.dsc.yaml'
    }

    It 'stops for a pending restart even when nothing differs, without restarting' {
        Set-RestartDocument -InDesiredState
        $machine.Servicing = @($true)
        (Invoke-SetSystem).ExitCode | Should -Be 3010
        Should -Invoke Restart-Computer -Times 0 -Exactly
        Get-Calls | Should -Be 'test flat/iris.restart.dsc.yaml'
    }

    It 'goes on to the system document when what differed left no restart pending' {
        $result = Invoke-SetSystem
        $result.ExitCode | Should -Be 0
        Get-Calls | Should -Be 'test flat/iris.restart.dsc.yaml', 'set flat/iris.restart.dsc.yaml', 'set flat/iris.system.dsc.yaml'
        Should -Invoke Restart-Computer -Times 0 -Exactly
    }

    It 'restarts after the system document for a rename that nothing before it restarted for' {
        Set-RestartDocument -InDesiredState
        $machine.Pending = 'NEWNAME'
        $result = Invoke-SetSystem
        $result.ExitCode | Should -Be 3010
        Get-Calls | Should -Be 'test flat/iris.restart.dsc.yaml', 'set flat/iris.system.dsc.yaml'
        Should -Invoke Restart-Computer -Times 1 -Exactly
        $machine.Warnings | Should -BeLike 'The system configuration is applied, but the computer is not named yet. *'
    }

    It 'does not restart for a rename that the gate restart already applied' {
        $machine.Servicing = @($false, $true)
        $machine.Pending = 'NEWNAME'
        Invoke-SetSystem | Out-Null
        Should -Invoke Restart-Computer -Times 1 -Exactly
    }

    It 'stops with dsc''s exit code, applying nothing, when the restart document cannot be tested' {
        Set-FakeDscResult $dsc iris.restart.dsc.yaml -NoOutput -ExitCode 4 -Operation test
        $result = Invoke-SetSystem
        $result.ExitCode | Should -Be 4
        Get-Calls | Should -Be 'test flat/iris.restart.dsc.yaml'
        $result.Output | Should -BeLike '*dsc/iris.restart.dsc.yaml: dsc failed with exit code 4*'
    }

    It 'stops with the exit code of a restart document that fails to apply' {
        Set-FakeDscResult $dsc iris.restart.dsc.yaml -NoOutput -ExitCode 2 -Operation set
        $machine.Servicing = @($false, $true)
        (Invoke-SetSystem).ExitCode | Should -Be 2
        Should -Invoke Restart-Computer -Times 0 -Exactly
        Get-Calls | Should -Not -Contain 'set flat/iris.system.dsc.yaml'
    }

    It 'stops with the exit code of a system document that fails to apply, without restarting' {
        Set-RestartDocument -InDesiredState
        $machine.Pending = 'NEWNAME'
        Set-FakeDscResult $dsc iris.system.dsc.yaml -NoOutput -ExitCode 2
        (Invoke-SetSystem).ExitCode | Should -Be 2
        Should -Invoke Restart-Computer -Times 0 -Exactly
    }

    It 'still exits 3010, with a warning, when the restart fails' {
        $machine.Servicing = @($false, $true)
        Mock Restart-Computer { throw 'busy' }
        (Invoke-SetSystem).ExitCode | Should -Be 3010
        ($machine.Warnings -join "`n") | Should -BeLike '*Restarting failed*'
    }
}