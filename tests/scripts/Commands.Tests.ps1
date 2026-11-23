# The command runner's table (commands.jsonc and scripts/commands.ps1). Reading and resolving a command is tested in
# this process against tables made for the test. The real commands.jsonc is only read.
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
    }

    It 'requires both configurations' {
        Get-WinfilesRequirement -Node $node |
            Should -Be @('dsc/iris.system.dsc.yaml', 'dsc/emily@iris.home.dsc.yaml')
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
