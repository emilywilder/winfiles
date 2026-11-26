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
        $copied = 'commands.ps1', 'winlog.ps1', 'privilege.ps1', 'resume.ps1'
        $copied += 'Invoke-AsAdmin.ps1', 'Invoke-AsUser.ps1'
        foreach ($name in $copied) { Copy-Item (Join-Path $repo "scripts\$name") $scripts }
        Set-Content (Join-Path $checkout 'commands.jsonc') $Table
        # Writes its arguments, and exits with WINFILES_TEST_FAIL_CODE when they start with WINFILES_TEST_FAIL
        Set-Content (Join-Path $scripts 'Record.ps1') @'
$line = "$(if ($env:WINFILES_ELEVATED -eq 'true') { 'elevated' } else { 'unelevated' }) $($args -join ' ')"
if ($env:WINFILES_RESUME) { $line += " WINFILES_RESUME=$env:WINFILES_RESUME" }
Add-Content $env:WINFILES_TEST_RECORD $line
Add-Content "$env:WINFILES_TEST_RECORD.command" "$env:WINFILES_COMMAND"
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
    # the fake Invoke-Clean.ps1 wrote, the WINFILES_COMMAND each Record.ps1 saw, and run.log
    function Invoke-Winfiles {
        param(
            [string]$Checkout, [string[]]$Arguments = @(), [bool]$Elevated = $false, [string]$Fail,
            [int]$FailCode = 1,
            # The RunOnce key a resumable command clears: one of the test's own, never the real RunOnce
            [string]$RunOnceKey = "HKCU:\Software\winfiles-test-$([guid]::NewGuid())",
            # What the calling shell has already set, as a parent winfiles.ps1 would
            [hashtable]$Inherited = @{}
        )
        $record = Join-Path $Checkout "record-$([guid]::NewGuid()).txt"
        $userProfile = New-Item -ItemType Directory "$record-home"
        $environment = @{
            WINFILES_ELEVATED       = "$Elevated".ToLower()
            WINFILES_GSUDO          = Join-Path $Checkout 'gsudo.cmd'
            WINFILES_TEST_RECORD    = $record
            WINFILES_TEST_FAIL      = $Fail
            WINFILES_TEST_FAIL_CODE = "$FailCode"
            WINFILES_RUNONCE_KEY    = $RunOnceKey
            USERPROFILE             = $userProfile.FullName
        }
        $result = Invoke-Child $Checkout ($environment + $Inherited) {
            pwsh -NoLogo -NoProfile -NonInteractive -File "$Checkout\winfiles.ps1" @Arguments
        }
        $log = Join-Path $userProfile '.local\state\winfiles\run.log'
        $result | Add-Member Record @(if (Test-Path $record) { Get-Content $record }) -PassThru |
            Add-Member Command @(if (Test-Path "$record.command") { Get-Content "$record.command" }) -PassThru |
            Add-Member Log @(if (Test-Path $log) { Get-Content $log }) -PassThru
    }
}

Describe 'Read-WinfilesCommand' {
    It 'reads the real commands.jsonc, comments and all' {
        $table = Read-WinfilesCommand -Path (Join-Path $repo 'commands.jsonc') -Root $repo
        $table.Keys | Should -Contain 'switch'
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
        @{
            Problem = 'a flag whose name is not lowercase letters, digits and dashes'
            Json    = '{ "a": { "flags": [{ "name": "Go" }] } }'; Message = "flag named 'Go'"
        }
        @{
            Problem = 'resumable naming something that is not one of its flags'
            Json    = '{ "a": { "resumable": true } }'; Message = "resumable by 'True'"
        }
        @{
            Problem = 'a step given a flag its command does not have'
            Json    = '{ "a": { "steps": ["b --go"] }, "b": {} }'; Message = 'runs b with --go'
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
    "required": { "parameters": [{ "name": "x" }] },
    "flagged": {
        "parameters": [{ "name": "x", "default": "one" }, { "name": "y", "default": "two" }],
        "flags": [{ "name": "go" }, { "name": "also" }]
    },
    "calls": { "steps": ["flagged a b --go"] },
    "passflagged": { "flags": [{ "name": "go" }], "passArgs": true }
}
'@
    }

    It 'with passArgs, takes its own flags and passes other -- arguments on' {
        $node = Resolve-WinfilesCommand -Table $table -Name passflagged -Argument '--other', '--go', '--Go'
        $node.Flags | Should -Be 'go'
        $node.Extra | Should -BeExactly @('--other', '--Go')
    }

    It 'takes flags from anywhere in the arguments, and gives them back last, in the table''s order' {
        $node = Resolve-WinfilesCommand -Table $table -Name flagged -Argument '--also', 'a', '--go', 'b'
        $node.Values.x | Should -Be 'a'
        $node.Values.y | Should -Be 'b'
        $node.Flags | Should -Be @('go', 'also')
        $node.Arguments | Should -Be @('a', 'b', '--go', '--also')
    }

    It 'leaves a flag off unless it is given' {
        $node = Resolve-WinfilesCommand -Table $table -Name flagged
        $node.Flags | Should -BeNullOrEmpty
        $node.Arguments | Should -Be @('one', 'two')
    }

    It 'passes a flag a step gives on to that step' {
        Get-Order (Resolve-WinfilesCommand -Table $table -Name calls) | Should -Be @('calls', 'flagged a b --go')
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
        @{
            Case = 'a flag the command does not have'; Name = 'flagged'; Arguments = @('--nope')
            Message = '*flagged has no flag --nope*'
        }
        @{
            Case = 'a flag in another case'; Name = 'flagged'; Arguments = @('--Go')
            Message = '*flagged has no flag --Go*'
        }
    ) {
        { Resolve-WinfilesCommand -Table $table -Name $Name -Argument $Arguments } |
            Should -Throw -ExceptionType ([ArgumentException]) -ExpectedMessage $Message
    }
}

Describe 'the real switch command' {
    BeforeAll {
        $table = Read-WinfilesCommand -Path (Join-Path $repo 'commands.jsonc') -Root $repo
        $node = Resolve-WinfilesCommand -Table $table -Name switch -Argument iris, emily
    }

    It 'applies system and home as one aggregate, then checks, then prints the post-install notes' {
        Get-Order $node | Should -Be @(
            'switch iris emily', 'configure iris emily', 'check iris emily', 'post-install iris emily'
        )
        $node.Steps[0].Definition.args |
            Should -Be @('set', 'dsc/{host}.system.dsc.yaml', 'dsc/{user}@{host}.home.dsc.yaml')
        $node.Steps[1].Definition.args |
            Should -Be @('test', 'dsc/{host}.system.dsc.yaml', 'dsc/{user}@{host}.home.dsc.yaml')
    }

    It "reads the post-install notes from the host's manual list and both entries" {
        $node.Steps[2].Definition.args | Should -Be @(
            'dsc/hosts/{host}/manual.yaml', 'dsc/{host}.system.dsc.yaml', 'dsc/{user}@{host}.home.dsc.yaml'
        )
    }

    It 'requires both configurations' {
        Get-WinfilesRequirement -Node $node |
            Should -Be @('dsc/iris.system.dsc.yaml', 'dsc/emily@iris.home.dsc.yaml')
    }

    It 'restarts and resumes only with --restart, its resumable flag' {
        $node.Definition.resumable | Should -Be 'restart'
        $node.Flags | Should -BeNullOrEmpty
        (Resolve-WinfilesCommand -Table $table -Name switch -Argument iris, --restart).Flags | Should -Be 'restart'
    }

    It 'leaves system attended: no flag, and not resumable' {
        $table['system'].Contains('flags') | Should -BeFalse
        $table['system'].Contains('resumable') | Should -BeFalse
    }
}

Describe 'the real resume command' {
    BeforeAll {
        $table = Read-WinfilesCommand -Path (Join-Path $repo 'commands.jsonc') -Root $repo
        $node = Resolve-WinfilesCommand -Table $table -Name resume -Argument iris, emily
    }

    It 'waits for the person and the network, then runs switch --restart with the arguments it was given' {
        Get-Order $node | Should -Be @(
            'resume iris emily', 'wait-resume', 'switch iris emily --restart', 'configure iris emily',
            'check iris emily', 'post-install iris emily'
        )
    }

    It 'requires what switch requires' {
        Get-WinfilesRequirement -Node $node |
            Should -Be @('dsc/iris.system.dsc.yaml', 'dsc/emily@iris.home.dsc.yaml')
    }

    It 'is not resumable itself: switch --restart is, and arms the next resume' {
        $node.Definition.Contains('resumable') | Should -BeFalse
        $node.Steps[1].Flags | Should -Be $node.Steps[1].Definition.resumable
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
    "resumable": {
        "description": "can resume after a restart", "parameters": [{ "name": "host", "default": "h" }],
        "flags": [{ "name": "restart", "description": "restart and resume" }],
        "script": "scripts/Record.ps1", "args": ["resumable", "{host}"], "privilege": "admin",
        "resumable": "restart"
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

    It 'tells every step the command that was run, with its defaults, for the message after a restart' {
        $result = Invoke-Winfiles $checkout all
        $result.ExitCode | Should -Be 0
        $result.Command | Should -Be @('all h', 'all h', 'all h')
    }

    It 'quotes an argument with a space in the command it tells the script, and keeps a flag' {
        $result = Invoke-Winfiles $checkout resumable, 'two words', --restart
        $result.Command | Should -Be @('resumable "two words" --restart')
    }

    It 'names its own command to the script, not one the calling shell left in WINFILES_COMMAND' {
        $result = Invoke-Winfiles $checkout pass -Inherited @{ WINFILES_COMMAND = 'switch stale' }
        $result.ExitCode | Should -Be 0
        $result.Command | Should -Be @('pass')
    }

    Context 'a resumable command' {
        BeforeEach {
            $key = "HKCU:\Software\winfiles-test-$([guid]::NewGuid())"
            New-Item $key | Out-Null
            New-ItemProperty $key -Name winfiles -Value 'left by an earlier run' | Out-Null
            New-ItemProperty $key -Name other -Value keep | Out-Null
        }

        AfterEach {
            Remove-Item $key -ErrorAction Ignore
        }

        It 'clears the resume an earlier run left, and says so in run.log, but nothing else in the key' {
            $result = Invoke-Winfiles $checkout resumable -RunOnceKey $key
            $result.ExitCode | Should -Be 0
            (Get-ItemProperty $key).winfiles | Should -BeNullOrEmpty
            (Get-ItemProperty $key).other | Should -Be keep
            # Once, in the run that started it, not again in the elevated run
            $cleared = @($result.Log | Where-Object { $_ -match '\[resume\]' })
            $cleared | Should -HaveCount 1
            $cleared[0] | Should -Match '\[resume\] removed the RunOnce entry an earlier run left$'
        }

        It 'with its flag, gives the script its arguments and defaults (elevated: <elevated>)' -ForEach @(
            @{ elevated = $false }, @{ elevated = $true }
        ) {
            $result = Invoke-Winfiles $checkout resumable, --restart -Elevated $elevated -RunOnceKey $key
            $result.Record[-1] | Should -Be 'elevated resumable h WINFILES_RESUME=["h"]'
        }

        It 'carries the flag across the change of privilege' {
            $result = Invoke-Winfiles $checkout resumable, --restart -RunOnceKey $key
            $result.Record | Where-Object { $_ -like 'gsudo*' } | Should -BeLike '* --run resumable h --restart'
        }

        It 'takes the arguments as typed when there are some, with the flag before them' {
            $result = Invoke-Winfiles $checkout resumable, --restart, 'two words' -RunOnceKey $key
            $result.Record[-1] | Should -Be 'elevated resumable two words WINFILES_RESUME=["two words"]'
        }

        It 'without its flag, still clears the earlier entry but gives the script no resume' {
            $result = Invoke-Winfiles $checkout resumable -RunOnceKey $key
            $result.ExitCode | Should -Be 0
            (Get-ItemProperty $key).winfiles | Should -BeNullOrEmpty
            $result.Record[-1] | Should -Be 'elevated resumable h'
        }

        It 'without its flag, drops a resume the calling shell left in WINFILES_RESUME' {
            $stale = @{ WINFILES_RESUME = '["stale"]' }
            $result = Invoke-Winfiles $checkout resumable -RunOnceKey $key -Inherited $stale
            $result.ExitCode | Should -Be 0
            $result.Record[-1] | Should -Be 'elevated resumable h'
        }

        It 'leaves another command''s resume alone, and sets no resume for its steps' {
            $result = Invoke-Winfiles $checkout all -RunOnceKey $key
            $result.ExitCode | Should -Be 0
            (Get-ItemProperty $key).winfiles | Should -Be 'left by an earlier run'
            $result.Record | Where-Object { $_ -like '*WINFILES_RESUME*' } | Should -BeNullOrEmpty
        }
    }

    It 'lists the commands that are not private, by group' {
        $result = Invoke-Winfiles $checkout
        $result.ExitCode | Should -Be 0
        $text = $result.Stdout -join "`n"
        $text | Should -Match 'all \[host\] +# the whole thing'
        $text | Should -Match 'resumable \[host\] \[--restart\] +# can resume after a restart'
        $text | Should -Match '\[g\]\n +pass \[arguments\.\.\.\] +# passes arguments on'
        $text | Should -Not -Match 'first'
    }

    It 'exits 2 for <Case>' -ForEach @(
        @{ Case = 'a command that does not exist'; Arguments = @('nope') }
        @{ Case = 'an extra argument'; Arguments = @('hosts', 'x') }
        @{ Case = 'a flag the command does not have'; Arguments = @('resumable', '--nope') }
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

    It 'shows a command''s flags with what each does' {
        $result = Invoke-Child $repo @{} {
            pwsh -NoLogo -NoProfile -NonInteractive -File "$repo\winfiles.ps1" help switch
        }
        $result.ExitCode | Should -Be 0
        $result.Stdout[0] | Should -Be 'Usage: ./winfiles.ps1 switch [host] [user] [--restart]'
        $result.Stdout | Should -Contain (
            '    --restart: restart Windows when the run needs it, and continue at the next sign-in once ' +
            'Enter is pressed (install.cmd passes it)')
    }

    It 'shows only the usage of a command without extra arguments' {
        $result = Invoke-Child $repo @{} {
            pwsh -NoLogo -NoProfile -NonInteractive -File "$repo\winfiles.ps1" help hosts
        }
        $result.ExitCode | Should -Be 0
        $result.Stdout | Should -Not -Contain 'SYNOPSIS'
    }
}
