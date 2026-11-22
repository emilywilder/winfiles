#Requires -Version 7.5

<#
.SYNOPSIS
Writes a DSC configuration with each Include replaced by the resources of the document it includes, as one YAML
document.

.DESCRIPTION
just system, home and check run the result (through Get-RunDocument in dsclog.ps1), and just flatten writes it on
its own. A single dsc process then runs every resource, and its progress bar names each one
("37/54 Set 'Malwarebytes.Malwarebytes'"), where through an Include it only names the Include, and the dsc that
runs the included document draws no bar of its own.
It covers what the entry documents use, and refuses anything else rather than guess:
- An Include's configurationFile, resolved from the entry document's folder, as DSC does (nested ones too), and its
  parametersContent, whose values become the defaults of the included document's parameters.
- Includes inside included documents, at any depth. A document that includes itself, directly or through others,
  fails, naming the chain.
- The included documents' parameters, merged. A parameter declared twice fails, as does a value in
  parametersContent that the document doesn't declare, or that is an expression.
- dependsOn on an Include, which becomes dependsOn on every resource inside that Include, at any depth, for each
  resource inside the dependent Include (or the resource itself, for one outside any Include). An Include is looked
  up among those of the document the dependsOn is written in. Other dependsOn entries are kept. A dependsOn loop in
  the result fails, naming the resources.
- Resource names must be unique across the result, since dsc refers to resources by type and name.
Other Include properties, and other top-level keys (variables, for example) fail. Comments aren't kept. The result
is written with yq, from mise.toml, and its path printed.
A document, or a resource, can ask for elevation with metadata.winget.securityContext: elevated, as in Microsoft's
configuration format. A resource takes its own tag, else its document's, else that of the document that includes
it, so tagging an entry covers everything it includes; untagged resources are the user's. An Include can't carry a
tag. Only 'elevated' is accepted. The tag is taken out of the result, since dsc hands a resource its metadata, and
the resources that are tested as a whole would count it as a difference (put those in a tagged document instead).
Nothing in a document says what needs a restart: a resource reports that to dsc itself (`_restartRequired`), and
Invoke-Configuration.ps1 passes what reported it to -First.

.EXAMPLE
./scripts/ConvertTo-FlatConfiguration.ps1 dsc/emily@iris.home.dsc.yaml

Writes emily@iris's home configuration as one flat document, and prints its path.
#>
[CmdletBinding()]
param(
    # The entry document, or several, which make one aggregate: their resources in the order given, the first one's
    # header, and everything flattened together, so resource and parameter names must be unique across them. A
    # later entry's resources come after an earlier one's wherever dependsOn doesn't say otherwise. A dependsOn
    # can't name another entry's resources.
    [Parameter(Mandatory, Position = 0)]
    [string[]]$File,

    # Where to write the result. By default, ~/.local/state/winfiles/flat/<the file's name>, where just system,
    # home and check write it, so `just dsc config test --file <it>` runs what they run.
    [Parameter(Position = 1)]
    [string]$Destination = (Join-Path -Path $env:USERPROFILE -ChildPath (
            ".local\state\winfiles\flat\$(Split-Path -Path $File[0] -Leaf)")),

    # Write the resources as batches instead, each a flat document of consecutive resources of one level, and print
    # an object with the Path, Level ('elevated' or 'user'), Stage ('restart' for the batch -First asks for,
    # otherwise '') and Resources count of each, in the order to run them. Their names are the destination's with
    # the batch's number and level before .dsc.yaml (entry.1-elevated.dsc.yaml). The order keeps every dependsOn,
    # with as few batches as it allows; a dependsOn on a resource in an earlier batch is dropped, since running
    # them in order satisfies it, and each batch has only the parameters its resources use. An earlier run's batch
    # files for the same destination are deleted first.
    [switch]$Batch,

    # With -Batch: resources to run before everything else, as `<type>|<name>` entries separated by `;`. They and
    # what they depend on, at any depth, make the first batch, whose Stage is 'restart' (what
    # Invoke-Configuration.ps1 found reporting a restart, which has to happen before anything installs). They must
    # all be elevated.
    [string]$First = ''
)

$ErrorActionPreference = 'Stop'
try {
    $include = 'Microsoft.DSC/Include'
    $documentKeys = '$schema', 'metadata', 'parameters', 'resources'


    function Invoke-Yq {
        <#
        .SYNOPSIS
        Runs yq, on -InputText when it's given, and returns its output as one string; throws when yq fails.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param(
            # yq's arguments.
            [Parameter(Mandatory)]
            [string[]]$Arguments,

            # Text for yq's stdin.
            [string]$InputText
        )

        $output = if ($PSBoundParameters.ContainsKey('InputText')) {
            $InputText | & yq @Arguments
        } else {
            & yq @Arguments
        }
        if ($LASTEXITCODE) {
            throw "yq $Arguments failed with exit code $LASTEXITCODE"
        }
        $output -join "`n"
    }


    function Get-Property {
        <#
        .SYNOPSIS
        Returns an object's properties, and none for $null, whose PSObject.Properties isn't empty.
        #>
        [CmdletBinding()]
        [OutputType([Management.Automation.PSPropertyInfo])]
        param(
            # The object.
            [Parameter(Position = 0)]
            [AllowNull()]
            [object]$Object
        )

        if ($null -ne $Object) {
            $Object.PSObject.Properties
        }
    }


    function Read-Document {
        <#
        .SYNOPSIS
        Reads a DSC document, failing for one that's missing or has top-level keys flattening doesn't handle.
        #>
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            # The document's path.
            [Parameter(Mandatory, Position = 0)]
            [string]$Path
        )

        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "${File}: $Path doesn't exist"
        }
        $document = Invoke-Yq -Arguments '-o', 'json', '.', $Path | ConvertFrom-Json -DateKind String
        $unknown = @(Get-Property -Object $document |
                ForEach-Object -MemberName Name |
                Where-Object -FilterScript { $_ -notin $documentKeys })
        if ($unknown) {
            throw "${File}: $Path has $($unknown -join ', '), which flattening doesn't handle"
        }
        $document
    }


    function Get-Dependency {
        <#
        .SYNOPSIS
        Returns the (type, name) a dependsOn entry names. Only resourceId() is used in winfiles.
        #>
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param(
            # The dependsOn entry.
            [Parameter(Mandatory, Position = 0)]
            [string]$Expression
        )

        if ($Expression -notmatch "^\[resourceId\('([^']+)',\s*'([^']+)'\)\]$") {
            throw ("${File}: dependsOn '$Expression' isn't a resourceId('<type>', '<name>'), " +
                "which flattening doesn't handle")
        }
        [pscustomobject]@{ Type = $Matches[1]; Name = $Matches[2] }
    }


    function Get-SecurityContext {
        <#
        .SYNOPSIS
        Returns the level a document, resource or Include asks for: 'elevated', or nothing. Anything else fails.

        .DESCRIPTION
        The level is metadata.winget.securityContext, the name Microsoft's configuration format gives it.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param(
            # The document, resource or Include.
            [Parameter(Mandatory, Position = 0)]
            [object]$Resource,

            # What to call it in an error.
            [Parameter(Mandatory, Position = 1)]
            [string]$Label
        )

        $value = $Resource.metadata.winget.securityContext
        if ($null -ne $value -and $value -ne 'elevated') {
            throw "${File}: $Label has securityContext '$value', and only 'elevated' is handled"
        }
        $value
    }


    function Remove-Tag {
        <#
        .SYNOPSIS
        Takes metadata.winget.securityContext out of a document or resource, and metadata and winget when left
        empty.

        .DESCRIPTION
        dsc passes a resource's metadata on to it, and the resources that are checked as a whole count it as a
        difference (see the description notes in CLAUDE.md), so the tag is taken out once read. This changes the
        object in memory only.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'It changes an object in memory, not the system')]
        [CmdletBinding()]
        param(
            # The document or resource.
            [Parameter(Mandatory, Position = 0)]
            [object]$Resource
        )

        $owner = $Resource.metadata.winget
        if ($null -ne $owner -and $owner.PSObject.Properties.Name -contains 'securityContext') {
            $owner.PSObject.Properties.Remove('securityContext')
            if (-not @($owner.PSObject.Properties).Count) {
                $Resource.metadata.PSObject.Properties.Remove('winget')
            }
        }
        if ($null -ne $Resource.metadata -and -not @($Resource.metadata.PSObject.Properties).Count) {
            $Resource.PSObject.Properties.Remove('metadata')
        }
    }


    # More than one entry makes one aggregate, in the order given: what a later one lists comes after what an
    # earlier one does, where dependsOn can't reach (it names resources of its own document). The first one's
    # header heads the result
    $entries = @($File)
    $File = $entries -join ' and '
    $entry = Read-Document -Path $entries[0]
    $parameters = [ordered]@{}
    $declaredIn = @{}
    # The resources, each with the Includes it sits inside (outermost first) and the Includes its own document
    # declares, which its dependsOn can name
    $flat = [Collections.Generic.List[object]]::new()


    function Add-Parameter {
        <#
        .SYNOPSIS
        Adds a parameter declaration to the result's, failing for one declared already.
        #>
        [CmdletBinding()]
        param(
            # The parameter's name.
            [Parameter(Mandatory, Position = 0)]
            [string]$Name,

            # Its declaration.
            [Parameter(Mandatory, Position = 1)]
            [object]$Declaration,

            # The document that declares it.
            [Parameter(Mandatory, Position = 2)]
            [string]$Source
        )

        if ($parameters.Contains($Name)) {
            throw "${File}: parameter '$Name' is declared in both $($declaredIn[$Name]) and $Source"
        }
        $parameters[$Name] = $Declaration
        $declaredIn[$Name] = $Source
    }


    function Add-IncludedParameter {
        <#
        .SYNOPSIS
        Adds the included document's parameters, with the Include's parametersContent as their defaults.
        #>
        [CmdletBinding()]
        param(
            # The Include.
            [Parameter(Mandatory, Position = 0)]
            [object]$Resource,

            # The document it includes.
            [Parameter(Mandatory, Position = 1)]
            [object]$Document,

            # That document's path.
            [Parameter(Mandatory, Position = 2)]
            [string]$Path
        )

        $values = $null
        if ($Resource.properties.parametersContent) {
            $yq = @{
                Arguments = '-p', 'yaml', '-o', 'json', '.'
                InputText = $Resource.properties.parametersContent
            }
            $values = (Invoke-Yq @yq | ConvertFrom-Json -DateKind String).parameters
        }
        $given = @(Get-Property -Object $values | ForEach-Object -MemberName Name)
        $declared = @(Get-Property -Object $Document.parameters | ForEach-Object -MemberName Name)
        foreach ($name in $given) {
            if ($name -notin $declared) {
                throw "${File}: Include '$($Resource.name)' sets parameter '$name', which $Path doesn't declare"
            }
            $value = $values.$name
            # DSC takes parametersContent's values as they are; as a default, an expression would be evaluated
            # instead
            if ($value -is [string] -and $value.StartsWith('[') -and -not $value.StartsWith('[[')) {
                throw ("${File}: Include '$($Resource.name)' sets parameter '$name' to '$value', an expression, " +
                    "which flattening doesn't handle")
            }
        }
        foreach ($parameter in @(Get-Property -Object $Document.parameters)) {
            $declaration = $parameter.Value
            if ($parameter.Name -in $given) {
                $default = @{ NotePropertyName = 'defaultValue'; NotePropertyValue = $values.($parameter.Name) }
                Add-Member -InputObject $declaration -Force @default
            }
            Add-Parameter -Name $parameter.Name -Declaration $declaration -Source $Path
        }
    }


    function Add-Document {
        <#
        .SYNOPSIS
        Adds a document's resources to the result, replacing each Include with the resources of what it includes,
        at any depth.
        #>
        [CmdletBinding()]
        param(
            # The document.
            [Parameter(Mandatory, Position = 0)]
            [object]$Document,

            # Its path.
            [Parameter(Mandatory, Position = 1)]
            [string]$Path,

            # The documents being included, by full path, from the entry down: one already in it is a loop.
            [Parameter(Mandatory, Position = 2)]
            [string[]]$Chain,

            # The Includes it sits inside, outermost first.
            [Parameter(Position = 3)]
            [AllowEmptyCollection()]
            [object[]]$Ancestors = @(),

            # The level of the document that includes it.
            [Parameter(Position = 4)]
            [AllowEmptyString()]
            [string]$InheritedContext = ''
        )

        # The document's own tag, else that of the document that includes it. A resource's own comes before both
        $docContext = Get-SecurityContext -Resource $Document -Label "document $Path"
        if (-not $docContext) {
            $docContext = $InheritedContext
        }
        # The entry's metadata heads the flat copies, so its tag goes like the resources'
        Remove-Tag -Resource $Document
        # This document's Includes by name, which dependsOn entries in it refer to
        $scope = @{}
        foreach ($resource in @($Document.resources | Where-Object -FilterScript { $null -ne $_ })) {
            $context = Get-SecurityContext -Resource $resource -Label "'$($resource.name)'"
            if ($resource.type -eq $include -and $context) {
                throw ("${File}: Include '$($resource.name)' has a securityContext, " +
                    'which only a document or a resource can have')
            }
            if ($resource.type -ne $include) {
                # Its own tag, else its document's. Untagged is the user's level
                $level = if ($context) { $context } elseif ($docContext) { $docContext } else { 'user' }
                Remove-Tag -Resource $resource
                $flat.Add([pscustomobject]@{
                        Resource  = $resource
                        Path      = $Path
                        Scope     = $scope
                        Ancestors = $Ancestors
                        Level     = $level
                        Stage     = ''
                    })
                $id = "[resourceId('$($resource.type)', '$($resource.name)')]"
                foreach ($ancestor in $Ancestors) {
                    $ancestor.Ids.Add($id)
                }
                continue
            }
            $properties = $resource.properties
            $unknown = @(Get-Property -Object $properties |
                    ForEach-Object -MemberName Name |
                    Where-Object -FilterScript { $_ -notin 'configurationFile', 'parametersContent' })
            if ($unknown) {
                $names = $unknown -join ', '
                throw "${File}: Include '$($resource.name)' has $names, which flattening doesn't handle"
            }
            if (-not $properties.configurationFile) {
                throw "${File}: Include '$($resource.name)' has no configurationFile"
            }
            if ($scope.ContainsKey($resource.name)) {
                throw "${File}: $Path has two Includes named '$($resource.name)'"
            }

            $childPath = Join-Path -Path $folder -ChildPath $properties.configurationFile
            $full = [IO.Path]::GetFullPath($childPath)
            if ($full -in $Chain) {
                $root = (Resolve-Path -Path $folder).Path
                $names = @($Chain + $full | ForEach-Object -Process {
                        [IO.Path]::GetRelativePath($root, $_) -replace '\\', '/'
                    })
                throw ("${File}: Include '$($resource.name)' includes a document that's already being included: " +
                    ($names -join ' -> '))
            }
            $included = Read-Document -Path $childPath
            Add-IncludedParameter -Resource $resource -Document $included -Path $childPath
            $node = [pscustomobject]@{
                Name      = $resource.name
                Ids       = [Collections.Generic.List[string]]::new()
                DependsOn = @($resource.dependsOn | Where-Object -FilterScript { $_ })
                Path      = $Path
                Scope     = $scope
            }
            $scope[$resource.name] = $node
            $child = @{
                Document         = $included
                Path             = $childPath
                Chain            = $Chain + $full
                Ancestors        = $Ancestors + $node
                InheritedContext = $docContext
            }
            Add-Document @child
        }
    }


    foreach ($path in $entries) {
        $document = if ($path -eq $entries[0]) { $entry } else { Read-Document -Path $path }
        # Every configurationFile resolves from its entry document's folder, nested ones too, as DSC 3.3.0 does
        $folder = Split-Path -Path $path
        if (-not $folder) {
            $folder = '.'
        }
        foreach ($parameter in @(Get-Property -Object $document.parameters)) {
            Add-Parameter -Name $parameter.Name -Declaration $parameter.Value -Source $path
        }
        Add-Document -Document $document -Path $path -Chain @([IO.Path]::GetFullPath($path))
    }


    function Expand-Dependency {
        <#
        .SYNOPSIS
        Returns a dependsOn entry, with one on an Include replaced by one on each resource inside it, at any depth.

        .DESCRIPTION
        An Include is looked up among those of the document the entry was written in.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param(
            # The dependsOn entry.
            [Parameter(Mandatory, Position = 0)]
            [string]$Expression,

            # The Includes of the document it was written in, by name.
            [Parameter(Mandatory, Position = 1)]
            [hashtable]$Scope,

            # That document's path.
            [Parameter(Mandatory, Position = 2)]
            [string]$Path
        )

        $dependency = Get-Dependency -Expression $Expression
        if ($dependency.Type -ne $include) {
            $Expression
        } elseif (-not $Scope.ContainsKey($dependency.Name)) {
            throw "${File}: dependsOn names Include '$($dependency.Name)', which isn't in $Path"
        } else {
            $Scope[$dependency.Name].Ids
        }
    }


    $seen = @{}
    foreach ($item in $flat) {
        $resource = $item.Resource
        $source = if ($item.Ancestors) { "Include '$($item.Ancestors[-1].Name)'" } else { $item.Path }
        if ($seen.ContainsKey($resource.name)) {
            throw "${File}: resource name '$($resource.name)' is used in both $($seen[$resource.name]) and $source"
        }
        $seen[$resource.name] = $source

        # Its own dependsOn, then each surrounding Include's, each read in the document it was written in
        $expanded = @(
            $resource.dependsOn |
                Where-Object -FilterScript { $_ } |
                ForEach-Object -Process { Expand-Dependency -Expression $_ -Scope $item.Scope -Path $item.Path }
                foreach ($ancestor in $item.Ancestors) {
                    $ancestor.DependsOn | ForEach-Object -Process {
                        Expand-Dependency -Expression $_ -Scope $ancestor.Scope -Path $ancestor.Path
                    }
                }
            ) | Select-Object -Unique
            if ($expanded) {
                $dependsOn = @{ NotePropertyName = 'dependsOn'; NotePropertyValue = @($expanded) }
                Add-Member -InputObject $resource -Force @dependsOn
            } elseif ($resource.PSObject.Properties.Name -contains 'dependsOn') {
                $resource.PSObject.Properties.Remove('dependsOn')
            }
        }

        # A dependsOn loop, which an Include's dependsOn can make once it reaches every resource inside it. DSC
        # refuses one too, but naming the resources here says where it came from
        $edges = @{}
        foreach ($resource in $flat.Resource) {
            $edges["[resourceId('$($resource.type)', '$($resource.name)')]"] = @(
                $resource.dependsOn | Where-Object -FilterScript { $_ })
        }
        $state = @{}


        function Find-Loop {
            <#
        .SYNOPSIS
        Fails, naming the resources, if a dependsOn loop starts from a resource; a depth-first search.
        #>
            [CmdletBinding()]
            param(
                # The resource's id, as resourceId() writes it.
                [Parameter(Mandatory, Position = 0)]
                [string]$Id,

                # The ids on the way to it.
                [Parameter(Mandatory, Position = 1)]
                [string[]]$Stack
            )

            $state[$Id] = 'visiting'
            foreach ($next in $edges[$Id]) {
                if ($state[$next] -eq 'visiting') {
                    $loop = (@($Stack[[array]::IndexOf($Stack, $next)..($Stack.Count - 1)] + $next) -replace
                        "^\[resourceId\('([^']+)', '([^']+)'\)\]$", "`$1 '`$2'")
                    throw "${File}: dependsOn makes a loop: $($loop -join ' -> ')"
                }
                if (-not $state[$next] -and $edges.ContainsKey($next)) {
                    Find-Loop -Id $next -Stack ($Stack + $next)
                }
            }
            $state[$Id] = 'done'
        }


        foreach ($id in $edges.Keys) {
            if (-not $state[$id]) {
                Find-Loop -Id $id -Stack @($id)
            }
        }

        $header = (
            "# Generated from $File by scripts/ConvertTo-FlatConfiguration.ps1, " +
            "which replaced each Include with the`n" +
            '# resources of the document it includes. Edit the documents in dsc/, not this file.')


        function Write-Flat {
            <#
        .SYNOPSIS
        Writes a document of these resources, with the entry's header and the parameters they use.
        #>
            [CmdletBinding()]
            param(
                # The resources.
                [Parameter(Mandatory, Position = 0)]
                [AllowEmptyCollection()]
                [object[]]$Resources,

                # Where to write it.
                [Parameter(Mandatory, Position = 1)]
                [string]$Path,

                # The parameters, by name.
                [Parameter(Mandatory, Position = 2)]
                [AllowEmptyCollection()]
                [Collections.IDictionary]$Parameters
            )

            $document = [ordered]@{ '$schema' = $entry.'$schema' }
            if ($entry.metadata) {
                $document.metadata = $entry.metadata
            }
            if ($Parameters.Count) {
                $document.parameters = $Parameters
            }
            $document.resources = @($Resources)
            $json = ConvertTo-Json -InputObject $document -Depth 64
            $yaml = Invoke-Yq -Arguments '-p', 'json', '-o', 'yaml', '-P', '.' -InputText $json
            $null = New-Item -ItemType Directory -Force -Path (Split-Path -Path $Path)
            Set-Content -LiteralPath $Path -Value $header, $yaml
        }


        if (-not $Batch) {
            Write-Flat -Resources $flat.Resource -Path $Destination -Parameters $parameters
            $Destination
            exit 0
        }

        # Batches: the resources in an order that keeps every dependsOn, as few runs of the same level as it
        # allows. Kahn's algorithm, taking the first ready resource (in document order) of the level being run, and
        # changing level only when none of it is ready. A dependsOn on a resource in an earlier batch is dropped,
        # since the batches run in order
        $ids = @{}
        foreach ($item in $flat) {
            $ids["[resourceId('$($item.Resource.type)', '$($item.Resource.name)')]"] = $item
        }

        # -First: those resources and everything they depend on, at any depth, are the 'restart' stage, which runs
        # first
        $queue = [Collections.Generic.Queue[string]]::new()
        foreach ($spec in @($First -split ';' | Where-Object -FilterScript { $_ })) {
            $type, $name = $spec -split '\|', 2
            $id = "[resourceId('$type', '$name')]"
            if (-not $ids.ContainsKey($id)) {
                throw "${File}: -First names $type '$name', which isn't in it"
            }
            $queue.Enqueue($id)
        }
        while ($queue.Count) {
            $item = $ids[$queue.Dequeue()]
            if ($item.Stage) {
                continue
            }
            if ($item.Level -ne 'elevated') {
                $resource = "$($item.Resource.type) '$($item.Resource.name)'"
                throw ("${File}: $resource has to come before the restart, " +
                    "but isn't elevated, and only elevated resources can")
            }
            $item.Stage = 'restart'
            $dependencies = @($item.Resource.dependsOn |
                    Where-Object -FilterScript { $_ -and $ids.ContainsKey($_) })
        foreach ($dependency in $dependencies) {
            $queue.Enqueue($dependency)
        }
    }
    $finished = @{}
    $remaining = [Collections.Generic.List[object]]::new($flat)
    $batches = [Collections.Generic.List[object]]::new()
    $level = $null
    $stage = $null
    while ($remaining.Count) {
        $ready = @($remaining | Where-Object -FilterScript {
                $item = $_
                -not @($item.Resource.dependsOn | Where-Object -FilterScript {
                        $_ -and $ids.ContainsKey($_) -and -not $finished.ContainsKey($_)
                    })
            })
        if (-not $ready) {
            throw ("${File}: no resource is ready to run, " +
                'which is a dependsOn loop the check above should have found')
        }
        # The restart stage comes first: it begins a batch as soon as any of it is ready, and is finished
        # before the rest
        $pick = $ready | Where-Object -FilterScript { $_.Stage -eq 'restart' } | Select-Object -First 1
        if (-not $pick) {
            $pick = $ready |
                Where-Object -FilterScript { $_.Level -eq $level -and $_.Stage -eq $stage } |
                Select-Object -First 1
        }
        if (-not $pick -or $pick.Level -ne $level -or $pick.Stage -ne $stage) {
            if (-not $pick) {
                $pick = $ready[0]
            }
            $level = $pick.Level
            $stage = $pick.Stage
            $batches.Add([pscustomobject]@{
                    Level = $level
                    Stage = $stage
                    Items = [Collections.Generic.List[object]]::new()
                })
        }
        $batches[-1].Items.Add($pick)
        $finished["[resourceId('$($pick.Resource.type)', '$($pick.Resource.name)')]"] = $true
        $null = $remaining.Remove($pick)
    }

    # Earlier batches' files for this entry go, so one with a higher number than this run's can't be run by mistake
    $base = $Destination -replace '\.dsc\.yaml$'
    $earlier = @{
        LiteralPath = Split-Path -Path $Destination
        Filter      = "$(Split-Path -Path $base -Leaf).*-*.dsc.yaml"
        ErrorAction = 'Ignore'
    }
    Get-ChildItem @earlier |
        Where-Object -FilterScript { $_.Name -match '\.\d+-(elevated|user)\.dsc\.yaml$' } |
        Remove-Item

    $number = 0
    $inEarlier = @{}
    foreach ($group in $batches) {
        $number++
        $path = "$base.$number-$($group.Level).dsc.yaml"
        $resources = foreach ($item in $group.Items) {
            $resource = $item.Resource
            $kept = @($resource.dependsOn | Where-Object -FilterScript { $_ -and -not $inEarlier.ContainsKey($_) })
            if ($kept) {
                Add-Member -InputObject $resource -Force -NotePropertyName dependsOn -NotePropertyValue $kept
            } elseif ($resource.PSObject.Properties.Name -contains 'dependsOn') {
                $resource.PSObject.Properties.Remove('dependsOn')
            }
            $resource
        }
        # Only the parameters these resources use, as parameters('<name>') anywhere in them
        $text = ConvertTo-Json -InputObject @($resources) -Depth 64 -Compress
        $used = [ordered]@{}
        foreach ($parameter in $parameters.GetEnumerator()) {
            if ($text -match "parameters\(\s*'$([regex]::Escape($parameter.Key))'\s*\)") {
                $used[$parameter.Key] = $parameter.Value
            }
        }
        Write-Flat -Resources $resources -Path $path -Parameters $used
        foreach ($item in $group.Items) {
            $inEarlier["[resourceId('$($item.Resource.type)', '$($item.Resource.name)')]"] = $true
        }
        [pscustomobject]@{
            Path      = $path
            Level     = [string]$group.Level
            Stage     = [string]$group.Stage
            Resources = @($resources).Count
        }
    }
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
