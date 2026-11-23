# The command runner's reading of the command table (commands.jsonc at the repo root): it checks the table, and
# works out what a command runs and in what order, each command once. The table is data only, so a runner in
# another language can read the same file (docs/dev/tooling.md).
# A usage error (an unknown command, a missing or extra argument) is an ArgumentException. A mistake in the table
# is an InvalidOperationException.


function Read-WinfilesCommand {
    <#
    .SYNOPSIS
    Reads the command table, and checks that every field, command, placeholder and script it names exists.

    .EXAMPLE
    Read-WinfilesCommand -Path ./commands.jsonc -Root .
    #>
    [CmdletBinding()]
    [OutputType([Collections.Specialized.OrderedDictionary])]
    param(
        # The table: JSON with // comments.
        [Parameter(Mandatory)]
        [string]$Path,

        # The repo root, which script paths are relative to.
        [Parameter(Mandatory)]
        [string]$Root
    )

    $table = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    $fields = @(
        'description', 'parameters', 'passArgs', 'requires', 'dependsOn', 'steps', 'script', 'args', 'pwshArgs',
        'builtin', 'privilege', 'uacMessage', 'log', 'clean', 'private', 'group'
    )
    $builtinValues = @('computername', 'username', 'home')
    $problems = foreach ($name in $table.Keys) {
        $definition = $table[$name]
        foreach ($field in $definition.Keys) {
            if ($fields -notcontains $field) {
                "$name has an unknown field, '$field'."
            }
        }
        if ($definition.privilege -and @('admin', 'user', 'any') -notcontains $definition.privilege) {
            "$name has privilege '$($definition.privilege)'; it can be admin, user or any."
        }
        if ($definition.builtin -and @('hosts', 'help') -notcontains $definition.builtin) {
            "$name names a builtin that doesn't exist, '$($definition.builtin)'."
        }
        $missingScript = ($definition.script -and
            -not (Test-Path -LiteralPath (Join-Path -Path $Root -ChildPath $definition.script)))
        if ($missingScript) {
            "$name runs $($definition.script), which doesn't exist."
        }
        $parameterNames = @(Get-WinfilesList -Definition $definition -Field parameters | ForEach-Object -Process {
                $_.name
            })
        foreach ($parameter in Get-WinfilesList -Definition $definition -Field parameters) {
            $used = [regex]::Matches([string]$parameter.default, '\{([\w-]+)\}').Groups |
                Where-Object -Property Name -EQ -Value 1
            foreach ($placeholder in $used) {
                if ($builtinValues -notcontains $placeholder.Value) {
                    "$name's default for $($parameter.name) uses {$($placeholder.Value)}, which isn't one of " +
                    "{$($builtinValues -join '}, {')}."
                }
            }
        }
        $templates = @(
            Get-WinfilesList -Definition $definition -Field requires
            Get-WinfilesList -Definition $definition -Field dependsOn
            Get-WinfilesList -Definition $definition -Field steps
            Get-WinfilesList -Definition $definition -Field args
            $definition.uacMessage
            if ($definition.log) { $definition.log.started; $definition.log.finished }
        )
        foreach ($template in $templates) {
            $used = [regex]::Matches([string]$template, '\{([\w-]+)\}').Groups |
                Where-Object -Property Name -EQ -Value 1
            foreach ($placeholder in $used) {
                if ($parameterNames -notcontains $placeholder.Value) {
                    "$name uses {$($placeholder.Value)}, which isn't one of its parameters."
                }
            }
        }
        $calls = @(
            Get-WinfilesList -Definition $definition -Field dependsOn
            Get-WinfilesList -Definition $definition -Field steps
        )
        foreach ($call in $calls) {
            $called = @($call -split '\s+' | Where-Object -FilterScript { $_ })[0]
            if (-not $table.Contains($called)) {
                "$name runs $called, which isn't a command."
            }
        }
    }
    if ($problems) {
        throw [InvalidOperationException]::new("$Path has mistakes:`n" + ($problems -join "`n"))
    }
    $table
}


function Get-WinfilesList {
    <#
    .SYNOPSIS
    Returns a list field of a command's definition, or nothing when the field is missing.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        # The command's definition, from the table.
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Definition,

        # The field.
        [Parameter(Mandatory)]
        [string]$Field
    )

    if ($Definition.Contains($Field)) {
        $Definition[$Field]
    }
}


function Expand-WinfilesText {
    <#
    .SYNOPSIS
    Replaces each {name} in text with its value.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The text.
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        # The values, by name.
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Value
    )

    # Read-WinfilesCommand has checked that every placeholder has a value
    $expanded = $Text
    foreach ($name in $Value.Keys) {
        $expanded = $expanded.Replace("{$name}", [string]$Value[$name])
    }
    $expanded
}


function Resolve-WinfilesCommand {
    <#
    .SYNOPSIS
    Works out what a command runs: its arguments, and its dependencies and steps, each once, in order.

    .DESCRIPTION
    Returns a tree of nodes: Name, Definition, Values (the parameters by name), Arguments (the values and the
    extra arguments, as a command line would give them), Extra, DependsOn and Steps. A command already met with the
    same arguments, anywhere earlier in the walk, is left out, as just does. A cycle is refused, naming it.

    .EXAMPLE
    Resolve-WinfilesCommand -Table $table -Name install -Argument iris, emily
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # The command table, from Read-WinfilesCommand.
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Table,

        # The command.
        [Parameter(Mandatory)]
        [string]$Name,

        # Its arguments, in order.
        [AllowEmptyCollection()]
        [string[]]$Argument = @(),

        # The commands met so far, by name and arguments. Left out at the top.
        [Collections.Generic.HashSet[string]]$Seen = [Collections.Generic.HashSet[string]]::new(),

        # The commands that led here, to find a cycle. Left out at the top.
        [AllowEmptyCollection()]
        [string[]]$Stack = @()
    )

    if (-not $Table.Contains($Name)) {
        throw [ArgumentException]::new("There's no command named '$Name'. ./winfiles.ps1 lists them.")
    }
    if ($Stack -contains $Name) {
        $cycle = @($Stack[[array]::IndexOf($Stack, $Name)..($Stack.Count - 1)]) + $Name
        throw [InvalidOperationException]::new("The commands run each other in a cycle: $($cycle -join ' -> ')")
    }

    $definition = $Table[$Name]
    $parameters = @(Get-WinfilesList -Definition $definition -Field parameters)
    $builtinValues = @{
        computername = "$env:COMPUTERNAME".ToLowerInvariant()
        username     = $env:USERNAME
        home         = $HOME
    }
    $values = [ordered]@{}
    for ($i = 0; $i -lt $parameters.Count; $i++) {
        $parameter = $parameters[$i]
        if ($i -lt $Argument.Count) {
            $values[$parameter.name] = $Argument[$i]
        } elseif ($parameter.Contains('default')) {
            $values[$parameter.name] = Expand-WinfilesText -Text $parameter.default -Value $builtinValues
        } else {
            throw [ArgumentException]::new(
                "$Name needs <$($parameter.name)>. ./winfiles.ps1 help $Name shows its usage.")
        }
    }
    $extra = @($Argument | Select-Object -Skip $parameters.Count)
    if ($extra -and -not $definition.passArgs) {
        throw [ArgumentException]::new(
            "$Name takes at most $($parameters.Count) arguments, and was also given: $($extra -join ' ')")
    }

    $arguments = @($values.Values) + $extra
    $key = (@($Name) + $arguments) -join [char]0
    if ($Seen.Add($key)) {
        $inner = $Stack + $Name


        function Resolve-WinfilesCall {
            <#
            .SYNOPSIS
            Resolves the commands in a dependsOn or steps list.
            #>
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param(
                # The field.
                [Parameter(Mandatory)]
                [string]$Field
            )

            foreach ($call in Get-WinfilesList -Definition $definition -Field $Field) {
                $parts = @($call -split '\s+' | Where-Object -FilterScript { $_ })
                $callArguments = @($parts | Select-Object -Skip 1 | ForEach-Object -Process {
                        Expand-WinfilesText -Text $_ -Value $values
                    })
                $resolve = @{
                    Table    = $Table
                    Name     = $parts[0]
                    Argument = $callArguments
                    Seen     = $Seen
                    Stack    = $inner
                }
                Resolve-WinfilesCommand @resolve
            }
        }


        $dependsOn = @(Resolve-WinfilesCall -Field dependsOn)
        $steps = @(Resolve-WinfilesCall -Field steps)
        [pscustomobject]@{
            Name       = $Name
            Definition = $definition
            Values     = $values
            Arguments  = $arguments
            Extra      = $extra
            DependsOn  = $dependsOn
            Steps      = $steps
        }
    }
}


function Get-WinfilesNode {
    <#
    .SYNOPSIS
    Returns a resolved command and every command under it, depth first.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # The command, from Resolve-WinfilesCommand.
        [Parameter(Mandatory)]
        [pscustomobject]$Node
    )

    $Node
    foreach ($child in @($Node.DependsOn) + @($Node.Steps)) {
        Get-WinfilesNode -Node $child
    }
}


function Get-WinfilesRequirement {
    <#
    .SYNOPSIS
    Returns the files a resolved command and everything it runs require, each once.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The command, from Resolve-WinfilesCommand.
        [Parameter(Mandatory)]
        [pscustomobject]$Node
    )

    $required = foreach ($each in Get-WinfilesNode -Node $Node) {
        foreach ($file in Get-WinfilesList -Definition $each.Definition -Field requires) {
            Expand-WinfilesText -Text $file -Value $each.Values
        }
    }
    $required | Select-Object -Unique
}
