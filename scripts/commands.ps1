# The command runner behind winfiles.ps1, which dot-sources it. It reads the command table (commands.jsonc at the
# repo root), works out what a command runs and in what order, and runs it: the requirements of the whole plan
# first, then once through Invoke-Clean.ps1 for a clean environment, then once through Invoke-AsAdmin.ps1 or
# Invoke-AsUser.ps1 when a command needs a privilege the shell doesn't have, then the scripts. The scripts' output
# streams straight through, and the run ends with the exit code of the first script that failed, unchanged.
# The table is data only, so a runner in another language can read the same file (docs/dev/tooling.md).
# A usage error (an unknown command, a missing or extra argument) is an ArgumentException, which winfiles.ps1
# reports with exit code 2. A mistake in the table is an InvalidOperationException.

. (Join-Path -Path $PSScriptRoot -ChildPath 'winlog.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'privilege.ps1')


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
    same arguments, anywhere earlier in the walk, is left out. A cycle is refused, naming it.

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


function Get-WinfilesHost {
    <#
    .SYNOPSIS
    Returns the names of the system and home configurations in a checkout's dsc folder.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The repo root.
        [Parameter(Mandatory)]
        [string]$Root
    )

    Get-ChildItem -Path (Join-Path -Path $Root -ChildPath dsc) -File -Filter *.dsc.yaml |
        ForEach-Object -Process { $_.Name -replace '\.dsc\.yaml$' }
}


function Test-WinfilesElevated {
    <#
    .SYNOPSIS
    Tests whether this process is elevated, or what WINFILES_ELEVATED says, for the tests.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if ($env:WINFILES_ELEVATED) {
        $env:WINFILES_ELEVATED -eq 'true'
    } else {
        Test-Elevated
    }
}


function Invoke-WinfilesNode {
    <#
    .SYNOPSIS
    Runs a resolved command: its dependencies, then its steps and script under the privilege it needs.

    .DESCRIPTION
    Output streams through. The exit code is left in $LASTEXITCODE: that of the first thing that failed, unchanged,
    or 0. A command that needs another privilege runs again as `winfiles.ps1 --run <command> <arguments>`, through
    Invoke-AsAdmin.ps1 or Invoke-AsUser.ps1, which ask for UAC or drop privilege only when the shell needs it.
    -Hopped is that second run: its dependencies have run, its privilege is right and its log lines are written.
    #>
    [CmdletBinding()]
    param(
        # The command, from Resolve-WinfilesCommand.
        [Parameter(Mandatory)]
        [pscustomobject]$Node,

        # The command table, for help.
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Table,

        # The repo root.
        [Parameter(Mandatory)]
        [string]$Root,

        # This is the run that a change of privilege started.
        [switch]$Hopped
    )

    $definition = $Node.Definition
    $code = 0
    if (-not $Hopped) {
        foreach ($dependency in $Node.DependsOn) {
            Invoke-WinfilesNode -Node $dependency -Table $Table -Root $Root
            $code = $LASTEXITCODE
            if ($code) {
                break
            }
        }
    }

    if (-not $code) {
        $log = if (-not $Hopped) { $definition.log }
        if ($log) {
            $started = Expand-WinfilesText -Text $log.started -Value $Node.Values
            Write-WinfilesLog -Phase $log.phase -Message $started
        }

        $helper = if (-not $Hopped) {
            $elevated = Test-WinfilesElevated
            if ($definition.privilege -eq 'admin' -and -not $elevated) {
                'Invoke-AsAdmin.ps1'
            } elseif ($definition.privilege -eq 'user' -and $elevated) {
                'Invoke-AsUser.ps1'
            }
        }

        if ($helper) {
            if ($helper -eq 'Invoke-AsAdmin.ps1' -and $definition.uacMessage) {
                Write-Host -Object (Expand-WinfilesText -Text $definition.uacMessage -Value $Node.Values)
            }
            $runner = Join-Path -Path $Root -ChildPath 'winfiles.ps1'
            $command = @('pwsh', '-NoLogo', '-NoProfile', '-File', $runner, '--run', $Node.Name) + $Node.Arguments
            & (Join-Path -Path $Root -ChildPath "scripts/$helper") @command
            $code = $LASTEXITCODE
        } else {
            foreach ($step in $Node.Steps) {
                Invoke-WinfilesNode -Node $step -Table $Table -Root $Root
                $code = $LASTEXITCODE
                if ($code) {
                    break
                }
            }
            if (-not $code -and $definition.script) {
                $templates = @(Get-WinfilesList -Definition $definition -Field args)
                $scriptArguments = @($templates | ForEach-Object -Process {
                        Expand-WinfilesText -Text $_ -Value $Node.Values
                    }) + $Node.Extra
                $pwshArguments = @(Get-WinfilesList -Definition $definition -Field pwshArgs)
                $script = Join-Path -Path $Root -ChildPath $definition.script
                & pwsh -NoLogo -NoProfile @pwshArguments -File $script @scriptArguments
                $code = $LASTEXITCODE
            } elseif (-not $code -and $definition.builtin -eq 'hosts') {
                Get-WinfilesHost -Root $Root
            } elseif (-not $code -and $definition.builtin -eq 'help') {
                Show-WinfilesHelp -Table $Table -Name $Node.Values.command -Root $Root
            }
        }

        if ($log -and -not $code) {
            $finished = Expand-WinfilesText -Text $log.finished -Value $Node.Values
            Write-WinfilesLog -Phase $log.phase -Message $finished
        }
    }
    $global:LASTEXITCODE = $code
}


function Invoke-WinfilesCommand {
    <#
    .SYNOPSIS
    Runs a command from the table by name, as winfiles.ps1 does, leaving its exit code in $LASTEXITCODE.

    .DESCRIPTION
    Checks the files the whole plan requires before anything runs, so a missing configuration stops it before any
    UAC prompt. Then, when anything in the plan has `clean`, runs `winfiles.ps1 --clean` through Invoke-Clean.ps1,
    once for the whole run, and otherwise runs the command here.

    .EXAMPLE
    Invoke-WinfilesCommand -Root . -Table $table -Name check -Argument iris
    #>
    [CmdletBinding()]
    param(
        # The repo root.
        [Parameter(Mandatory)]
        [string]$Root,

        # The command table, from Read-WinfilesCommand.
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Table,

        # The command.
        [Parameter(Mandatory)]
        [string]$Name,

        # Its arguments, in order.
        [AllowEmptyCollection()]
        [string[]]$Argument = @(),

        # Where this run is: started by a person (Outer), inside Invoke-Clean.ps1 (Clean), or after a change of
        # privilege (Run).
        [ValidateSet('Outer', 'Clean', 'Run')]
        [string]$Mode = 'Outer'
    )

    $node = Resolve-WinfilesCommand -Table $Table -Name $Name -Argument $Argument
    $missing = @(Get-WinfilesRequirement -Node $node | Where-Object -FilterScript {
            -not (Test-Path -LiteralPath (Join-Path -Path $Root -ChildPath $_))
        })
    $clean = @(Get-WinfilesNode -Node $node | Where-Object -FilterScript { $_.Definition.clean })

    if ($missing) {
        foreach ($file in $missing) {
            [Console]::Error.WriteLine("No configuration at $file.")
        }
        [Console]::Error.WriteLine('These exist:')
        Get-WinfilesHost -Root $Root
        $global:LASTEXITCODE = 1
    } elseif ($Mode -eq 'Outer' -and $clean) {
        $runner = Join-Path -Path $Root -ChildPath 'winfiles.ps1'
        $command = @('pwsh', '-NoLogo', '-NoProfile', '-File', $runner, '--clean', $Name) + $Argument
        & (Join-Path -Path $Root -ChildPath 'scripts/Invoke-Clean.ps1') @command
    } else {
        Invoke-WinfilesNode -Node $node -Table $Table -Root $Root -Hopped:($Mode -eq 'Run')
    }
}


function Get-WinfilesUsage {
    <#
    .SYNOPSIS
    Returns a command's usage line: its name, its parameters, and [arguments...] when it passes more on.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The command.
        [Parameter(Mandatory)]
        [string]$Name,

        # Its definition, from the table.
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Definition
    )

    $parts = @($Name) + @(Get-WinfilesList -Definition $Definition -Field parameters | ForEach-Object -Process {
            if ($_.Contains('default')) { "[$($_.name)]" } else { "<$($_.name)>" }
        })
    if ($Definition.passArgs) {
        $parts += '[arguments...]'
    }
    $parts -join ' '
}


function Show-WinfilesCommand {
    <#
    .SYNOPSIS
    Lists the commands that aren't private, by group, with their usage and description.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The command table, from Read-WinfilesCommand.
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Table
    )

    $listed = foreach ($name in $Table.Keys) {
        $definition = $Table[$name]
        if (-not $definition.private) {
            [pscustomobject]@{
                Group       = [string]$definition.group
                Usage       = Get-WinfilesUsage -Name $name -Definition $definition
                Description = $definition.description
            }
        }
    }
    $width = ($listed.Usage | Measure-Object -Property Length -Maximum).Maximum
    'Commands (./winfiles.ps1 <command> [arguments]):'
    $groups = @($listed.Group | Select-Object -Unique | Sort-Object -Property { [bool]$_ } -Stable)
    foreach ($group in $groups) {
        if ($group) {
            ''
            "    [$group]"
        }
        foreach ($command in $listed | Where-Object -Property Group -EQ -Value $group) {
            '    {0} # {1}' -f $command.Usage.PadRight($width), $command.Description
        }
    }
}


function Format-SyntaxParameter {
    <#
    .SYNOPSIS
    Formats a parameter as Get-Help writes it: brackets around an optional parameter, and around the name of a
    positional one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The parameter, from the help's syntax data.
        [Parameter(Mandatory)]
        [object]$Parameter
    )

    $name = "-$($Parameter.name)"
    if ($Parameter.position -ne 'named') {
        $name = "[$name]"
    }
    if ($Parameter.parameterValue) {
        $name += " <$($Parameter.parameterValue)>"
    }
    if ($Parameter.required -eq 'true') { $name } else { "[$name]" }
}


function Format-WinfilesScriptHelp {
    <#
    .SYNOPSIS
    Returns a script's Get-Help text, with its own name for its path and SYNTAX one parameter per line.

    .DESCRIPTION
    Get-Help names a script by its full path. That's cut to the file name, except in the Get-Help commands under
    REMARKS, which get ./scripts/ so they run from the repo root. SYNTAX is rebuilt from the help's syntax data
    with one parameter per line, in Get-Help's notation, since Get-Help has no option for it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The script.
        [Parameter(Mandatory)]
        [string]$Path
    )

    $full = [IO.Path]::GetFullPath($Path)
    $folder = [regex]::Escape((Split-Path -Path $full) + '\')
    $help = Get-Help -Name $full
    $text = ($help | Out-String) -replace "Get-Help $folder", 'Get-Help ./scripts/' -replace $folder, ''
    $lines = $text -split '\r?\n'

    # SYNTAX runs from its heading to the next one; its blank lines stay, its syntax lines are replaced
    $start = [array]::IndexOf($lines, 'SYNTAX')
    if ($start -ge 0) {
        $end = $start + 1
        while ($end -lt $lines.Count -and $lines[$end] -notmatch '^[A-Z][A-Z ]*$') {
            $end++
        }
        $section = $lines[($start + 1)..($end - 1)]
        $common = $section -match '\[<CommonParameters>\]'
        $syntax = foreach ($item in $help.syntax.syntaxItem) {
            '    ' + (Split-Path -Path $item.name -Leaf)
            foreach ($parameter in $item.parameter) {
                '        ' + (Format-SyntaxParameter -Parameter $parameter)
            }
            if ($common) {
                '        [<CommonParameters>]'
            }
        }
        $blank = @($section | Where-Object -FilterScript { $_ -notmatch '\S' })
        $lines = @($lines[0..$start]) + @($syntax) + $blank + @($lines[$end..($lines.Count - 1)])
    }
    $lines
}


function Show-WinfilesHelp {
    <#
    .SYNOPSIS
    Shows a command's usage, description and defaults, then the help of the script its extra arguments go to.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The command table, from Read-WinfilesCommand.
        [Parameter(Mandatory)]
        [Collections.IDictionary]$Table,

        # The command.
        [Parameter(Mandatory)]
        [string]$Name,

        # The repo root.
        [Parameter(Mandatory)]
        [string]$Root
    )

    if (-not $Table.Contains($Name)) {
        throw [ArgumentException]::new("There's no command named '$Name'. ./winfiles.ps1 lists them.")
    }
    $definition = $Table[$Name]
    "Usage: ./winfiles.ps1 $(Get-WinfilesUsage -Name $Name -Definition $definition)"
    if ($definition.description) {
        "    $($definition.description)"
    }
    foreach ($parameter in Get-WinfilesList -Definition $definition -Field parameters) {
        if ($parameter.Contains('default')) {
            "    $($parameter.name): default $($parameter.default)"
        }
    }
    if ($definition.passArgs -and $definition.script) {
        ''
        Format-WinfilesScriptHelp -Path (Join-Path -Path $Root -ChildPath $definition.script)
    }
}
