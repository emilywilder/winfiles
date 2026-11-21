#Requires -Version 7.5

<#
.SYNOPSIS
Writes a DSC configuration with each Include replaced by the resources of the document it includes, as one YAML
document.

.DESCRIPTION
just system, home and check run the result (through Get-RunDocument in dsclog.ps1), and just flatten writes it on its
own. A single dsc process then runs every resource, and its progress bar names each one
("37/54 Set 'Malwarebytes.Malwarebytes'"), where through an Include it only names the Include, and the dsc that runs
the included document draws no bar of its own.
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
configuration format. A resource takes its own tag, else its document's, else that of the document that includes it,
so tagging an entry covers everything it includes; untagged resources are the user's. An Include can't carry a tag.
Only 'elevated' is accepted. The tag is taken out of the result, since dsc hands a resource its metadata, and the
resources that are tested as a whole would count it as a difference (put those in a tagged document instead).
Nothing in a document says what needs a restart: a resource reports that to dsc itself (`_restartRequired`), and
Invoke-Configuration.ps1 passes what reported it to -First.

.PARAMETER File
The entry document, or several, which make one aggregate: their resources in the order given, the first one's header,
and everything flattened together, so resource and parameter names must be unique across them. A later entry's
resources come after an earlier one's wherever dependsOn doesn't say otherwise. A dependsOn can't name another
entry's resources.

.PARAMETER Destination
Where to write the result. By default, ~/.local/state/winfiles/flat/<the file's name>, where just system, home and
check write it, so `just dsc config test --file <it>` runs what they run.

.PARAMETER Batch
Write the resources as batches instead, each a flat document of consecutive resources of one level, and print an
object with the Path, Level ('elevated' or 'user'), Stage ('restart' for the batch -First asks for, otherwise '') and
Resources count of each, in the order to run them. Their names
are the destination's with the batch's number and level before .dsc.yaml (entry.1-elevated.dsc.yaml). The order keeps
every dependsOn, with as few batches as it allows; a dependsOn on a resource in an earlier batch is dropped, since
running them in order satisfies it, and each batch has only the parameters its resources use. An earlier run's batch
files for the same destination are deleted first.

.PARAMETER First
With -Batch: resources to run before everything else, as `<type>|<name>` entries separated by `;`. They and what they
depend on, at any depth, make the first batch, whose Stage is 'restart' (what Invoke-Configuration.ps1 found reporting
a restart, which has to happen before anything installs). They must all be elevated.

.EXAMPLE
./scripts/ConvertTo-FlatConfiguration.ps1 dsc/emily@iris.home.dsc.yaml
#>
param(
    [Parameter(Mandatory)]
    [string[]]$File,
    [string]$Destination = (Join-Path $env:USERPROFILE ".local\state\winfiles\flat\$(Split-Path $File[0] -Leaf)"),
    [switch]$Batch,
    [string]$First = ''
)

$ErrorActionPreference = 'Stop'

$include = 'Microsoft.DSC/Include'
$documentKeys = '$schema', 'metadata', 'parameters', 'resources'

function Invoke-Yq {
    param([string[]]$Arguments, [string]$InputText)
    $output = if ($PSBoundParameters.ContainsKey('InputText')) { $InputText | & yq @Arguments } else { & yq @Arguments }
    if ($LASTEXITCODE) { throw "yq $Arguments failed with exit code $LASTEXITCODE" }
    $output -join "`n"
}

# An object's properties; none for $null, whose PSObject.Properties isn't empty
function Get-Property($Object) {
    if ($null -ne $Object) { $Object.PSObject.Properties }
}

function Read-Document([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "${File}: $Path doesn't exist" }
    $document = Invoke-Yq -Arguments '-o', 'json', '.', $Path | ConvertFrom-Json -DateKind String
    $unknown = @(Get-Property $document | ForEach-Object Name | Where-Object { $_ -notin $documentKeys })
    if ($unknown) { throw "${File}: $Path has $($unknown -join ', '), which flattening doesn't handle" }
    $document
}

# The (type, name) a dependsOn entry names. Only resourceId() is used in winfiles
function Get-Dependency([string]$Expression) {
    if ($Expression -notmatch "^\[resourceId\('([^']+)',\s*'([^']+)'\)\]$") {
        throw "${File}: dependsOn '$Expression' isn't a resourceId('<type>', '<name>'), which flattening doesn't handle"
    }
    [pscustomobject]@{ Type = $Matches[1]; Name = $Matches[2] }
}

# The level a resource or Include asks for with metadata.winget.securityContext, the name Microsoft's configuration
# format gives it: 'elevated', or nothing. Anything else fails
function Get-SecurityContext($Resource, [string]$Label) {
    $value = $Resource.metadata.winget.securityContext
    if ($null -eq $value) { return }
    if ($value -ne 'elevated') {
        throw "${File}: $Label has securityContext '$value', and only 'elevated' is handled"
    }
    $value
}

# dsc passes a resource's metadata on to it, and the resources that are checked as a whole count it as a difference
# (see the description notes in CLAUDE.md), so the tag is taken out once read. metadata and winget go too when empty
function Remove-Tag($Resource) {
    $owner = $Resource.metadata.winget
    if ($null -ne $owner -and $owner.PSObject.Properties.Name -contains 'securityContext') {
        $owner.PSObject.Properties.Remove('securityContext')
        if (-not @($owner.PSObject.Properties).Count) { $Resource.metadata.PSObject.Properties.Remove('winget') }
    }
    if ($null -ne $Resource.metadata -and -not @($Resource.metadata.PSObject.Properties).Count) {
        $Resource.PSObject.Properties.Remove('metadata')
    }
}

# More than one entry makes one aggregate, in the order given: what a later one lists comes after what an earlier one
# does, where dependsOn can't reach (it names resources of its own document). The first one's header heads the result
$entries = @($File)
$File = $entries -join ' and '
$entry = Read-Document $entries[0]
$parameters = [ordered]@{}
$declaredIn = @{}
# The resources, each with the Includes it sits inside (outermost first) and the Includes its own document declares,
# which its dependsOn can name
$flat = [Collections.Generic.List[object]]::new()

function Add-Parameter([string]$Name, $Declaration, [string]$Source) {
    if ($parameters.Contains($Name)) {
        throw "${File}: parameter '$Name' is declared in both $($declaredIn[$Name]) and $Source"
    }
    $parameters[$Name] = $Declaration
    $declaredIn[$Name] = $Source
}

# The included document's parameters, with the Include's parametersContent as their defaults
function Add-IncludedParameter($Resource, $Document, [string]$Path) {
    $values = $null
    if ($Resource.properties.parametersContent) {
        $content = Invoke-Yq -Arguments '-p', 'yaml', '-o', 'json', '.' `
            -InputText $Resource.properties.parametersContent |
            ConvertFrom-Json -DateKind String
        $values = $content.parameters
    }
    $given = @(Get-Property $values | ForEach-Object Name)
    $declared = @(Get-Property $Document.parameters | ForEach-Object Name)
    foreach ($name in $given) {
        if ($name -notin $declared) {
            throw "${File}: Include '$($Resource.name)' sets parameter '$name', which $Path doesn't declare"
        }
        $value = $values.$name
        # DSC takes parametersContent's values as they are; as a default, an expression would be evaluated instead
        if ($value -is [string] -and $value.StartsWith('[') -and -not $value.StartsWith('[[')) {
            throw ("${File}: Include '$($Resource.name)' sets parameter '$name' to '$value', an expression, " +
                "which flattening doesn't handle")
        }
    }
    foreach ($parameter in @(Get-Property $Document.parameters)) {
        $declaration = $parameter.Value
        if ($parameter.Name -in $given) {
            $declaration | Add-Member -Force -NotePropertyName defaultValue -NotePropertyValue $values.($parameter.Name)
        }
        Add-Parameter $parameter.Name $declaration $Path
    }
}

# Adds a document's resources to $flat, replacing each Include with the resources of what it includes, at any depth.
# $Chain is the documents being included, by full path, from the entry down: one already in it is a loop.
function Add-Document($Document, [string]$Path, [string[]]$Chain, [object[]]$Ancestors, [string]$InheritedContext) {
    # The document's own tag, else that of the document that includes it. A resource's own comes before both
    $docLabel = "document $Path"
    $docContext = Get-SecurityContext $Document $docLabel
    if (-not $docContext) { $docContext = $InheritedContext }
    # The entry's metadata heads the flat copies, so its tag goes like the resources'
    Remove-Tag $Document
    # This document's Includes by name, which dependsOn entries in it refer to
    $scope = @{}
    foreach ($resource in @($Document.resources)) {
        $label = "'$($resource.name)'"
        $context = Get-SecurityContext $resource $label
        if ($resource.type -eq $include -and $context) {
            throw ("${File}: Include '$($resource.name)' has a securityContext, " +
                'which only a document or a resource can have')
        }
        if ($resource.type -ne $include) {
            # Its own tag, else its document's. Untagged is the user's level
            $level = if ($context) { $context } else { $docContext }
            Remove-Tag $resource
            $flat.Add([pscustomobject]@{
                Resource  = $resource
                Path      = $Path
                Scope     = $scope
                Ancestors = $Ancestors
                Level     = $(if ($level) { $level } else { 'user' })
                Stage     = ''
            })
            $id = "[resourceId('$($resource.type)', '$($resource.name)')]"
            foreach ($ancestor in $Ancestors) { $ancestor.Ids.Add($id) }
            continue
        }
        $properties = $resource.properties
        $unknown = @(Get-Property $properties | ForEach-Object Name |
            Where-Object { $_ -notin 'configurationFile', 'parametersContent' })
        if ($unknown) {
            throw "${File}: Include '$($resource.name)' has $($unknown -join ', '), which flattening doesn't handle"
        }
        if (-not $properties.configurationFile) {
            throw "${File}: Include '$($resource.name)' has no configurationFile"
        }
        if ($scope.ContainsKey($resource.name)) { throw "${File}: $Path has two Includes named '$($resource.name)'" }

        $childPath = Join-Path $folder $properties.configurationFile
        $full = [IO.Path]::GetFullPath($childPath)
        if ($full -in $Chain) {
            $root = (Resolve-Path $folder).Path
            $names = @($Chain + $full | ForEach-Object { [IO.Path]::GetRelativePath($root, $_) -replace '\\', '/' })
            throw ("${File}: Include '$($resource.name)' includes a document that's already being included: " +
                ($names -join ' -> '))
        }
        $document = Read-Document $childPath
        Add-IncludedParameter $resource $document $childPath
        $node = [pscustomobject]@{
            Name      = $resource.name
            Ids      = [Collections.Generic.List[string]]::new()
            DependsOn = @($resource.dependsOn | Where-Object { $_ })
            Path      = $Path
            Scope     = $scope
        }
        $scope[$resource.name] = $node
        Add-Document $document $childPath ($Chain + $full) ($Ancestors + $node) $docContext
    }
}

foreach ($path in $entries) {
    $document = if ($path -eq $entries[0]) { $entry } else { Read-Document $path }
    # Every configurationFile resolves from its entry document's folder, nested ones too, as DSC 3.3.0 does
    $folder = Split-Path $path
    if (-not $folder) { $folder = '.' }
    foreach ($parameter in @(Get-Property $document.parameters)) {
        Add-Parameter $parameter.Name $parameter.Value $path
    }
    Add-Document $document $path @([IO.Path]::GetFullPath($path)) @() ''
}

# A dependsOn entry, with one on an Include replaced by one on each resource inside it, at any depth. An Include is
# looked up among those of the document the entry was written in
function Expand-Dependency([string]$Expression, [hashtable]$Scope, [string]$Path) {
    $dependency = Get-Dependency $Expression
    if ($dependency.Type -ne $include) { return $Expression }
    if (-not $Scope.ContainsKey($dependency.Name)) {
        throw "${File}: dependsOn names Include '$($dependency.Name)', which isn't in $Path"
    }
    $Scope[$dependency.Name].Ids
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
        $resource.dependsOn | Where-Object { $_ } | ForEach-Object { Expand-Dependency $_ $item.Scope $item.Path }
        foreach ($ancestor in $item.Ancestors) {
            $ancestor.DependsOn | ForEach-Object { Expand-Dependency $_ $ancestor.Scope $ancestor.Path }
        }
    ) | Select-Object -Unique
    if ($expanded) {
        $resource | Add-Member -Force -NotePropertyName dependsOn -NotePropertyValue @($expanded)
    } elseif ($resource.PSObject.Properties.Name -contains 'dependsOn') {
        $resource.PSObject.Properties.Remove('dependsOn')
    }
}

# A dependsOn loop, which an Include's dependsOn can make once it reaches every resource inside it. DSC refuses one
# too, but naming the resources here says where it came from
$edges = @{}
foreach ($resource in $flat.Resource) {
    $edges["[resourceId('$($resource.type)', '$($resource.name)')]"] = @($resource.dependsOn | Where-Object { $_ })
}
$state = @{}
function Find-Loop([string]$Id, [string[]]$Stack) {
    $state[$Id] = 'visiting'
    foreach ($next in $edges[$Id]) {
        if ($state[$next] -eq 'visiting') {
            $loop = @($Stack[[array]::IndexOf($Stack, $next)..($Stack.Count - 1)] + $next) -replace
                "^\[resourceId\('([^']+)', '([^']+)'\)\]$", "`$1 '`$2'"
            throw "${File}: dependsOn makes a loop: $($loop -join ' -> ')"
        }
        if (-not $state[$next] -and $edges.ContainsKey($next)) { Find-Loop $next ($Stack + $next) }
    }
    $state[$Id] = 'done'
}
foreach ($id in $edges.Keys) { if (-not $state[$id]) { Find-Loop $id @($id) } }

$header = "# Generated from $File by scripts/ConvertTo-FlatConfiguration.ps1, which replaced each Include with the" +
    "`n# resources of the document it includes. Edit the documents in dsc/, not this file."

# Writes a document of these resources, with the entry's header and the parameters they use (all of them when
# $Parameters is $null)
function Write-Flat([object[]]$Resources, [string]$Path, $Parameters) {
    $document = [ordered]@{ '$schema' = $entry.'$schema' }
    if ($entry.metadata) { $document.metadata = $entry.metadata }
    if ($Parameters.Count) { $document.parameters = $Parameters }
    $document.resources = @($Resources)
    $yaml = Invoke-Yq -Arguments '-p', 'json', '-o', 'yaml', '-P', '.' -InputText ($document | ConvertTo-Json -Depth 64)
    $null = New-Item -ItemType Directory -Force (Split-Path $Path)
    Set-Content -LiteralPath $Path -Value $header, $yaml
}

if (-not $Batch) {
    Write-Flat $flat.Resource $Destination $parameters
    return $Destination
}

# Batches: the resources in an order that keeps every dependsOn, as few runs of the same level as it allows. Kahn's
# algorithm, taking the first ready resource (in document order) of the level being run, and changing level only when
# none of it is ready. A dependsOn on a resource in an earlier batch is dropped, since the batches run in order
$ids = @{}
foreach ($item in $flat) { $ids["[resourceId('$($item.Resource.type)', '$($item.Resource.name)')]"] = $item }

# -First: those resources and everything they depend on, at any depth, are the 'restart' stage, which runs first
$queue = [Collections.Generic.Queue[string]]::new()
foreach ($spec in @($First -split ';' | Where-Object { $_ })) {
    $type, $name = $spec -split '\|', 2
    $id = "[resourceId('$type', '$name')]"
    if (-not $ids.ContainsKey($id)) { throw "${File}: -First names $type '$name', which isn't in it" }
    $queue.Enqueue($id)
}
while ($queue.Count) {
    $item = $ids[$queue.Dequeue()]
    if ($item.Stage) { continue }
    if ($item.Level -ne 'elevated') {
        throw ("${File}: $($item.Resource.type) '$($item.Resource.name)' has to come before the restart, " +
            "but isn't elevated, and only elevated resources can")
    }
    $item.Stage = 'restart'
    foreach ($dependency in @($item.Resource.dependsOn | Where-Object { $_ -and $ids.ContainsKey($_) })) {
        $queue.Enqueue($dependency)
    }
}
$finished = @{}
$remaining = [Collections.Generic.List[object]]::new($flat)
$batches = [Collections.Generic.List[object]]::new()
$level = $null
$stage = $null
while ($remaining.Count) {
    $ready = @($remaining | Where-Object {
        $item = $_
        -not @($item.Resource.dependsOn |
            Where-Object { $_ -and $ids.ContainsKey($_) -and -not $finished.ContainsKey($_) })
    })
    if (-not $ready) {
        throw "${File}: no resource is ready to run, which is a dependsOn loop the check above should have found"
    }
    # The restart stage comes first: it begins a batch as soon as any of it is ready, and is finished before the rest
    $pick = $ready | Where-Object { $_.Stage -eq 'restart' } | Select-Object -First 1
    if (-not $pick) {
        $pick = $ready | Where-Object { $_.Level -eq $level -and $_.Stage -eq $stage } | Select-Object -First 1
    }
    if (-not $pick -or $pick.Level -ne $level -or $pick.Stage -ne $stage) {
        if (-not $pick) { $pick = $ready[0] }
        $level = $pick.Level
        $stage = $pick.Stage
        $batches.Add([pscustomobject]@{
            Level = $level; Stage = $stage; Items = [Collections.Generic.List[object]]::new()
        })
    }
    $batches[-1].Items.Add($pick)
    $finished["[resourceId('$($pick.Resource.type)', '$($pick.Resource.name)')]"] = $true
    $null = $remaining.Remove($pick)
}

# Earlier batches' files for this entry go, so one with a higher number than this run's can't be run by mistake
$base = $Destination -replace '\.dsc\.yaml$'
Get-ChildItem -LiteralPath (Split-Path $Destination) -Filter "$(Split-Path $base -Leaf).*-*.dsc.yaml" `
        -ErrorAction Ignore |
    Where-Object { $_.Name -match '\.\d+-(elevated|user)\.dsc\.yaml$' } | Remove-Item

$number = 0
$inEarlier = @{}
foreach ($group in $batches) {
    $number++
    $path = "$base.$number-$($group.Level).dsc.yaml"
    $resources = foreach ($item in $group.Items) {
        $resource = $item.Resource
        $kept = @($resource.dependsOn | Where-Object { $_ -and -not $inEarlier.ContainsKey($_) })
        if ($kept) {
            $resource | Add-Member -Force -NotePropertyName dependsOn -NotePropertyValue $kept
        } elseif ($resource.PSObject.Properties.Name -contains 'dependsOn') {
            $resource.PSObject.Properties.Remove('dependsOn')
        }
        $resource
    }
    # Only the parameters these resources use, as parameters('<name>') anywhere in them
    $text = $resources | ConvertTo-Json -Depth 64 -Compress
    $used = [ordered]@{}
    foreach ($parameter in $parameters.GetEnumerator()) {
        if ($text -match "parameters\(\s*'$([regex]::Escape($parameter.Key))'\s*\)") {
            $used[$parameter.Key] = $parameter.Value
        }
    }
    Write-Flat $resources $path $used
    foreach ($item in $group.Items) {
        $inEarlier["[resourceId('$($item.Resource.type)', '$($item.Resource.name)')]"] = $true
    }
    [pscustomobject]@{
        Path = $path; Level = [string]$group.Level; Stage = [string]$group.Stage; Resources = @($resources).Count
    }
}
