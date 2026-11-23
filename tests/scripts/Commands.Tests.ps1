# The command runner (winfiles.ps1 and scripts/commands.ps1). Resolving a command is tested in this process against
# tables made for the test. Running one is tested in a checkout in TestDrive: copies of the runner and the
# privilege helpers, a table of its own, a Record.ps1 that writes what it was given, a fake Invoke-Clean.ps1 that
# runs its command in place, and a fake gsudo that runs its command as if elevated. Nothing here elevates, runs
# mise or changes the machine. The real commands.jsonc is only read.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
    . (Join-Path $repo 'scripts\commands.ps1')

    # A table from JSON text, read as the runner reads commands.jsonc, with scripts resolved against the repo
    function New-Table([string]$Json) {
        $file = Join-Path $TestDrive "table-$([guid]::NewGuid()).jsonc"
        Set-Content $file $Json
        Read-WinfilesCommand -Path $file -Root $repo
    }

    # The names of a resolved command and everything under it, in the order they run, with their arguments
    function Get-Order($Node) {
        foreach ($dependency in $Node.DependsOn) { Get-Order $dependency }
        "$(@($Node.Name) + $Node.Arguments)"
        foreach ($step in $Node.Steps) { Get-Order $step }
    }

    # A checkout with the runner, the helpers, a fake Invoke-Clean.ps1 and Record.ps1, and $Table as commands.jsonc
    function New-Checkout([string]$Table) {
        $checkout = New-Item -ItemType Directory (Join-Path $TestDrive "checkout-$([guid]::NewGuid())")
        $scripts = New-Item -ItemType Directory (Join-Path $checkout 'scripts')
        New-Item -ItemType Directory (Join-Path $checkout 'dsc') | Out-Null
        Copy-Item (Join-Path $repo 'winfiles.ps1') $checkout
        $copied = 'commands.ps1', 'winlog.ps1', 'privilege.ps1', 'Invoke-AsAdmin.ps1', 'Invoke-AsUser.ps1'
        foreach ($name in $copied) { Copy-Item (Join-Path $repo "scripts\$name") $scripts }
        Set-Content (Join-Path $checkout 'commands.jsonc') $Table
        # Writes its arguments, and exits with WINFILES_TEST_FAIL_CODE when they start with WINFILES_TEST_FAIL
        Set-Content (Join-Path $scripts 'Record.ps1') @'
$line = "$(if ($env:WINFILES_ELEVATED -eq 'true') { 'elevated' } else { 'unelevated' }) $($args -join ' ')"
Add-Content $env:WINFILES_TEST_RECORD $line
if ($env:WINFILES_TEST_FAIL -and ($args -join ' ') -like "$env:WINFILES_TEST_FAIL*") {
    exit [int]$env:WINFILES_TEST_FAIL_CODE
}
'@
        # Records that it was called, then runs the command here, with nothing cleaned
        Set-Content (Join-Path $scripts 'Invoke-Clean.ps1') @'
Add-Content $env:WINFILES_TEST_RECORD "clean $($args -join ' ')"
& $args[0] @($args | Select-Object -Skip 1)
exit $LASTEXITCODE
'@
        # Stands in for gsudo: records its arguments, then runs what follows `--` as an elevated process would
        $gsudo = Join-Path $checkout 'fake-gsudo.ps1'
        Set-Content $gsudo @'
Add-Content $env:WINFILES_TEST_RECORD "gsudo $($args -join ' ')"
$command = @($args | Select-Object -Skip ([array]::IndexOf($args, 'exec') + 1) | Where-Object { $_ -ne '--' })
$env:WINFILES_ELEVATED = 'true'
& $command[0] @($command | Select-Object -Skip 1)
exit $LASTEXITCODE
'@
        Set-Content (Join-Path $checkout 'gsudo.cmd') "@pwsh -NoLogo -NoProfile -File `"$gsudo`" %*"
        $checkout.FullName
    }

    # Runs winfiles.ps1 in a checkout. Returns its exit code and output, the lines Record.ps1, the fake gsudo and
    # the fake Invoke-Clean.ps1 wrote, and run.log
    function Invoke-Winfiles {
        param(
            [string]$Checkout, [string[]]$Arguments = @(), [bool]$Elevated = $false, [string]$Fail,
            [int]$FailCode = 1
        )
        $record = Join-Path $Checkout "record-$([guid]::NewGuid()).txt"
        $userProfile = New-Item -ItemType Directory "$record-home"
        $result = Invoke-Child $Checkout @{
            WINFILES_ELEVATED       = "$Elevated".ToLower()
            WINFILES_GSUDO          = Join-Path $Checkout 'gsudo.cmd'
            WINFILES_TEST_RECORD    = $record
            WINFILES_TEST_FAIL      = $Fail
            WINFILES_TEST_FAIL_CODE = "$FailCode"
            USERPROFILE             = $userProfile.FullName
        } { pwsh -NoLogo -NoProfile -NonInteractive -File "$Checkout\winfiles.ps1" @Arguments }
        $log = Join-Path $userProfile '.local\state\winfiles\run.log'
        $result | Add-Member Record @(if (Test-Path $record) { Get-Content $record }) -PassThru |
            Add-Member Log @(if (Test-Path $log) { Get-Content $log }) -PassThru
    }
}

Describe 'Read-WinfilesCommand' {
    It 'reads the real commands.jsonc, comments and all' {
        $table = Read-WinfilesCommand -Path (Join-Path $repo 'commands.jsonc') -Root $repo
        $table.Keys | Should -Contain 'install'
    }

    It 'refuses <Problem>' -ForEach @(
        @{
            Problem = 'an unknown field'
            Json    = '{ "a": { "colour": "red" } }'; Message = "unknown field, 'colour'"
        }
        @{
            Problem = 'a privilege that does not exist'
            Json    = '{ "a": { "privilege": "root" } }'; Message = 'root'
        }
        @{ Problem = 'a step that is not a command'; Json = '{ "a": { "steps": ["b"] } }'; Message = 'runs b' }
        @{
            Problem = 'a script that does not exist'; Json = '{ "a": { "script": "scripts/Nope.ps1" } }'
            Message = "Nope.ps1, which doesn't exist"
        }
        @{
            Problem = 'a placeholder that is not a parameter'
            Json    = '{ "a": { "requires": ["dsc/{host}.yaml"] } }'; Message = '{host}'
        }
        @{
            Problem = 'a default with an unknown placeholder'
            Json    = '{ "a": { "parameters": [{ "name": "x", "default": "{nope}" }] } }'; Message = '{nope}'
        }
    ) {
        { New-Table $Json } | Should -Throw "*$Message*"
    }
}

Describe 'Resolve-WinfilesCommand' {
    BeforeAll {
        $table = New-Table @'
{
    // Comments are allowed
    "a": {
        "parameters": [{ "name": "x", "default": "one" }], "dependsOn": ["b {x}"], "steps": ["c {x}", "b {x}"]
    },
    "b": { "parameters": [{ "name": "x" }], "dependsOn": ["c {x}"] },
    "c": { "parameters": [{ "name": "x" }] },
    "d": { "steps": ["c 1", "c 2", "c 1"] },
    "loop": { "steps": ["loop2"] },
    "loop2": { "dependsOn": ["loop"] },
    "machine": {
        "parameters": [{ "name": "host", "default": "{computername}" }, { "name": "who", "default": "{username}" }]
    },
    "pass": { "parameters": [{ "name": "x" }], "passArgs": true },
    "required": { "parameters": [{ "name": "x" }] }
}
'@
    }

    It 'runs dependencies first, depth first, then steps in order, each once per set of arguments' {
        Get-Order (Resolve-WinfilesCommand -Table $table -Name a) | Should -Be @('c one', 'b one', 'a one')
    }

    It 'runs a command again with other arguments, but not with the same ones' {
        Get-Order (Resolve-WinfilesCommand -Table $table -Name d) | Should -Be @('d', 'c 1', 'c 2')
    }

    It 'refuses a cycle, naming it' {
        { Resolve-WinfilesCommand -Table $table -Name loop } | Should -Throw '*cycle: loop -> loop2 -> loop'
    }

    It 'defaults the host to the computer name in lowercase, and the user to USERNAME' {
        $node = Resolve-WinfilesCommand -Table $table -Name machine
        $node.Values.host | Should -BeExactly $env:COMPUTERNAME.ToLowerInvariant()
        $node.Values.who | Should -BeExactly $env:USERNAME
    }

    It 'passes the arguments after the parameters on, for a command with passArgs' {
        $node = Resolve-WinfilesCommand -Table $table -Name pass -Argument 1, '-Ref', 'two words'
        $node.Values.x | Should -Be '1'
        $node.Extra | Should -Be @('-Ref', 'two words')
    }

    It 'refuses <Case>, as a usage error' -ForEach @(
        @{
            Case = 'a command that does not exist'; Name = 'nope'; Arguments = @()
            Message = "*no command named 'nope'*"
        }
        @{ Case = 'a missing argument'; Name = 'required'; Arguments = @(); Message = '*required needs <x>*' }
        @{ Case = 'an extra argument'; Name = 'required'; Arguments = @('1', '2'); Message = '*at most 1*: 2' }
    ) {
        { Resolve-WinfilesCommand -Table $table -Name $Name -Argument $Arguments } |
            Should -Throw -ExceptionType ([ArgumentException]) -ExpectedMessage $Message
    }
}

Describe 'the real install command' {
    BeforeAll {
        $table = Read-WinfilesCommand -Path (Join-Path $repo 'commands.jsonc') -Root $repo
        $node = Resolve-WinfilesCommand -Table $table -Name install -Argument iris, emily
    }

    It 'applies system and home as one aggregate, then checks, then prints the post-install notes' {
        Get-Order $node | Should -Be @(
            'install iris emily', 'configure iris emily', 'check iris emily', 'post-install iris emily'
        )
        $node.Steps[0].Definition.args |
            Should -Be @('set', 'dsc/{host}.system.dsc.yaml', 'dsc/{user}@{host}.home.dsc.yaml')
        $node.Steps[1].Definition.args |
            Should -Be @('test', 'dsc/{host}.system.dsc.yaml', 'dsc/{user}@{host}.home.dsc.yaml')
    }

    It 'requires both configurations' {
        Get-WinfilesRequirement -Node $node |
            Should -Be @('dsc/iris.system.dsc.yaml', 'dsc/emily@iris.home.dsc.yaml')
    }
}

Describe 'winfiles.ps1' {
    BeforeAll {
        $checkout = New-Checkout @'
{
    "all": {
        "description": "the whole thing",
        "parameters": [{ "name": "host", "default": "h" }],
        "requires": ["dsc/{host}.yaml"],
        "steps": ["first {host}", "elevated {host}", "last {host}"],
        "privilege": "admin",
        "uacMessage": "Asking for UAC for {host}",
        "log": { "phase": "all", "started": "started {host}", "finished": "finished {host}" },
        "clean": true
    },
    "first": {
        "private": true, "parameters": [{ "name": "host" }], "script": "scripts/Record.ps1",
        "args": ["first", "{host}"]
    },
    "elevated": {
        "private": true, "parameters": [{ "name": "host" }], "script": "scripts/Record.ps1",
        "args": ["elevated-step"], "privilege": "admin"
    },
    "last": {
        "private": true, "parameters": [{ "name": "host" }], "script": "scripts/Record.ps1", "args": ["last"]
    },
    "unelevated": {
        "description": "drops privilege", "script": "scripts/Record.ps1", "args": ["as-user"], "privilege": "user"
    },
    "pass": {
        "description": "passes arguments on", "group": "g", "script": "scripts/Record.ps1", "args": ["pass"],
        "passArgs": true
    },
    "hosts": { "description": "list hosts", "builtin": "hosts" }
}
'@
        Set-Content (Join-Path $checkout 'dsc\h.yaml') ''
        Set-Content (Join-Path $checkout 'dsc\a.system.dsc.yaml') ''
    }

    It 'checks what the whole plan requires before it cleans, elevates or runs anything' {
        $result = Invoke-Winfiles $checkout all, missing
        $result.ExitCode | Should -Be 1
        $result.Stderr | Should -Contain 'No configuration at dsc/missing.yaml.'
        $result.Stdout | Should -Contain 'a.system'
        $result.Record | Should -BeNullOrEmpty
        $result.Log | Should -BeNullOrEmpty
    }

    It 'cleans the environment once, elevates once, and runs every step in the elevated run' {
        $result = Invoke-Winfiles $checkout all
        $result.ExitCode | Should -Be 0
        $result.Record | Should -HaveCount 5
        $result.Record[0] | Should -BeLike "clean pwsh * --clean all"
        $result.Record[1] | Should -BeLike "gsudo --direct mise exec * --run all h"
        $result.Record[2..4] | Should -Be @('elevated first h', 'elevated elevated-step', 'elevated last')
    }

    It 'says what the UAC prompt is for, and logs that it started and finished' {
        $result = Invoke-Winfiles $checkout all
        $result.Stdout | Should -Contain 'Asking for UAC for h'
        $result.Log | Should -HaveCount 4
        $result.Log[0] | Should -Match '\[all\] started h$'
        $result.Log[-1] | Should -Match '\[all\] finished h$'
    }

    It 'neither asks nor says anything about UAC from an elevated shell' {
        $result = Invoke-Winfiles $checkout all -Elevated $true
        $result.ExitCode | Should -Be 0
        $result.Record | Where-Object { $_ -like 'gsudo*' } | Should -BeNullOrEmpty
        $result.Stdout | Should -Not -Contain 'Asking for UAC for h'
        $result.Record[1..3] | Should -Be @('elevated first h', 'elevated elevated-step', 'elevated last')
    }

    It 'stops at the first step that fails and exits with its code unchanged (<code>)' -ForEach @(
        @{ code = 3010 }, @{ code = 194 }, @{ code = 1 }
    ) {
        $result = Invoke-Winfiles $checkout all -Fail elevated-step -FailCode $code
        $result.ExitCode | Should -Be $code
        $result.Record[-1] | Should -Be 'elevated elevated-step'
        $result.Log | Should -Not -Match 'finished'
    }

    It 'drops privilege through gsudo -i Medium for a user command from an elevated shell' {
        $result = Invoke-Winfiles $checkout unelevated -Elevated $true
        $result.Record[0] | Should -BeLike 'gsudo -i Medium --direct mise exec * --run unelevated'
    }

    It "passes a command's extra arguments on as they are, dashes and spaces included" {
        $result = Invoke-Winfiles $checkout pass, '-Ref', 'two words', '-Verbose'
        $result.ExitCode | Should -Be 0
        $result.Record | Should -Be @('unelevated pass -Ref two words -Verbose')
    }

    It 'lists the commands that are not private, by group' {
        $result = Invoke-Winfiles $checkout
        $result.ExitCode | Should -Be 0
        $text = $result.Stdout -join "`n"
        $text | Should -Match 'all \[host\] +# the whole thing'
        $text | Should -Match '\[g\]\n +pass \[arguments\.\.\.\] +# passes arguments on'
        $text | Should -Not -Match 'first'
    }

    It 'exits 2 for <Case>' -ForEach @(
        @{ Case = 'a command that does not exist'; Arguments = @('nope') }
        @{ Case = 'an extra argument'; Arguments = @('hosts', 'x') }
    ) {
        $result = Invoke-Winfiles $checkout $Arguments
        $result.ExitCode | Should -Be 2
        $result.Record | Should -BeNullOrEmpty
    }
}

Describe 'help' {
    It "shows a command's usage and defaults, then the help of the script its extra arguments go to" {
        $result = Invoke-Child $repo @{} {
            pwsh -NoLogo -NoProfile -NonInteractive -File "$repo\winfiles.ps1" help test-vm-copy
        }
        $result.ExitCode | Should -Be 0
        $result.Stdout[0] | Should -Be 'Usage: ./winfiles.ps1 test-vm-copy [name] [arguments...]'
        $result.Stdout | Should -Contain '    name: default winfiles-test'
        $result.Stdout | Should -Contain '    Copy-RepoToTestVm.ps1'
        $result.Stdout | Should -Contain '        [[-Ref] <String>]'
    }

    It 'shows only the usage of a command without extra arguments' {
        $result = Invoke-Child $repo @{} {
            pwsh -NoLogo -NoProfile -NonInteractive -File "$repo\winfiles.ps1" help hosts
        }
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Not -Contain 'SYNOPSIS'
    }
}

# Temporary, until the justfile is removed: every recipe someone can run has a command, with as many parameters,
# the same ones optional, and passArgs where the recipe has *args
Describe 'parity with the justfile' {
    BeforeDiscovery {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $dump = just --justfile (Join-Path $root 'justfile') --dump --dump-format json | ConvertFrom-Json
        $recipes = foreach ($property in $dump.recipes.PSObject.Properties) {
            if (-not $property.Value.private) { @{ Name = $property.Name; Recipe = $property.Value } }
        }
    }

    BeforeAll {
        $table = Read-WinfilesCommand -Path (Join-Path $repo 'commands.jsonc') -Root $repo
    }

    It '<Name> has a command with the same parameters' -ForEach $recipes {
        $table.Contains($Name) | Should -BeTrue
        $definition = $table[$Name]
        $plain = @($Recipe.parameters | Where-Object kind -EQ 'singular')
        $parameters = @(Get-WinfilesList -Definition $definition -Field parameters)
        $parameters | Should -HaveCount $plain.Count
        for ($i = 0; $i -lt $plain.Count; $i++) {
            $parameters[$i].Contains('default') | Should -Be ($null -ne $plain[$i].default)
        }
        [bool]$definition.passArgs | Should -Be ([bool]($Recipe.parameters | Where-Object kind -NE 'singular'))
    }
}
