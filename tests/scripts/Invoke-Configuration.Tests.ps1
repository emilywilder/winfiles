# Invoke-Configuration.ps1 in a process of its own, with the real flattener and Set-Winfiles.ps1 under it, a fake dsc
# (tests/fakes/bin/dsc.cmd) and a fake gsudo, so no test elevates or changes the machine. The process is told it is
# elevated, as `just install` runs it, so an elevated batch runs dsc itself and an unelevated one goes to gsudo, whose
# fake records what it was asked to run (its last call only) and runs nothing.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')

    $header = '$schema: https://raw.githubusercontent.com/PowerShell/DSC/main/schemas/2023/08/config/document.json'

    # a (user), then b (elevated, after a), then c (user, after b): one batch each
    $threeLevels = @'
resources:
  - type: Test/Thing
    name: a
    properties: {}
  - type: Test/Thing
    name: b
    dependsOn: ["[resourceId('Test/Thing', 'a')]"]
    metadata: { winget: { securityContext: elevated } }
    properties: {}
  - type: Test/Thing
    name: c
    dependsOn: ["[resourceId('Test/Thing', 'b')]"]
    properties: {}
'@

    function New-Entry([string]$Body) {
        $folder = New-Item -ItemType Directory (Join-Path $TestDrive "entry-$([guid]::NewGuid())")
        $file = Join-Path $folder 'entry.dsc.yaml'
        [IO.File]::WriteAllText($file, "$header`n$Body", [Text.UTF8Encoding]::new($false))
        $file
    }

    # Runs the script elevated (or not) with a fake dsc and gsudo; the result has what dsc was asked, as
    # "<operation> <batch name>", what gsudo was asked to run, and run.log
    function Invoke-Configuration([string]$Operation, [string]$File, [bool]$Elevated = $true) {
        $bin = New-Item -ItemType Directory (Join-Path $TestDrive "gsudo-$([guid]::NewGuid())")
        Copy-Item (Join-Path $fakes 'bin\gsudo.cmd'), (Join-Path $fakes 'bin\fake-gsudo.ps1') $bin
        $record = Join-Path $bin 'arguments.txt'
        $environment = $script:dsc.Environment.Clone()
        $environment.WINFILES_ELEVATED = "$Elevated".ToLower()
        $environment.WINFILES_GSUDO = Join-Path $bin 'gsudo.cmd'
        $environment.WINFILES_FAKE_GSUDO = $record
        $result = Invoke-Script Invoke-Configuration.ps1 $Operation, $File -Environment $environment
        $log = Join-Path $script:dsc.Home '.local\state\winfiles\run.log'
        $result | Add-Member Calls @(Get-FakeDscCalls $script:dsc | ForEach-Object { "$($_.args[1]) $(Split-Path $_.args[5] -Leaf)" }) -PassThru |
            Add-Member Gsudo @(if (Test-Path $record) { Get-Content $record }) -PassThru |
            Add-Member Log @(if (Test-Path $log) { Get-Content $log }) -PassThru
    }
}

Describe 'Invoke-Configuration.ps1' {
    BeforeEach {
        $script:dsc = New-FakeDsc
    }

    It 'applies the elevated batch itself and hands the unelevated ones to gsudo, in order' {
        $result = Invoke-Configuration set (New-Entry $threeLevels)
        $result.ExitCode | Should -Be 0
        $result.Calls | Should -Be @('set entry.2-elevated.dsc.yaml')
        # The fake keeps only the last call: the batch after the elevated one
        $result.Gsudo | Should -Contain '-i'
        ($result.Gsudo -join ' ') | Should -BeLike '*Set-Winfiles.ps1*entry.3-user.dsc.yaml -NoFlatten*'
        ($result.Log -join "`n") | Should -BeLike '*3 batches: user x1, elevated x1, user x1*'
    }

    It 'stops at the first batch that fails, with its exit code, and starts none after it' {
        Set-FakeDscResult $dsc entry.2-elevated.dsc.yaml @() -ExitCode 7 -Operation set
        $result = Invoke-Configuration set (New-Entry $threeLevels)
        $result.ExitCode | Should -Be 7
        # Batch 1 (user) went to gsudo, which was the last call it saw, so batch 3 never started
        ($result.Gsudo -join ' ') | Should -BeLike '*entry.1-user.dsc.yaml*'
        ($result.Gsudo -join ' ') | Should -Not -BeLike '*entry.3-user*'
        ($result.Log -join "`n") | Should -BeLike '*batch 2*ended with exit code 7, so the run stops*'
    }

    It 'tests every batch, even after one fails, and exits 1' {
        Set-FakeDscResult $dsc entry.2-elevated.dsc.yaml @() -ExitCode 1 -Operation test
        $result = Invoke-Configuration test (New-Entry $threeLevels)
        $result.ExitCode | Should -Be 1
        $result.Calls | Should -Be @('test entry.2-elevated.dsc.yaml')
        ($result.Gsudo -join ' ') | Should -BeLike '*Test-Winfiles.ps1*entry.3-user.dsc.yaml -NoFlatten*'
        ($result.Stdout + $result.Stderr -join ' ') | Should -BeLike '*1 of 3 batches failed*'
    }

    It 'exits 0 from a test when every batch passes' {
        $result = Invoke-Configuration test (New-Entry $threeLevels)
        $result.ExitCode | Should -Be 0
    }

    It 'runs a batch of the restart stage through Set-RestartStage.ps1, which tests it first' {
        $entry = New-Entry @'
resources:
  - type: Test/Thing
    name: features
    metadata:
      winget: { securityContext: elevated }
      winfiles: { stage: restart }
    properties: {}
  - type: Test/Thing
    name: after
    metadata: { winget: { securityContext: elevated } }
    properties: {}
'@
        $result = Invoke-Configuration set $entry
        # Whether it goes on depends on what this machine says about a pending restart, which a child can't mock, so
        # only the order is checked: the restart stage is tested before it is applied, and the next is the stage's own
        $result.Calls[0] | Should -Be 'test entry.1-elevated.dsc.yaml'
        ($result.Log -join "`n") | Should -BeLike '*batch 1 of 2: elevated, 1 resources, Set-RestartStage.ps1*'
    }

    It 'fails with the flattener''s reason when the entry can''t be made into batches' {
        $result = Invoke-Configuration set (Join-Path $TestDrive 'no-such.dsc.yaml')
        $result.ExitCode | Should -Be 1
        ($result.Stdout + $result.Stderr -join ' ') | Should -BeLike "*couldn't make batches of it*doesn't exist*"
        $result.Calls | Should -BeNullOrEmpty
    }
}
