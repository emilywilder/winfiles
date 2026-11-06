# Shared by the tests in this folder, which dot-source it in BeforeAll.
# Resources run the way DSC runs them: a child pwsh started with the command in the resource's manifest. What a
# resource talks to is replaced with fakes made of files (tests/fakes), never with mocks, so nothing here can reach
# the real winget or Scoop.
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$fakes = Join-Path $repo 'tests\fakes'

# Runs one operation of a Winfiles/* resource, with -Instance as JSON on stdin and the working directory DSC uses
# (the manifest's folder). -Environment is set for the child only. Returns the exit code, the state the resource
# printed, the messages it wrote as {"<level>": "<text>"} lines, and all of its stderr.
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
    $stderrFile = New-TemporaryFile
    $saved = @{}
    # Not $null: PowerShell passes it as an empty string, which leaves the variable set but empty
    foreach ($variable in $Environment.Keys) {
        $saved[$variable] = [Environment]::GetEnvironmentVariable($variable) ?? [NullString]::Value
        [Environment]::SetEnvironmentVariable($variable, $Environment[$variable] ?? [NullString]::Value)
    }
    Push-Location $resources
    try {
        $stdout = @($Instance | ConvertTo-Json -Compress -Depth 5 | & $command.executable @($command.args) 2> $stderrFile)
        $exitCode = $LASTEXITCODE
        $stderr = @(Get-Content $stderrFile)
    } finally {
        Pop-Location
        foreach ($variable in $saved.Keys) { [Environment]::SetEnvironmentVariable($variable, $saved[$variable]) }
        Remove-Item $stderrFile
    }

    $json = $stdout | Where-Object { $_ } | Select-Object -Last 1
    $messages = $stderr | Where-Object { $_ -match '^\{"\w+":' } | ForEach-Object {
        $property = @(($_ | ConvertFrom-Json).PSObject.Properties)[0]
        [pscustomobject]@{ Level = $property.Name; Text = $property.Value }
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        State    = if ($json) { $json | ConvertFrom-Json }
        Messages = @($messages)
        Stderr   = $stderr
    }
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

# A fake winget (tests/fakes/modules/Microsoft.WinGet.Client) with -Installed already installed from the winget
# source, -Failing ids whose install returns -Status, and -Unknown ids whose install throws. -Other ids are installed
# from another source. Pass .Environment to Invoke-Resource, and read what happened with Get-FakeWinGetState.
function New-FakeWinGet {
    param([string[]]$Installed = @(), [string[]]$Other = @(), [string[]]$Failing = @(), [string]$Status = 'InstallError',
        [string[]]$Unknown = @())
    $file = Join-Path $TestDrive "winget-$([guid]::NewGuid()).json"
    $failingStatus = @{}
    foreach ($id in $Failing) { $failingStatus[$id] = $Status }
    [ordered]@{
        installed = @($Installed | ForEach-Object { @{ Id = $_; Source = 'winget' } }) +
            @($Other | ForEach-Object { @{ Id = $_; Source = 'msstore' } })
        failing   = $failingStatus
        unknown   = $Unknown
        installs  = @()
    } | ConvertTo-Json -Depth 4 | Set-Content $file
    [pscustomobject]@{
        Path        = $file
        Environment = @{
            WINFILES_FAKE_WINGET = $file
            PSModulePath         = "$fakes\modules;$env:PSModulePath"
        }
    }
}

function Get-FakeWinGetState($Fake) {
    Get-Content -Raw $Fake.Path | ConvertFrom-Json
}

# Fails unless a child pwsh given $Fake's environment imports the fake Microsoft.WinGet.Client, so a change in how
# pwsh builds PSModulePath can't let a test install real packages
function Assert-FakeWinGetLoads($Fake) {
    $saved = $env:PSModulePath
    $env:PSModulePath = $Fake.Environment.PSModulePath
    try {
        $base = pwsh -NoLogo -NoProfile -NonInteractive -Command '(Import-Module Microsoft.WinGet.Client -PassThru).ModuleBase'
    } finally {
        $env:PSModulePath = $saved
    }
    if ($base -notlike "$fakes\*") { throw "A child pwsh loads Microsoft.WinGet.Client from $base, not the fake" }
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
