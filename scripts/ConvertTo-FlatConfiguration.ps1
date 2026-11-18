#Requires -Version 7.5

<#
.SYNOPSIS
Writes a DSC configuration with each Include replaced by the resources of the document it includes, as one YAML document.

.DESCRIPTION
Set-Winfiles.ps1 applies the result, so a single dsc process runs every resource and its progress bar names each one
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
is written with yq, from mise.toml.

.EXAMPLE
./scripts/ConvertTo-FlatConfiguration.ps1 dsc/emily@iris.home.dsc.yaml ~/.local/state/winfiles/flat/emily@iris.home.dsc.yaml
#>
param(
    [Parameter(Mandatory)]
    [string]$File,
    [Parameter(Mandatory)]
    [string]$Destination
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

$entry = Read-Document $File
# Every configurationFile resolves from the entry document's folder, nested ones too, as DSC 3.3.0 does
$folder = Split-Path $File
if (-not $folder) { $folder = '.' }
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
        $content = Invoke-Yq -Arguments '-p', 'yaml', '-o', 'json', '.' -InputText $Resource.properties.parametersContent |
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
            throw "${File}: Include '$($Resource.name)' sets parameter '$name' to '$value', an expression, which flattening doesn't handle"
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
function Add-Document($Document, [string]$Path, [string[]]$Chain, [object[]]$Ancestors) {
    # This document's Includes by name, which dependsOn entries in it refer to
    $scope = @{}
    foreach ($resource in @($Document.resources)) {
        if ($resource.type -ne $include) {
            $flat.Add([pscustomobject]@{ Resource = $resource; Path = $Path; Scope = $scope; Ancestors = $Ancestors })
            $id = "[resourceId('$($resource.type)', '$($resource.name)')]"
            foreach ($ancestor in $Ancestors) { $ancestor.Ids.Add($id) }
            continue
        }
        $properties = $resource.properties
        $unknown = @(Get-Property $properties | ForEach-Object Name | Where-Object { $_ -notin 'configurationFile', 'parametersContent' })
        if ($unknown) { throw "${File}: Include '$($resource.name)' has $($unknown -join ', '), which flattening doesn't handle" }
        if (-not $properties.configurationFile) { throw "${File}: Include '$($resource.name)' has no configurationFile" }
        if ($scope.ContainsKey($resource.name)) { throw "${File}: $Path has two Includes named '$($resource.name)'" }

        $childPath = Join-Path $folder $properties.configurationFile
        $full = [IO.Path]::GetFullPath($childPath)
        if ($full -in $Chain) {
            $names = @($Chain + $full | ForEach-Object { [IO.Path]::GetRelativePath((Resolve-Path $folder).Path, $_) -replace '\\', '/' })
            throw "${File}: Include '$($resource.name)' includes a document that's already being included: $($names -join ' -> ')"
        }
        $document = Read-Document $childPath
        Add-IncludedParameter $resource $document $childPath
        $node = [pscustomobject]@{
            Name      = $resource.name
            Ids       = [Collections.Generic.List[string]]::new()
            DependsOn = @($resource.dependsOn | Where-Object { $_ })
            Path      = $Path
            Scope     = $scope
        }
        $scope[$resource.name] = $node
        Add-Document $document $childPath ($Chain + $full) ($Ancestors + $node)
    }
}

foreach ($parameter in @(Get-Property $entry.parameters)) { Add-Parameter $parameter.Name $parameter.Value $File }
Add-Document $entry $File @([IO.Path]::GetFullPath($File)) @()

# A dependsOn entry, with one on an Include replaced by one on each resource inside it, at any depth. An Include is
# looked up among those of the document the entry was written in
function Expand-Dependency([string]$Expression, [hashtable]$Scope, [string]$Path) {
    $dependency = Get-Dependency $Expression
    if ($dependency.Type -ne $include) { return $Expression }
    if (-not $Scope.ContainsKey($dependency.Name)) { throw "${File}: dependsOn names Include '$($dependency.Name)', which isn't in $Path" }
    $Scope[$dependency.Name].Ids
}

$seen = @{}
foreach ($item in $flat) {
    $resource = $item.Resource
    $source = if ($item.Ancestors) { "Include '$($item.Ancestors[-1].Name)'" } else { $File }
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
            $loop = @($Stack[[array]::IndexOf($Stack, $next)..($Stack.Count - 1)] + $next) -replace "^\[resourceId\('([^']+)', '([^']+)'\)\]$", "`$1 '`$2'"
            throw "${File}: dependsOn makes a loop: $($loop -join ' -> ')"
        }
        if (-not $state[$next] -and $edges.ContainsKey($next)) { Find-Loop $next ($Stack + $next) }
    }
    $state[$Id] = 'done'
}
foreach ($id in $edges.Keys) { if (-not $state[$id]) { Find-Loop $id @($id) } }

$result = [ordered]@{ '$schema' = $entry.'$schema' }
if ($entry.metadata) { $result.metadata = $entry.metadata }
if ($parameters.Count) { $result.parameters = $parameters }
$result.resources = @($flat.Resource)

$yaml = Invoke-Yq -Arguments '-p', 'json', '-o', 'yaml', '-P', '.' -InputText ($result | ConvertTo-Json -Depth 64)
$null = New-Item -ItemType Directory -Force (Split-Path $Destination)
$header = "# Generated from $File by scripts/ConvertTo-FlatConfiguration.ps1, which replaced each Include with the" +
    "`n# resources of the document it includes. Edit the documents in dsc/, not this file."
Set-Content -LiteralPath $Destination -Value $header, $yaml
