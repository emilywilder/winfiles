# ConvertTo-FlatConfiguration.ps1 against small documents written to TestDrive:, read back with yq (from mise.toml,
# as the script uses it)
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')

    $header = '$schema: https://raw.githubusercontent.com/PowerShell/DSC/main/schemas/2023/08/config/document.json'

    # Writes -Documents (relative path -> YAML body, after the $schema line) to a new folder, and returns it
    function New-Documents([hashtable]$Documents) {
        $folder = New-Item -ItemType Directory (Join-Path $TestDrive "docs-$([guid]::NewGuid())")
        foreach ($path in $Documents.Keys) {
            $file = Join-Path $folder $path
            $null = New-Item -ItemType Directory -Force (Split-Path $file)
            [IO.File]::WriteAllText($file, "$header`n$($Documents[$path])", [Text.UTF8Encoding]::new($false))
        }
        $folder.FullName
    }

    # Flattens entry.dsc.yaml in -Folder, and returns the run with the result read back as an object
    function Invoke-Flatten([string]$Folder) {
        $destination = Join-Path $Folder 'out\entry.dsc.yaml'
        $run = Invoke-Script ConvertTo-FlatConfiguration.ps1 'entry.dsc.yaml', $destination -Directory $Folder
        $flat = if (Test-Path $destination) {
            $previous = [Console]::OutputEncoding
            [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
            try { (yq -o json '.' $destination) -join "`n" | ConvertFrom-Json -DateKind String } finally { [Console]::OutputEncoding = $previous }
        }
        $run | Add-Member -PassThru Flat $flat | Add-Member -PassThru Text $(if (Test-Path $destination) { Get-Content -Raw $destination })
    }

    # What the run printed on stderr, on one line: PowerShell's error view wraps a long message with "| " on each line
    function Get-Message($Run) { ($Run.Stderr -join ' ') -replace '\s+\|\s+', ' ' -replace '\s+', ' ' }

    $thing = @'
resources:
  - type: Test/Thing
    name: one
    properties: {}
'@
}

Describe 'ConvertTo-FlatConfiguration.ps1' {
    It 'replaces each Include with its resources, in order, and keeps resources outside any Include' {
        $folder = New-Documents @{
            'entry.dsc.yaml'  = @'
metadata:
  winget:
    processor:
      identifier: dscv3
resources:
  - type: Microsoft.DSC/Include
    name: First
    properties:
      configurationFile: modules/a.dsc.yaml
  - type: Test/Thing
    name: between
    properties: {}
  - type: Microsoft.DSC/Include
    name: Second
    properties:
      configurationFile: modules/b.dsc.yaml
'@
            'modules/a.dsc.yaml' = @'
resources:
  - type: Test/Thing
    name: a1
    properties: { value: 1 }
  - type: Test/Other
    name: a2
    dependsOn:
      - "[resourceId('Test/Thing', 'a1')]"
    properties: { value: two }
'@
            'modules/b.dsc.yaml' = @'
resources:
  - type: Test/Thing
    name: b1
    properties: {}
'@
        }
        $result = Invoke-Flatten $folder
        $result.ExitCode | Should -Be 0
        $result.Flat.resources.name | Should -Be @('a1', 'a2', 'between', 'b1')
        $result.Flat.resources[0].properties.value | Should -Be 1
        $result.Flat.resources[1].dependsOn | Should -Be @("[resourceId('Test/Thing', 'a1')]")
        $result.Flat.metadata.winget.processor.identifier | Should -Be 'dscv3'
        $result.Flat.'$schema' | Should -BeLike '*2023/08/config/document.json'
        $result.Text | Should -BeLike '# Generated from entry.dsc.yaml*'
        $result.Stdout | Should -Be (Join-Path $folder 'out\entry.dsc.yaml')
    }

    It "writes to ~/.local/state/winfiles/flat, under the document's own name, when given no destination" {
        $folder = New-Documents @{ 'entry.dsc.yaml' = $thing }
        $userHome = New-Item -ItemType Directory (Join-Path $TestDrive "home-$([guid]::NewGuid())")
        $result = Invoke-Script ConvertTo-FlatConfiguration.ps1 'entry.dsc.yaml' -Directory $folder -Environment @{ USERPROFILE = $userHome.FullName }
        $result.ExitCode | Should -Be 0
        $expected = Join-Path $userHome '.local\state\winfiles\flat\entry.dsc.yaml'
        $result.Stdout | Should -Be $expected
        Get-Content -Raw $expected | Should -BeLike '# Generated from entry.dsc.yaml*'
    }

    It "makes dependsOn on an Include into dependsOn on each of its resources, for each resource of the dependent one" {
        $folder = New-Documents @{
            'entry.dsc.yaml'     = @'
resources:
  - type: Microsoft.DSC/Include
    name: Runtimes
    properties:
      configurationFile: a.dsc.yaml
  - type: Microsoft.DSC/Include
    name: Apps
    dependsOn:
      - "[resourceId('Microsoft.DSC/Include', 'Runtimes')]"
    properties:
      configurationFile: b.dsc.yaml
  - type: Test/Thing
    name: last
    dependsOn:
      - "[resourceId('Microsoft.DSC/Include', 'Apps')]"
    properties: {}
'@
            'a.dsc.yaml' = @'
resources:
  - { type: Test/Thing, name: r1, properties: {} }
  - { type: Test/Thing, name: r2, properties: {} }
'@
            'b.dsc.yaml' = @'
resources:
  - { type: Test/Thing, name: b1, properties: {} }
  - type: Test/Thing
    name: b2
    dependsOn:
      - "[resourceId('Test/Thing', 'b1')]"
    properties: {}
'@
        }
        $result = Invoke-Flatten $folder
        $result.ExitCode | Should -Be 0
        $byName = @{}; foreach ($r in $result.Flat.resources) { $byName[$r.name] = $r }
        $byName.r1.PSObject.Properties.Name | Should -Not -Contain 'dependsOn'
        $byName.b1.dependsOn | Should -Be @("[resourceId('Test/Thing', 'r1')]", "[resourceId('Test/Thing', 'r2')]")
        $byName.b2.dependsOn | Should -Be @("[resourceId('Test/Thing', 'b1')]", "[resourceId('Test/Thing', 'r1')]", "[resourceId('Test/Thing', 'r2')]")
        $byName.last.dependsOn | Should -Be @("[resourceId('Test/Thing', 'b1')]", "[resourceId('Test/Thing', 'b2')]")
    }

    It 'flattens Includes inside included documents, resolving every configurationFile from the entry folder' {
        $folder = New-Documents @{
            'entry.dsc.yaml'           = @'
resources:
  - type: Microsoft.DSC/Include
    name: Common
    properties:
      configurationFile: layers/common.dsc.yaml
  - type: Test/Thing
    name: last
    dependsOn:
      - "[resourceId('Microsoft.DSC/Include', 'Common')]"
    properties: {}
'@
            'layers/common.dsc.yaml'   = @'
resources:
  - type: Microsoft.DSC/Include
    name: A
    properties:
      configurationFile: modules/a.dsc.yaml
  - type: Test/Thing
    name: middle
    properties: {}
  - type: Microsoft.DSC/Include
    name: B
    dependsOn:
      - "[resourceId('Microsoft.DSC/Include', 'A')]"
    properties:
      configurationFile: modules/b.dsc.yaml
'@
            'modules/a.dsc.yaml'       = "resources:`n  - { type: Test/Thing, name: a1, properties: {} }"
            'modules/b.dsc.yaml'       = "resources:`n  - { type: Test/Thing, name: b1, properties: {} }"
        }
        $result = Invoke-Flatten $folder
        $result.ExitCode | Should -Be 0
        $result.Flat.resources.name | Should -Be @('a1', 'middle', 'b1', 'last')
        $byName = @{}; foreach ($r in $result.Flat.resources) { $byName[$r.name] = $r }
        $byName.b1.dependsOn | Should -Be @("[resourceId('Test/Thing', 'a1')]")
        $byName.last.dependsOn | Should -Be @("[resourceId('Test/Thing', 'a1')]", "[resourceId('Test/Thing', 'middle')]", "[resourceId('Test/Thing', 'b1')]")
    }

    It "gives the resources of a nested Include the dependsOn of every Include around them" {
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
resources:
  - type: Microsoft.DSC/Include
    name: Base
    properties:
      configurationFile: base.dsc.yaml
  - type: Microsoft.DSC/Include
    name: Layer
    dependsOn:
      - "[resourceId('Microsoft.DSC/Include', 'Base')]"
    properties:
      configurationFile: layer.dsc.yaml
'@
            'base.dsc.yaml'  = "resources:`n  - { type: Test/Thing, name: base, properties: {} }"
            'layer.dsc.yaml' = @'
resources:
  - type: Test/Thing
    name: first
    properties: {}
  - type: Microsoft.DSC/Include
    name: Inner
    dependsOn:
      - "[resourceId('Test/Thing', 'first')]"
    properties:
      configurationFile: inner.dsc.yaml
'@
            'inner.dsc.yaml' = "resources:`n  - { type: Test/Thing, name: deep, properties: {} }"
        }
        $result = Invoke-Flatten $folder
        $result.ExitCode | Should -Be 0
        $byName = @{}; foreach ($r in $result.Flat.resources) { $byName[$r.name] = $r }
        $byName.first.dependsOn | Should -Be @("[resourceId('Test/Thing', 'base')]")
        # Its own dependsOn first, then each surrounding Include's, outermost first
        $byName.deep.dependsOn | Should -Be @("[resourceId('Test/Thing', 'base')]", "[resourceId('Test/Thing', 'first')]")
    }

    It 'passes parametersContent down through two levels of Include' {
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
resources:
  - type: Microsoft.DSC/Include
    name: Layer
    properties:
      configurationFile: layer.dsc.yaml
      parametersContent: '{"parameters": {"layerName": "outer"}}'
'@
            'layer.dsc.yaml' = @'
parameters:
  layerName: { type: string, defaultValue: layer }
resources:
  - type: Microsoft.DSC/Include
    name: Inner
    properties:
      configurationFile: inner.dsc.yaml
      parametersContent: '{"parameters": {"innerName": "set by layer"}}'
'@
            'inner.dsc.yaml' = @'
parameters:
  innerName: { type: string, defaultValue: inner }
resources:
  - { type: Test/Thing, name: deep, properties: {} }
'@
        }
        $result = Invoke-Flatten $folder
        $result.ExitCode | Should -Be 0
        $result.Flat.parameters.layerName.defaultValue | Should -Be 'outer'
        $result.Flat.parameters.innerName.defaultValue | Should -Be 'set by layer'
    }

    It 'fails, naming the chain, when documents include each other in a loop' {
        $folder = New-Documents @{
            'entry.dsc.yaml' = "resources:`n  - type: Microsoft.DSC/Include`n    name: A`n    properties: { configurationFile: a.dsc.yaml }"
            'a.dsc.yaml'     = "resources:`n  - type: Microsoft.DSC/Include`n    name: B`n    properties: { configurationFile: sub/b.dsc.yaml }"
            'sub/b.dsc.yaml' = "resources:`n  - type: Microsoft.DSC/Include`n    name: Back`n    properties: { configurationFile: a.dsc.yaml }"
        }
        $result = Invoke-Flatten $folder
        $result.ExitCode | Should -Not -Be 0
        (Get-Message $result) |
            Should -BeLike "*Include 'Back' includes a document that's already being included: entry.dsc.yaml -> a.dsc.yaml -> sub/b.dsc.yaml -> a.dsc.yaml*"
        $result.Text | Should -BeNullOrEmpty
    }

    It 'fails, naming the resources, when dependsOn on an Include makes a loop' {
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
resources:
  - type: Test/Thing
    name: outside
    dependsOn:
      - "[resourceId('Microsoft.DSC/Include', 'A')]"
    properties: {}
  - type: Microsoft.DSC/Include
    name: A
    dependsOn:
      - "[resourceId('Test/Thing', 'outside')]"
    properties:
      configurationFile: a.dsc.yaml
'@
            'a.dsc.yaml'     = $thing
        }
        $result = Invoke-Flatten $folder
        $result.ExitCode | Should -Not -Be 0
        (Get-Message $result) | Should -BeLike "*dependsOn makes a loop: Test/Thing '*' -> Test/Thing '*' -> Test/Thing '*'*"
        $result.Text | Should -BeNullOrEmpty
    }

    It 'merges the parameters, with parametersContent in place of the defaults' {
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
resources:
  - type: Microsoft.DSC/Include
    name: A
    properties:
      configurationFile: a.dsc.yaml
      parametersContent: >-
        {"parameters": {"name": "Alpine", "port": 22}}
  - type: Microsoft.DSC/Include
    name: B
    properties:
      configurationFile: b.dsc.yaml
'@
            'a.dsc.yaml'     = @'
parameters:
  name: { type: string, defaultValue: NixOS }
  port: { type: int, defaultValue: 2122 }
  kept: { type: string, defaultValue: same }
resources:
  - type: Test/Thing
    name: a
    properties:
      name: "[parameters('name')]"
'@
            'b.dsc.yaml'     = @'
parameters:
  buckets:
    type: object
    defaultValue: { main: https://example.test/main.git }
resources:
  - { type: Test/Thing, name: b, properties: {} }
'@
        }
        $result = Invoke-Flatten $folder
        $result.ExitCode | Should -Be 0
        $result.Flat.parameters.name.defaultValue | Should -Be 'Alpine'
        $result.Flat.parameters.port.defaultValue | Should -Be 22
        $result.Flat.parameters.port.type | Should -Be 'int'
        $result.Flat.parameters.kept.defaultValue | Should -Be 'same'
        $result.Flat.parameters.buckets.defaultValue.main | Should -Be 'https://example.test/main.git'
        $result.Flat.resources[0].properties.name | Should -Be "[parameters('name')]"
    }

    It 'keeps multi-line scripts, strings that look like other types, and non-ASCII text as they were' {
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
resources:
  - type: Microsoft.DSC/Include
    name: A
    properties:
      configurationFile: a.dsc.yaml
'@
            'a.dsc.yaml'     = @'
resources:
  - type: Test/Thing
    name: a
    properties:
      script: |
        $x = 'one'
        if ($x) { "two: $x" }
      version: "1.10"
      flag: "yes"
      date: "2026-11-17"
      text: "café — 26H2 ×2"
'@
        }
        $result = Invoke-Flatten $folder
        $result.ExitCode | Should -Be 0
        $properties = $result.Flat.resources[0].properties
        $properties.script | Should -Be "`$x = 'one'`nif (`$x) { `"two: `$x`" }`n"
        $properties.version | Should -BeOfType [string]
        $properties.version | Should -Be '1.10'
        $properties.flag | Should -Be 'yes'
        $properties.date | Should -BeOfType [string]
        $properties.date | Should -Be '2026-11-17'
        $properties.text | Should -Be 'café — 26H2 ×2'
    }

    It 'fails, naming both places, when <case>' -ForEach @(
        @{
            case = 'a resource name is used twice'
            a = "resources:`n  - { type: Test/Thing, name: same, properties: {} }"
            b = "resources:`n  - { type: Test/Other, name: same, properties: {} }"
            message = "*resource name 'same' is used in both Include 'A' and Include 'B'*"
        }
        @{
            case = 'a parameter is declared twice'
            a = "parameters:`n  path: { type: string }`n$thing"
            b = "parameters:`n  path: { type: string }`nresources:`n  - { type: Test/Thing, name: two, properties: {} }"
            message = "*parameter 'path' is declared in both*a.dsc.yaml and*b.dsc.yaml*"
        }
    ) {
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
resources:
  - type: Microsoft.DSC/Include
    name: A
    properties:
      configurationFile: a.dsc.yaml
  - type: Microsoft.DSC/Include
    name: B
    properties:
      configurationFile: b.dsc.yaml
'@
            'a.dsc.yaml'     = $a
            'b.dsc.yaml'     = $b
        }
        $result = Invoke-Flatten $folder
        $result.ExitCode | Should -Not -Be 0
        (Get-Message $result) | Should -BeLike $message
        $result.Text | Should -BeNullOrEmpty
    }

    It "fails rather than guess when <case>" -ForEach @(
        @{ case = 'an Include has another property'; include = "configurationFile: a.dsc.yaml`n      parametersFile: p.json"; a = $thing; message = '*has parametersFile*' }
        @{ case = 'parametersContent sets a parameter the document lacks'; include = "configurationFile: a.dsc.yaml`n      parametersContent: '{`"parameters`": {`"nope`": 1}}'"; a = $thing; message = "*sets parameter 'nope'*doesn't declare*" }
        @{ case = 'parametersContent sets a parameter to an expression'; include = "configurationFile: a.dsc.yaml`n      parametersContent: '{`"parameters`": {`"p`": `"[parameters(''x'')]`"}}'"; a = "parameters:`n  p: { type: string }`n$thing"; message = "*sets parameter 'p' to '``[parameters('x')]', an expression*" }
        @{ case = 'a document includes itself'; include = 'configurationFile: a.dsc.yaml'; a = "resources:`n  - type: Microsoft.DSC/Include`n    name: Again`n    properties: { configurationFile: a.dsc.yaml }"; message = "*Include 'Again' includes a document that's already being included: entry.dsc.yaml -> a.dsc.yaml -> a.dsc.yaml*" }
        @{ case = 'an included document has variables'; include = 'configurationFile: a.dsc.yaml'; a = "variables:`n  x: 1`n$thing"; message = '*has variables*' }
        @{ case = 'the included document is missing'; include = 'configurationFile: nowhere.dsc.yaml'; a = $thing; message = "*nowhere.dsc.yaml doesn't exist*" }
    ) {
        $folder = New-Documents @{
            'entry.dsc.yaml' = "resources:`n  - type: Microsoft.DSC/Include`n    name: A`n    properties:`n      $include"
            'a.dsc.yaml'     = $a
        }
        $result = Invoke-Flatten $folder
        $result.ExitCode | Should -Not -Be 0
        (Get-Message $result) | Should -BeLike $message
    }

    It "fails rather than guess when the entry <case>" -ForEach @(
        @{ case = 'has an Include with no configurationFile'; entry = "resources:`n  - { type: Microsoft.DSC/Include, name: A, properties: {} }"; message = "*Include 'A' has no configurationFile*" }
        @{ case = 'has two Includes of the same name'; entry = "resources:`n  - { type: Microsoft.DSC/Include, name: A, properties: { configurationFile: a.dsc.yaml } }`n  - { type: Microsoft.DSC/Include, name: A, properties: { configurationFile: a.dsc.yaml } }"; message = "*has two Includes named 'A'*" }
        @{ case = "has a dependsOn that isn't resourceId()"; entry = "resources:`n  - type: Test/Thing`n    name: two`n    dependsOn: [ `"[concat('a', 'b')]`" ]`n    properties: {}"; message = "*dependsOn '``[concat('a', 'b')]' isn't a resourceId*" }
        @{ case = "names an Include its own document doesn't have"; entry = "resources:`n  - type: Test/Thing`n    name: two`n    dependsOn: [ `"[resourceId('Microsoft.DSC/Include', 'Nowhere')]`" ]`n    properties: {}"; message = "*dependsOn names Include 'Nowhere', which isn't in entry.dsc.yaml*" }
    ) {
        $folder = New-Documents @{ 'entry.dsc.yaml' = $entry; 'a.dsc.yaml' = $thing }
        $result = Invoke-Flatten $folder
        $result.ExitCode | Should -Not -Be 0
        (Get-Message $result) | Should -BeLike $message
        $result.Text | Should -BeNullOrEmpty
    }
}

# The real entry documents, so a name used twice across modules, or anything else the flattener refuses, fails here
# rather than at the start of an install. Written to TestDrive:, not the real ~/.local/state
Describe 'The entry documents in dsc/' {
    BeforeDiscovery {
        $entryCases = @(Get-ChildItem (Join-Path $PSScriptRoot '..\..\dsc') -File -Filter '*.dsc.yaml' | ForEach-Object { @{ Name = $_.Name } })
    }

    It '<Name> flattens, leaving no Include' -ForEach $entryCases {
        $destination = Join-Path $TestDrive "flat\$Name"
        $result = Invoke-Script ConvertTo-FlatConfiguration.ps1 "dsc/$Name", $destination
        $result.ExitCode | Should -Be 0 -Because ($result.Stderr -join "`n")
        $previous = [Console]::OutputEncoding
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        try { $flat = (yq -o json '.' $destination) -join "`n" | ConvertFrom-Json -DateKind String } finally { [Console]::OutputEncoding = $previous }
        $flat.resources | Should -Not -BeNullOrEmpty
        $flat.resources.type | Should -Not -Contain 'Microsoft.DSC/Include'
    }
}

# How the recipes pass the bypass on, read with just --dry-run, which prints each line without running it, and
# `just flatten`'s exit code. Read-only: a flatten that succeeds would write to the real ~/.local/state, which
# Invoke-Clean.ps1 restores whatever USERPROFILE the test sets, so only its failure is run
Describe 'just flat and just flatten' {
    BeforeAll {
        # What a dry run of `just <Arguments>` prints, stdout and stderr, as one string
        function Get-DryRun([string[]]$Arguments) {
            $run = Invoke-Child $repo @{} { just --dry-run @Arguments }
            $run | Add-Member -PassThru Text (($run.Stdout + $run.Stderr) -join "`n")
        }
    }

    It 'runs the system and home documents as one aggregate for install-steps, then checks both, with nothing to run them unflattened' {
        $run = Get-DryRun 'install-steps', 'iris', 'emily'
        $run.ExitCode | Should -Be 0
        $run.Text | Should -Match 'Invoke-Configuration\.ps1 set dsc/iris\.system\.dsc\.yaml dsc/emily@iris\.home\.dsc\.yaml;'
        $run.Text | Should -Match 'Invoke-Configuration\.ps1 test dsc/iris\.system\.dsc\.yaml dsc/emily@iris\.home\.dsc\.yaml;'
        $run.Text | Should -Not -Match 'NoFlatten'
    }

    It 'has no flat setting any more' {
        $run = Get-DryRun 'flat=false', 'check', 'iris', 'emily'
        $run.ExitCode | Should -Not -Be 0
    }
    It "exits 1 from just flatten when the document can't be flattened, with the reason" {
        $run = Invoke-Child $repo @{} { just flatten dsc/no-such.dsc.yaml }
        $run.ExitCode | Should -Be 1
        ($run.Stdout + $run.Stderr) -join ' ' | Should -BeLike "*dsc/no-such.dsc.yaml doesn't exist*"
    }
}

Describe 'ConvertTo-FlatConfiguration.ps1 securityContext and -Batch' {
    BeforeAll {
        # Runs the entry in -Folder with -Batch, and returns the run with each batch file read back, in batch order
        function Invoke-Batch([string]$Folder, [string]$First) {
            $destination = Join-Path $Folder 'out\entry.dsc.yaml'
            $arguments = @('entry.dsc.yaml', $destination, '-Batch')
            if ($First) { $arguments += '-First', $First }
            $run = Invoke-Script ConvertTo-FlatConfiguration.ps1 $arguments -Directory $Folder
            $previous = [Console]::OutputEncoding
            [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
            try {
                $batches = @(Get-ChildItem (Join-Path $Folder 'out') -Filter 'entry.*-*.dsc.yaml' -ErrorAction Ignore |
                    Where-Object { $_.Name -match '^entry\.\d+-(elevated|user)\.dsc\.yaml$' } |
                    Sort-Object { [int]($_.Name -replace '^entry\.(\d+)-.*', '$1') } | ForEach-Object {
                        [pscustomobject]@{
                            Name  = $_.Name
                            Level = $_.Name -replace '^entry\.\d+-(\w+)\.dsc\.yaml$', '$1'
                            Doc   = (yq -o json '.' $_.FullName) -join "`n" | ConvertFrom-Json -DateKind String
                        }
                    })
            } finally { [Console]::OutputEncoding = $previous }
            $run | Add-Member -PassThru Batches $batches
        }
    }

    It 'gives resources the tag of their document, and takes the tag out' {
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
resources:
  - type: Microsoft.DSC/Include
    name: Outer
    properties:
      configurationFile: outer.dsc.yaml
  - type: Test/Thing
    name: plain
    properties: {}
'@
            'outer.dsc.yaml' = @'
metadata:
  winget: { securityContext: elevated }
resources:
  - type: Test/Thing
    name: inherits
    metadata:
      description: kept
    properties: {}
  - type: Test/Thing
    name: own
    metadata:
      winget: { securityContext: elevated }
    properties: {}
'@
        }
        $result = Invoke-Batch $folder
        $result.ExitCode | Should -Be 0
        $result.Batches.Level | Should -Be @('elevated', 'user')
        $result.Batches[0].Doc.resources.name | Should -Be @('inherits', 'own')
        $result.Batches[1].Doc.resources.name | Should -Be @('plain')
        $result.Batches[0].Doc.resources[0].metadata.description | Should -Be 'kept'
        $result.Batches[0].Doc.resources[1].PSObject.Properties.Name | Should -Not -Contain 'metadata'
    }

    It 'gives what an entry includes the entry''s tag, and takes it out of the header' {
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
metadata:
  winget:
    securityContext: elevated
    processor: { identifier: dscv3 }
resources:
  - type: Test/Thing
    name: top
    properties: {}
  - type: Microsoft.DSC/Include
    name: Child
    properties: { configurationFile: child.dsc.yaml }
'@
            'child.dsc.yaml'      = @'
resources:
  - { type: Test/Thing, name: inherited, properties: {} }
'@
        }
        $result = Invoke-Batch $folder
        $result.ExitCode | Should -Be 0
        $result.Batches.Level | Should -Be @('elevated')
        $result.Batches[0].Doc.resources.name | Should -Be @('top', 'inherited')
        $result.Batches[0].Doc.metadata.winget.PSObject.Properties.Name | Should -Be @('processor')
    }

    It 'fails on a tag on an Include' {
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
resources:
  - type: Microsoft.DSC/Include
    name: Child
    metadata: { winget: { securityContext: elevated } }
    properties: { configurationFile: child.dsc.yaml }
'@
            'child.dsc.yaml' = @'
resources:
  - { type: Test/Thing, name: one, properties: {} }
'@
        }
        $result = Invoke-Flatten $folder
        $result.ExitCode | Should -Be 1
        Get-Message $result | Should -BeLike "*Include 'Child' has a securityContext, which only a document or a resource can have*"
    }

    It 'takes the tag out of a plain flat copy too' {
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
resources:
  - type: Test/Thing
    name: one
    metadata:
      winget: { securityContext: elevated }
    properties: {}
'@
        }
        $result = Invoke-Flatten $folder
        $result.ExitCode | Should -Be 0
        $result.Flat.resources[0].PSObject.Properties.Name | Should -Not -Contain 'metadata'
    }

    It 'fails on a securityContext other than elevated' {
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
resources:
  - type: Test/Thing
    name: one
    metadata:
      winget: { securityContext: restricted }
    properties: {}
'@
        }
        $result = Invoke-Flatten $folder
        $result.ExitCode | Should -Be 1
        Get-Message $result | Should -BeLike "*'one' has securityContext 'restricted', and only 'elevated' is handled*"
    }

    It 'runs same-level resources together past one that has to wait, with as few batches as dependsOn allows' {
        # a (user) -> b (elevated) -> c (user); d (user) and e (elevated) depend on nothing
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
resources:
  - { type: Test/Thing, name: a, properties: {} }
  - type: Test/Thing
    name: b
    dependsOn: ["[resourceId('Test/Thing', 'a')]"]
    metadata: { winget: { securityContext: elevated } }
    properties: {}
  - type: Test/Thing
    name: c
    dependsOn: ["[resourceId('Test/Thing', 'b')]"]
    properties: {}
  - { type: Test/Thing, name: d, properties: {} }
  - type: Test/Thing
    name: e
    metadata: { winget: { securityContext: elevated } }
    properties: {}
'@
        }
        $result = Invoke-Batch $folder
        $result.ExitCode | Should -Be 0
        # a and d first (user), then b and e (elevated), then c: three batches
        $result.Batches.Level | Should -Be @('user', 'elevated', 'user')
        $result.Batches[0].Doc.resources.name | Should -Be @('a', 'd')
        $result.Batches[1].Doc.resources.name | Should -Be @('b', 'e')
        $result.Batches[2].Doc.resources.name | Should -Be @('c')
    }

    It 'drops a dependsOn on an earlier batch and keeps one inside the batch' {
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
resources:
  - { type: Test/Thing, name: a, properties: {} }
  - type: Test/Thing
    name: b
    dependsOn: ["[resourceId('Test/Thing', 'a')]"]
    metadata: { winget: { securityContext: elevated } }
    properties: {}
  - type: Test/Thing
    name: c
    dependsOn:
      - "[resourceId('Test/Thing', 'a')]"
      - "[resourceId('Test/Thing', 'b')]"
    metadata: { winget: { securityContext: elevated } }
    properties: {}
'@
        }
        $result = Invoke-Batch $folder
        $result.ExitCode | Should -Be 0
        $result.Batches.Level | Should -Be @('user', 'elevated')
        $result.Batches[0].Doc.resources[0].PSObject.Properties.Name | Should -Not -Contain 'dependsOn'
        $result.Batches[1].Doc.resources[0].PSObject.Properties.Name | Should -Not -Contain 'dependsOn'
        $result.Batches[1].Doc.resources[1].dependsOn | Should -Be @("[resourceId('Test/Thing', 'b')]")
    }

    It 'carries an Include''s dependsOn across levels onto its resources, so they land in a later batch' {
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
resources:
  - type: Microsoft.DSC/Include
    name: Late
    dependsOn: ["[resourceId('Microsoft.DSC/Include', 'Early')]"]
    properties: { configurationFile: late.dsc.yaml }
  - type: Microsoft.DSC/Include
    name: Early
    properties: { configurationFile: early.dsc.yaml }
'@
            'late.dsc.yaml'  = @'
resources:
  - { type: Test/Thing, name: late1, properties: {} }
'@
            'early.dsc.yaml' = @'
metadata: { winget: { securityContext: elevated } }
resources:
  - { type: Test/Thing, name: early1, properties: {} }
'@
        }
        $result = Invoke-Batch $folder
        $result.ExitCode | Should -Be 0
        $result.Batches.Level | Should -Be @('elevated', 'user')
        $result.Batches[0].Doc.resources.name | Should -Be @('early1')
        $result.Batches[1].Doc.resources.name | Should -Be @('late1')
    }

    It 'gives each batch only the parameters its resources use' {
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
resources:
  - type: Microsoft.DSC/Include
    name: A
    properties: { configurationFile: a.dsc.yaml }
  - type: Microsoft.DSC/Include
    name: B
    properties: { configurationFile: b.dsc.yaml }
'@
            'a.dsc.yaml'     = @'
metadata: { winget: { securityContext: elevated } }
parameters:
  pathA: { type: string, defaultValue: one }
resources:
  - type: Test/Thing
    name: a1
    properties: { path: "[parameters('pathA')]" }
'@
            'b.dsc.yaml'     = @'
parameters:
  pathB: { type: string, defaultValue: two }
  unused: { type: string, defaultValue: three }
resources:
  - type: Test/Thing
    name: b1
    properties: { path: "[concat(parameters('pathB'), '\\x')]" }
'@
        }
        $result = Invoke-Batch $folder
        $result.ExitCode | Should -Be 0
        @($result.Batches[0].Doc.parameters.PSObject.Properties.Name) | Should -Be @('pathA')
        @($result.Batches[1].Doc.parameters.PSObject.Properties.Name) | Should -Be @('pathB')
    }

    It 'has no parameters key in a batch that uses none, and keeps the entry''s header' {
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
metadata:
  winget:
    processor:
      identifier: dscv3
resources:
  - { type: Test/Thing, name: a, properties: {} }
'@
        }
        $result = Invoke-Batch $folder
        $result.Batches.Count | Should -Be 1
        $result.Batches[0].Doc.PSObject.Properties.Name | Should -Not -Contain 'parameters'
        $result.Batches[0].Doc.metadata.winget.processor.identifier | Should -Be 'dscv3'
    }

    Context 'more than one entry' {
        BeforeAll {
            # Passed as an array, which is how Invoke-Configuration.ps1 calls it (-File would pass one string)
            function Invoke-Aggregate([string]$Folder, [string[]]$Entries) {
                $script = Join-Path $repo 'scripts\ConvertTo-FlatConfiguration.ps1'
                $destination = Join-Path $Folder 'out\aggregate.dsc.yaml'
                $list = ($Entries | ForEach-Object { "'$_'" }) -join ','
                $run = Invoke-Child $Folder @{} { pwsh -NoLogo -NoProfile -NonInteractive -Command "& '$script' @($list) -Destination '$destination' -Batch; exit `$LASTEXITCODE" }
                $batches = @(Get-ChildItem (Join-Path $Folder 'out') -Filter 'aggregate.*-*.dsc.yaml' -ErrorAction Ignore | Sort-Object Name |
                    ForEach-Object { [pscustomobject]@{ Name = $_.Name; Doc = (yq -o json '.' $_.FullName) -join "`n" | ConvertFrom-Json -DateKind String } })
                $run | Add-Member -PassThru Batches $batches
            }
        }

        It 'puts the entries in one run, the first one''s resources first, and batches them together' {
            $folder = New-Documents @{
                'system.dsc.yaml' = @'
metadata: { winget: { securityContext: elevated } }
resources:
  - { type: Test/Thing, name: s1, properties: {} }
'@
                'home.dsc.yaml'   = @'
resources:
  - { type: Test/Thing, name: h1, properties: {} }
'@
            }
            $result = Invoke-Aggregate $folder 'system.dsc.yaml', 'home.dsc.yaml'
            $result.ExitCode | Should -Be 0
            $result.Batches.Doc.resources.name | Should -Be @('s1', 'h1')
            $result.Batches.Name | Should -Be @('aggregate.1-elevated.dsc.yaml', 'aggregate.2-user.dsc.yaml')
        }

        It 'fails on a resource name used in two entries, naming both' {
            $folder = New-Documents @{
                'system.dsc.yaml' = @'
resources:
  - { type: Test/Thing, name: same, properties: {} }
'@
                'home.dsc.yaml'   = @'
resources:
  - { type: Test/Thing, name: same, properties: {} }
'@
            }
            $result = Invoke-Aggregate $folder 'system.dsc.yaml', 'home.dsc.yaml'
            $result.ExitCode | Should -Be 1
            ($result.Stderr -join ' ') | Should -BeLike "*resource name 'same' is used in both system.dsc.yaml and home.dsc.yaml*"
        }
    }

    Context '-First' {
        BeforeAll {
            $script:entry = @'
metadata: { winget: { securityContext: elevated } }
resources:
  - { type: Test/Thing, name: x, properties: {} }
  - { type: Test/Thing, name: w, properties: {} }
  - type: Test/Thing
    name: z
    dependsOn: ["[resourceId('Test/Thing', 'w')]"]
    properties: {}
  - type: Test/Thing
    name: y
    dependsOn: ["[resourceId('Test/Thing', 'z')]"]
    properties: {}
'@
        }

        It 'runs the resources it names and what they depend on as the first batch, apart from the rest' {
            $folder = New-Documents @{ 'entry.dsc.yaml' = $entry }
            $result = Invoke-Batch $folder 'Test/Thing|z'
            $result.ExitCode | Should -Be 0
            $result.Batches.Level | Should -Be @('elevated', 'elevated')
            $result.Batches[0].Doc.resources.name | Should -Be @('w', 'z')
            $result.Batches[1].Doc.resources.name | Should -Be @('x', 'y')
            # z's dependsOn stays inside its batch; y's on z, in an earlier batch, goes
            $result.Batches[0].Doc.resources[1].dependsOn | Should -Be @("[resourceId('Test/Thing', 'w')]")
            $result.Batches[1].Doc.resources[1].PSObject.Properties.Name | Should -Not -Contain 'dependsOn'
        }

        It 'makes one batch when it names nothing' {
            $folder = New-Documents @{ 'entry.dsc.yaml' = $entry }
            $result = Invoke-Batch $folder
            $result.Batches.Count | Should -Be 1
        }

        It 'fails on a resource that isn''t in the entry' {
            $folder = New-Documents @{ 'entry.dsc.yaml' = $entry }
            $result = Invoke-Batch $folder 'Test/Thing|nope'
            $result.ExitCode | Should -Be 1
            Get-Message $result | Should -BeLike "*-First names Test/Thing 'nope', which isn't in it*"
        }

        It 'fails when what has to come first isn''t elevated' {
            $folder = New-Documents @{
                'entry.dsc.yaml' = @'
resources:
  - { type: Test/Thing, name: plain, properties: {} }
'@
            }
            $result = Invoke-Batch $folder 'Test/Thing|plain'
            $result.ExitCode | Should -Be 1
            Get-Message $result | Should -BeLike "*Test/Thing 'plain' has to come before the restart, but isn't elevated*"
        }
    }

    It 'deletes the batches of an earlier run for the same destination' {
        $folder = New-Documents @{
            'entry.dsc.yaml' = @'
resources:
  - { type: Test/Thing, name: a, properties: {} }
'@
        }
        $out = New-Item -ItemType Directory -Force (Join-Path $folder 'out')
        Set-Content (Join-Path $out 'entry.7-elevated.dsc.yaml') 'old'
        Set-Content (Join-Path $out 'other.1-user.dsc.yaml') 'someone else''s'
        $result = Invoke-Batch $folder
        $result.ExitCode | Should -Be 0
        Test-Path (Join-Path $out 'entry.7-elevated.dsc.yaml') | Should -BeFalse
        Test-Path (Join-Path $out 'other.1-user.dsc.yaml') | Should -BeTrue
        $result.Batches.Name | Should -Be @('entry.1-user.dsc.yaml')
    }
}
