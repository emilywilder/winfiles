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
        ($result.Stderr -join ' ') -replace '\s+', ' ' | Should -BeLike $message
        $result.Text | Should -BeNullOrEmpty
    }

    It "fails rather than guess when <case>" -ForEach @(
        @{ case = 'an Include has another property'; include = "configurationFile: a.dsc.yaml`n      parametersFile: p.json"; a = $thing; message = '*has parametersFile*' }
        @{ case = 'parametersContent sets a parameter the document lacks'; include = "configurationFile: a.dsc.yaml`n      parametersContent: '{`"parameters`": {`"nope`": 1}}'"; a = $thing; message = "*sets parameter 'nope'*doesn't declare*" }
        @{ case = 'an included document includes another'; include = 'configurationFile: a.dsc.yaml'; a = "resources:`n  - type: Microsoft.DSC/Include`n    name: Inner`n    properties: { configurationFile: c.dsc.yaml }"; message = '*includes another document*' }
        @{ case = 'an included document has variables'; include = 'configurationFile: a.dsc.yaml'; a = "variables:`n  x: 1`n$thing"; message = '*has variables*' }
        @{ case = 'the included document is missing'; include = 'configurationFile: nowhere.dsc.yaml'; a = $thing; message = "*nowhere.dsc.yaml doesn't exist*" }
    ) {
        $folder = New-Documents @{
            'entry.dsc.yaml' = "resources:`n  - type: Microsoft.DSC/Include`n    name: A`n    properties:`n      $include"
            'a.dsc.yaml'     = $a
        }
        $result = Invoke-Flatten $folder
        $result.ExitCode | Should -Not -Be 0
        ($result.Stderr -join ' ') -replace '\s+', ' ' | Should -BeLike $message
    }
}
