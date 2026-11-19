# Shared by the tests in this folder and tests/scripts, which dot-source it in BeforeAll.
# Resources run the way DSC runs them: a child pwsh started with the command in the resource's manifest. What a
# resource talks to is replaced with fakes made of files (tests/fakes), never with mocks, so nothing here can reach
# the real winget or Scoop.
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$fakes = Join-Path $repo 'tests\fakes'

# Runs -Start, which starts a child process, in -Directory with -Environment set for that child only, and returns
# its exit code and its stdout and stderr lines. A $null value unsets a variable.
# The scriptblock sees this function's variables first, so they have names a caller won't use
function Invoke-Child([string]$Directory, [hashtable]$Environment, [scriptblock]$Start) {
    $childStderrFile = New-TemporaryFile
    $childSaved = @{}
    # Not $null: PowerShell passes it as an empty string, which leaves the variable set but empty
    foreach ($childVariable in $Environment.Keys) {
        $childSaved[$childVariable] = [Environment]::GetEnvironmentVariable($childVariable) ?? [NullString]::Value
        [Environment]::SetEnvironmentVariable($childVariable, $Environment[$childVariable] ?? [NullString]::Value)
    }
    Push-Location $Directory
    try {
        $childStdout = @(& $Start 2> $childStderrFile)
        $childExitCode = $LASTEXITCODE
        $childStderr = @(Get-Content $childStderrFile)
    } finally {
        Pop-Location
        foreach ($childVariable in $childSaved.Keys) {
            [Environment]::SetEnvironmentVariable($childVariable, $childSaved[$childVariable])
        }
        Remove-Item $childStderrFile
    }
    [pscustomobject]@{ ExitCode = $childExitCode; Stdout = $childStdout; Stderr = $childStderr }
}

# Runs scripts/<Name> in a child pwsh, as the recipes do, from -Directory (the repo by default), with -Environment
# set for the child only. Returns its exit code and its stdout and stderr lines; Write-Host lands on stdout.
function Invoke-Script {
    param([string]$Name, [string[]]$Arguments = @(), [hashtable]$Environment = @{}, [string]$Directory = $repo)
    $scriptFile = Join-Path $repo "scripts\$Name"
    Invoke-Child $Directory $Environment { pwsh -NoLogo -NoProfile -NonInteractive -File $scriptFile @Arguments }
}

# A fake dsc (tests/fakes/bin/dsc.cmd), copied to a folder of its own so a test can put DSC's discovery extensions
# beside it with -Extensions, or put it in a folder named WindowsApps, where the Store DSC is, with -Store.
# -Home is a folder for $HOME, so DSC's results are kept there, not in the real ~/.local/state. Pass .Environment
# to Invoke-Script, answer with Set-FakeDscResult and read Get-FakeDscCalls.
function New-FakeDsc {
    param([switch]$Extensions, [switch]$Store)
    $bin = Join-Path $TestDrive "dsc-$([guid]::NewGuid())"
    if ($Store) { $bin = Join-Path $bin 'WindowsApps' }
    $bin = New-Item -ItemType Directory $bin
    Copy-Item (Join-Path $fakes 'bin\dsc.cmd'), (Join-Path $fakes 'bin\fake-dsc.ps1') $bin
    if ($Extensions) { Set-Content (Join-Path $bin 'Microsoft.PowerShell.Discover.dsc.extension.json') '{}' }
    $state = New-Item -ItemType Directory "$bin-state"
    $userHome = New-Item -ItemType Directory "$bin-home"
    [pscustomobject]@{
        Path        = $bin.FullName
        State       = $state.FullName
        Home        = $userHome.FullName
        # pwsh sets $HOME from USERPROFILE
        Environment = @{
            PATH              = "$($bin.FullName);$env:PATH"
            WINFILES_FAKE_DSC = $state.FullName
            USERPROFILE       = $userHome.FullName
        }
    }
}

# What the fake dsc prints for a document (by file name), and the code it exits with. -Results are resource results,
# from New-DscResult and New-DscInclude.
# -Operation makes it the answer to that operation only (test or set), beside an answer for the other
function Set-FakeDscResult($Fake, [string]$Document, [object[]]$Results, [int]$ExitCode = 0, [switch]$NoOutput, [string]$Operation) {
    $name = if ($Operation) { "$Document.$Operation" } else { $Document }
    if (-not $NoOutput) {
        @{ results = @($Results); hadErrors = $false } | ConvertTo-Json -Depth 20 |
            Set-Content (Join-Path $Fake.State "$name.json")
    }
    if ($ExitCode) { Set-Content (Join-Path $Fake.State "$name.exitcode") $ExitCode }
}

# -RestartSystem is a restart the resource reports, as DSC 3.3.0 puts it in the resource's executionInformation
function New-DscResult {
    param([string]$Type, [string]$Name, [switch]$Differs, [hashtable]$ActualState = @{}, [string[]]$Differing = @(), [hashtable]$AfterState = @{}, [string]$RestartSystem)
    $result = @{
        type   = $Type
        name   = $Name
        result = @{ inDesiredState = -not $Differs; actualState = $ActualState; afterState = $AfterState; differingProperties = $Differing }
    }
    if ($RestartSystem) { $result.executionInformation = @{ restartRequired = @(@{ system = $RestartSystem }) } }
    $result
}

# An Include's result is the list of results from its document. After a `test` that's the result itself; after a
# `set` (-Set) it's the result's beforeState and afterState (seen in a vm-quick install with DSC 3.3.0, 2026-11-16)
function New-DscInclude([string]$Name, [object[]]$Results, [switch]$Set) {
    $result = if ($Set) { @{ beforeState = @($Results); afterState = @($Results); changedProperties = @() } } else { , @($Results) }
    @{ type = 'Microsoft.DSC/Include'; name = $Name; result = $result }
}

function Get-FakeDscCalls($Fake) {
    $calls = Join-Path $Fake.State 'calls.jsonl'
    if (Test-Path $calls) { @(Get-Content $calls | ConvertFrom-Json) } else { @() }
}

# Runs one operation of a Winfiles/* resource, with -Instance as JSON on stdin and the working directory DSC uses
# (the manifest's folder). -Environment is set for the child only. Returns the exit code, the state the resource
# printed (its last stdout line), its stdout lines, the messages it wrote as {"<level>": "<text>"} lines, and all of
# its stderr.
function Invoke-Resource {
    param(
        [string]$Name,
        [ValidateSet('get', 'test', 'set')]
        [string]$Operation,
        [hashtable]$Instance,
        [hashtable]$Environment = @{}
    )
    $resources = Join-Path $repo 'dsc\resources'
    $command = (Get-Content -Raw (Join-Path $resources "$Name.dsc.resource.json") | ConvertFrom-Json).$Operation
    $json = $Instance | ConvertTo-Json -Compress -Depth 5
    $run = Invoke-Child $resources $Environment { $json | & $command.executable @($command.args) }

    $stdout, $exitCode, $stderr = $run.Stdout, $run.ExitCode, $run.Stderr
    $json = $stdout | Where-Object { $_ } | Select-Object -Last 1
    $messages = $stderr | Where-Object { $_ -match '^\{"\w+":' } | ForEach-Object {
        $property = @(($_ | ConvertFrom-Json).PSObject.Properties)[0]
        [pscustomobject]@{ Level = $property.Name; Text = $property.Value }
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        State    = if ($json) { $json | ConvertFrom-Json }
        Stdout   = @($stdout | Where-Object { $_ })
        Messages = @($messages)
        Stderr   = $stderr
    }
}

# A fake winget CLI (tests/fakes/bin/winget.cmd) with -Installed ids already installed, and every install and
# `dscv3 package --set` exiting with -ExitCode. Pass .Environment to Invoke-Resource; Get-FakeWinGetCliCalls reads the
# calls, and Get-FakeWinGetCliDscInput what each `dscv3 package` got on stdin
function New-FakeWinGetCli([string[]]$Installed = @(), [int]$ExitCode = 0, [int]$GetExitCode = 0) {
    $folder = New-Item -ItemType Directory (Join-Path $TestDrive "winget-cli-$([guid]::NewGuid())")
    if ($Installed) { Set-Content (Join-Path $folder 'installed.txt') $Installed }
    if ($ExitCode) { Set-Content (Join-Path $folder 'exitcode.txt') $ExitCode }
    if ($GetExitCode) { Set-Content (Join-Path $folder 'getexitcode.txt') $GetExitCode }
    # A home of its own, so what a resource writes to the run log isn't the real one
    $userHome = New-Item -ItemType Directory "$($folder.FullName)-home"
    [pscustomobject]@{
        Path        = $folder.FullName
        Home        = $userHome.FullName
        Environment = @{
            PATH                     = "$(Join-Path $fakes 'bin');$env:PATH"
            WINFILES_FAKE_WINGET_CLI = $folder.FullName
            USERPROFILE              = $userHome.FullName
        }
    }
}

function Get-FakeWinGetCliCalls($Fake) {
    $calls = Join-Path $Fake.Path 'calls.txt'
    if (Test-Path $calls) { @(Get-Content $calls) } else { @() }
}

function Get-FakeWinGetCliDscInput($Fake) {
    $inputs = Join-Path $Fake.Path 'dscv3.jsonl'
    if (Test-Path $inputs) { @(Get-Content $inputs | ConvertFrom-Json) } else { @() }
}

# Fails unless a child pwsh given $Fake's environment runs the fake winget, so a change in how PATH is searched can't
# let a test install real packages
function Assert-FakeWinGetCliRuns($Fake) {
    $run = Invoke-Child $repo $Fake.Environment { pwsh -NoLogo -NoProfile -NonInteractive -Command '(Get-Command winget).Source' }
    if ($run.Stdout -notlike "$fakes\*") { throw "A child pwsh runs winget from $($run.Stdout), not the fake" }
}

# Runs a resource's script in this process instead, so Pester mocks reach what it calls. Only for a resource whose
# surroundings can't be replaced with files: registry keys and CIM classes it names itself, or executables it calls
# by name. Write-ResourceMessage writes straight to the console, so tests mock it to check messages.
# Returns the exit code and the state the resource printed.
function Invoke-ResourceScript {
    param(
        [string]$Name,
        [ValidateSet('get', 'test', 'set')]
        [string]$Operation,
        [hashtable]$Instance
    )
    $file = Join-Path $repo "dsc\resources\$Name.ps1"
    $saved = [Environment]::GetEnvironmentVariables()
    try {
        $stdout = @($Instance | ConvertTo-Json -Compress -Depth 5 | & $file $Operation)
        $exitCode = $LASTEXITCODE
    } finally {
        # A resource sets variables for its own process (WSL_UTF8, PATH), which here is the test's
        foreach ($variable in @([Environment]::GetEnvironmentVariables().Keys)) {
            if ($saved.Keys -notcontains $variable) { [Environment]::SetEnvironmentVariable($variable, [NullString]::Value) }
        }
        foreach ($variable in $saved.Keys) { [Environment]::SetEnvironmentVariable($variable, $saved[$variable]) }
    }
    $json = $stdout | Where-Object { $_ } | Select-Object -Last 1
    [pscustomobject]@{
        ExitCode = $exitCode
        State    = if ($json) { $json | ConvertFrom-Json }
    }
}

# DSC's own schema for the entries of `_restartRequired` (`dsc schema -t restart-required`, from the dsc that mise pins).
# DSC doesn't reject an entry that doesn't fit it: it logs a warning and the restart goes unreported (checked
# 2026-11-18 with DSC 3.3.0), so a test has to. Read once; the run fails, rather than skips, when dsc isn't found
function Get-RestartRequiredSchema {
    if (-not $script:restartRequiredSchema) {
        if (-not (Get-Command dsc -ErrorAction SilentlyContinue)) { throw 'dsc is needed for its restart-required schema; run the tests through `just test`' }
        $script:restartRequiredSchema = (dsc schema -t restart-required | Out-String)
    }
    $script:restartRequiredSchema
}

# Passes when every entry of the state's `_restartRequired` fits DSC's schema, and there is at least one
function Assert-RestartRequiredSchema($State) {
    $entries = @($State._restartRequired)
    $entries | Should -Not -BeNullOrEmpty
    $schema = Get-RestartRequiredSchema
    foreach ($entry in $entries) {
        ($entry | ConvertTo-Json -Compress -Depth 5) | Test-Json -Schema $schema | Should -BeTrue -Because "DSC's schema must accept $($entry | ConvertTo-Json -Compress)"
    }
}

# A fake Scoop root (tests/fakes/scoop.ps1 in place of Scoop itself) with -Installed apps ('name' or 'bucket/name')
# and -Buckets already there. -Failing apps and -FailingBuckets fail to install, and -NoScoop leaves Scoop out.
# Pass .Environment to Invoke-Resource, and read the calls Scoop got with Get-FakeScoopCalls.
function New-FakeScoop {
    param([string[]]$Installed = @(), [string[]]$Buckets = @(), [string[]]$Failing = @(), [string[]]$FailingBuckets = @(),
        [switch]$NoScoop)
    $root = New-Item -ItemType Directory (Join-Path $TestDrive "scoop-$([guid]::NewGuid())")
    if (-not $NoScoop) {
        $bin = New-Item -ItemType Directory (Join-Path $root 'apps\scoop\current\bin')
        Copy-Item (Join-Path $fakes 'scoop.ps1') $bin
    }
    @{ failing = $Failing; failingBuckets = $FailingBuckets } | ConvertTo-Json | Set-Content (Join-Path $root 'fake-scoop.json')
    foreach ($bucket in $Buckets) { New-Item -ItemType Directory (Join-Path $root "buckets\$bucket") | Out-Null }
    foreach ($app in $Installed) {
        $bucket, $name = if ($app -match '/') { $app -split '/', 2 } else { 'main', $app }
        $current = New-Item -ItemType Directory -Force (Join-Path $root "apps\$name\current")
        @{ bucket = $bucket } | ConvertTo-Json | Set-Content (Join-Path $current 'scoop-install.json')
    }
    [pscustomobject]@{
        Path        = $root.FullName
        Environment = @{ SCOOP = $root.FullName }
    }
}

# A web server on a free loopback port that answers every request with -File's content, or with -Status and no body,
# for resources that download something. Invoke-WebRequest has no file:// support, and a TcpListener needs no
# elevation, unlike HttpListener. Each request line is logged; read them with Get-FakeWebRequests, and stop the
# server with Stop-FakeWebServer.
function Start-FakeWebServer {
    param([string]$File, [int]$Status = 200)
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $log = Join-Path $TestDrive "web-$([guid]::NewGuid()).log"
    $body = if ($File -and $Status -eq 200) { [IO.File]::ReadAllBytes($File) } else { [byte[]]@() }
    $control = [hashtable]::Synchronized(@{ Stop = $false })
    $job = Start-ThreadJob {
        $listener, $log, $status, $control = $using:listener, $using:log, $using:Status, $using:control
        [byte[]]$body = $using:body
        # A blocking AcceptTcpClient doesn't return when the listener stops, so poll until Stop-FakeWebServer says
        while (-not $control.Stop) {
            if (-not $listener.Pending()) {
                Start-Sleep -Milliseconds 20
                continue
            }
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $reader = [IO.StreamReader]::new($stream)
                Add-Content $log $reader.ReadLine()
                while ($reader.ReadLine()) {}
                $header = "HTTP/1.1 $status Fake`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
                [byte[]]$headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($headerBytes, 0, $headerBytes.Length)
                $stream.Write($body, 0, $body.Length)
                $stream.Flush()
            } finally {
                $client.Close()
            }
        }
    }
    [pscustomobject]@{
        Url      = "http://127.0.0.1:$($listener.LocalEndpoint.Port)"
        Log      = $log
        Listener = $listener
        Control  = $control
        Job      = $job
    }
}

function Get-FakeWebRequests($Server) {
    if (Test-Path $Server.Log) { @(Get-Content $Server.Log) } else { @() }
}

function Stop-FakeWebServer($Server) {
    $Server.Control.Stop = $true
    $Server.Job | Wait-Job -Timeout 5 | Out-Null
    $Server.Listener.Stop()
    $Server.Job | Remove-Job -Force
}

function Get-FakeScoopCalls($Fake) {
    $calls = Join-Path $Fake.Path 'fake-scoop-calls.txt'
    if (Test-Path $calls) { @(Get-Content $calls) } else { @() }
}
