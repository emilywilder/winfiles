#Requires -Version 7.5

<#
.SYNOPSIS
Writes a DSC configuration with each Include replaced by the resources of the document it includes, as one YAML document.

.DESCRIPTION
Set-Winfiles.ps1 applies the result, so a single dsc process runs every resource and its progress bar names each one
("37/54 Set 'Malwarebytes.Malwarebytes'"), where through an Include it only names the Include, and the dsc that runs
the included document draws no bar of its own.
It covers what the entry documents use, and refuses anything else rather than guess:
- An Include's configurationFile, resolved from the entry document's folder, as DSC does, and its
  parametersContent, whose values become the defaults of the included document's parameters.
- The included documents' parameters, merged. A parameter declared twice fails, as does a value in
  parametersContent that the document doesn't declare.
- dependsOn on an Include, which becomes dependsOn on every resource of that Include, for each resource of the
  dependent Include (or the resource itself, for one outside any Include). Other dependsOn entries are kept.
- Resource names must be unique across the result, since dsc refers to resources by type and name.
An Include inside an included document, other Include properties, and other top-level keys (variables, for example)
fail. Comments aren't kept. The result is written with yq, from mise.toml.

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
$folder = Split-Path $File
if (-not $folder) { $folder = '.' }
$parameters = [ordered]@{}
$declaredIn = @{}
# Each Include's name, with the resourceIds of the resources it was replaced by and its own dependsOn
$includes = @{}
# The resources, each with the Include it came from ($null for one in the entry document itself)
$flat = [Collections.Generic.List[object]]::new()

function Add-Parameter([string]$Name, $Declaration, [string]$Source) {
    if ($parameters.Contains($Name)) {
        throw "${File}: parameter '$Name' is declared in both $($declaredIn[$Name]) and $Source"
    }
    $parameters[$Name] = $Declaration
    $declaredIn[$Name] = $Source
}

foreach ($parameter in @(Get-Property $entry.parameters)) { Add-Parameter $parameter.Name $parameter.Value $File }

foreach ($resource in @($entry.resources)) {
    if ($resource.type -ne $include) {
        $flat.Add([pscustomobject]@{ Resource = $resource; Include = $null })
        continue
    }
    $properties = $resource.properties
    $unknown = @(Get-Property $properties | ForEach-Object Name | Where-Object { $_ -notin 'configurationFile', 'parametersContent' })
    if ($unknown) { throw "${File}: Include '$($resource.name)' has $($unknown -join ', '), which flattening doesn't handle" }
    if (-not $properties.configurationFile) { throw "${File}: Include '$($resource.name)' has no configurationFile" }

    $path = Join-Path $folder $properties.configurationFile
    $document = Read-Document $path
    $values = $null
    if ($properties.parametersContent) {
        $content = Invoke-Yq -Arguments '-p', 'yaml', '-o', 'json', '.' -InputText $properties.parametersContent |
            ConvertFrom-Json -DateKind String
        $values = $content.parameters
    }
    $given = @(Get-Property $values | ForEach-Object Name)
    $declared = @(Get-Property $document.parameters | ForEach-Object Name)
    foreach ($parameter in @(Get-Property $document.parameters)) {
        $declaration = $parameter.Value
        if ($parameter.Name -in $given) {
            $declaration | Add-Member -Force -NotePropertyName defaultValue -NotePropertyValue $values.($parameter.Name)
        }
        Add-Parameter $parameter.Name $declaration $path
    }
    foreach ($name in $given) {
        if ($name -notin $declared) {
            throw "${File}: Include '$($resource.name)' sets parameter '$name', which $path doesn't declare"
        }
    }

    $ids = foreach ($inner in @($document.resources)) {
        if ($inner.type -eq $include) { throw "${File}: $path includes another document, which flattening doesn't handle" }
        $flat.Add([pscustomobject]@{ Resource = $inner; Include = $resource.name })
        "[resourceId('$($inner.type)', '$($inner.name)')]"
    }
    $includes[$resource.name] = [pscustomobject]@{ Ids = @($ids); DependsOn = @($resource.dependsOn | Where-Object { $_ }) }
}

# A dependsOn entry, with one on an Include replaced by one on each of its resources
function Expand-Dependency([string]$Expression) {
    $dependency = Get-Dependency $Expression
    if ($dependency.Type -ne $include) { return $Expression }
    if (-not $includes.ContainsKey($dependency.Name)) { throw "${File}: dependsOn names Include '$($dependency.Name)', which isn't in the document" }
    $includes[$dependency.Name].Ids
}

$seen = @{}
foreach ($item in $flat) {
    $resource = $item.Resource
    $source = if ($item.Include) { "Include '$($item.Include)'" } else { $File }
    if ($seen.ContainsKey($resource.name)) {
        throw "${File}: resource name '$($resource.name)' is used in both $($seen[$resource.name]) and $source"
    }
    $seen[$resource.name] = $source

    $dependsOn = @($resource.dependsOn | Where-Object { $_ })
    if ($item.Include) { $dependsOn += $includes[$item.Include].DependsOn }
    $expanded = @($dependsOn | ForEach-Object { Expand-Dependency $_ } | Select-Object -Unique)
    if ($expanded) {
        $resource | Add-Member -Force -NotePropertyName dependsOn -NotePropertyValue $expanded
    } elseif ($resource.PSObject.Properties.Name -contains 'dependsOn') {
        $resource.PSObject.Properties.Remove('dependsOn')
    }
}

$result = [ordered]@{ '$schema' = $entry.'$schema' }
if ($entry.metadata) { $result.metadata = $entry.metadata }
if ($parameters.Count) { $result.parameters = $parameters }
$result.resources = @($flat.Resource)

$yaml = Invoke-Yq -Arguments '-p', 'json', '-o', 'yaml', '-P', '.' -InputText ($result | ConvertTo-Json -Depth 64)
$null = New-Item -ItemType Directory -Force (Split-Path $Destination)
$header = "# Generated from $File by scripts/ConvertTo-FlatConfiguration.ps1, which replaced each Include with the" +
    "`n# resources of the document it includes. Edit the documents in dsc/, not this file."
Set-Content -LiteralPath $Destination -Value $header, $yaml
