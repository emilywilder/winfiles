# Runs the scriptblock Watch-TestVmLog.ps1 sends into the VM, under Windows PowerShell 5.1 as PowerShell Direct does,
# against scratch logs. The host side (Get-VM, the reconnect loop) needs a running VM and isn't tested.
BeforeAll {
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    # The runner takes $watch from the script's AST, so the test runs the text that's really sent to the VM
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\..\scripts\Watch-TestVmLog.ps1'), [ref]$null, [ref]$null)
    $assignment = $ast.Find({ param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$watch' }, $true)
    $runner = Join-Path $TestDrive 'runner.ps1'
    # utf8BOM, because Windows PowerShell reads a file without one as ANSI
    Set-Content $runner -Encoding utf8BOM -Value @"
param([string]`$Directory, [int]`$Tail, [int]`$Polls, [int]`$Heartbeat)
`$watch = $($assignment.Right.Extent.Text)
& `$watch -Tail `$Tail -Directory `$Directory -Polls `$Polls -Heartbeat `$Heartbeat
"@

    function New-LogFolder { (New-Item -ItemType Directory (Join-Path $TestDrive "logs-$([guid]::NewGuid())")).FullName }

    # A log written as the given encoding, with its creation time set so that it counts as already there when the watch starts
    function Write-Log([string]$Folder, [string]$Name, [string]$Text, [Text.Encoding]$Encoding = [Text.UTF8Encoding]::new($true), [switch]$Append, [datetime]$Created = (Get-Date).AddMinutes(-10)) {
        $path = Join-Path $Folder $Name
        $bytes = if ($Append -or -not $Encoding.GetPreamble()) { $Encoding.GetBytes($Text) } else { $Encoding.GetPreamble() + $Encoding.GetBytes($Text) }
        if ($Append) {
            $stream = [IO.File]::Open($path, 'Append', 'Write', 'ReadWrite')
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        } else {
            [IO.File]::WriteAllBytes($path, $bytes)
            (Get-Item $path).CreationTime = $Created
        }
    }

    # Polls the folder $Polls times (once by default), and returns what it printed, without the "-- " status lines unless -Status
    function Watch-Log([string]$Folder, [int]$Tail = 20, [int]$Polls = 1, [int]$Heartbeat = 0, [switch]$Status) {
        $out = @(& $powershell -NoProfile -NonInteractive -File $runner -Directory $Folder -Tail $Tail -Polls $Polls -Heartbeat $Heartbeat)
        if ($Status) { $out } else { @($out | Where-Object { $_ -notlike '-- *' }) }
    }

    # Polls twice, running $Between once $After (the last line the first poll prints) has shown, which is the only
    # way to write to a log between two polls. Returns all the output
    function Watch-LogAround([string]$Folder, [string]$After, [scriptblock]$Between) {
        $out = Join-Path $TestDrive "out-$([guid]::NewGuid()).txt"
        $process = Start-Process $powershell -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-File', "`"$runner`"", '-Directory', "`"$Folder`"", '-Tail', '20', '-Polls', '2', '-Heartbeat', '0')
        try {
            $deadline = (Get-Date).AddSeconds(30)
            while (-not ((Get-Content $out -ErrorAction Ignore) -contains $After) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 100 }
            & $Between
            if (-not $process.WaitForExit(30000)) { throw 'The watch did not end after its second poll.' }
        } finally {
            if (-not $process.HasExited) { $process.Kill() }
        }
        @(Get-Content $out | Where-Object { $_ -notlike '-- *' })
    }
}

Describe 'Watch-TestVmLog.ps1' {
    It 'shows the last lines of a log from before it started, under a header' {
        $folder = New-LogFolder
        Write-Log $folder 'a.log' "one`r`ntwo`r`nthree`r`nfour`r`n"
        Watch-Log $folder -Tail 2 | Should -Be @('', '==> a.log <==', 'three', 'four')
    }

    It 'skips a log that nothing has written to for a minute' {
        $folder = New-LogFolder
        Write-Log $folder 'old.log' "stale`r`n"
        (Get-Item (Join-Path $folder 'old.log')).LastWriteTime = (Get-Date).AddMinutes(-10)
        Write-Log $folder 'live.log' "fresh`r`n"
        Watch-Log $folder | Should -Be @('', '==> live.log <==', 'fresh')
    }

    It 'finds the logs through a wildcard in the folder path, like its default' {
        $folder = New-LogFolder
        $inner = (New-Item -ItemType Directory (Join-Path $folder 'Package_1\LocalState\DiagOutputDir')).FullName
        Write-Log $inner 'a.log' "one`r`n"
        Watch-Log (Join-Path $folder 'Package_*\LocalState\DiagOutputDir') | Should -Be @('', '==> a.log <==', 'one')
    }

    It 'shows nothing, without failing, while the folder does not exist yet' {
        Watch-Log (Join-Path (New-LogFolder) 'Package_*\DiagOutputDir') | Should -BeNullOrEmpty
        $LASTEXITCODE | Should -Be 0
    }

    It 'says which folder it follows, once' {
        $folder = New-LogFolder
        Write-Log $folder 'a.log' "one
"
        $out = Watch-Log $folder -Polls 2 -Status
        $out | Should -Be @("-- following $folder", '', '==> a.log <==', 'one')
    }

    It 'says it is waiting while the folder does not exist, then which folder it follows' {
        $folder = New-LogFolder
        $later = Join-Path $folder 'later'
        (Watch-Log $later -Status) | Should -Be "-- waiting for $later to exist"
    }

    It 'notes the quiet once the polls set for it have passed with nothing printed' {
        $folder = New-LogFolder
        Watch-Log $folder -Polls 3 -Heartbeat 2 -Status | Select-Object -Skip 1 | Should -Be @('-- no new lines for about 6s')
    }

    It 'ignores files that are not logs' {
        $folder = New-LogFolder
        Write-Log $folder 'notes.txt' "not a log`r`n"
        Watch-Log $folder | Should -BeNullOrEmpty
    }

    It 'reads a log written as <Label>' -ForEach @(
        @{ Label = 'UTF-16 with a byte order mark'; Encoding = [Text.UnicodeEncoding]::new($false, $true) }
        @{ Label = 'big-endian UTF-16'; Encoding = [Text.UnicodeEncoding]::new($true, $true) }
        @{ Label = 'UTF-8 with a byte order mark'; Encoding = [Text.UTF8Encoding]::new($true) }
        @{ Label = 'UTF-8 without one'; Encoding = [Text.UTF8Encoding]::new($false) }
    ) {
        $folder = New-LogFolder
        Write-Log $folder 'a.log' "alpha`r`nbeta`n" $Encoding
        Watch-Log $folder | Should -Be @('', '==> a.log <==', 'alpha', 'beta')
    }

    It 'shows the last lines of a large UTF-16 log, without the line the cut falls in' {
        $folder = New-LogFolder
        # About 100KB, so only its last 64KB is read, and the cut falls inside a line
        $lines = 1..3000 | ForEach-Object { 'line {0:D5} of a long log' -f $_ }
        Write-Log $folder 'big.log' (($lines -join "`r`n") + "`r`n") ([Text.UnicodeEncoding]::new($false, $true))
        # A Tail larger than the 64KB window shows all of it, so a cut line would be its first
        $shown = @(Watch-Log $folder -Tail 5000 | Select-Object -Skip 2)
        $shown.Count | Should -BeLessThan 3000
        $shown.Count | Should -BeGreaterThan 1000
        $shown | Should -Be $lines[(3000 - $shown.Count)..2999]
    }

    It 'holds back a line that has not ended until the next write finishes it' {
        $folder = New-LogFolder
        Write-Log $folder 'a.log' "first`r`nsec"
        $out = Watch-LogAround $folder 'first' { Write-Log $folder 'a.log' "ond`r`nthird`r`n" -Append }
        $out | Should -Be @('', '==> a.log <==', 'first', 'second', 'third')
    }

    It 'shows a header each time the output moves to another log' {
        $folder = New-LogFolder
        Write-Log $folder 'a.log' "a1`r`n" -Created (Get-Date).AddMinutes(-20)
        Write-Log $folder 'b.log' "b1`r`n" -Created (Get-Date).AddMinutes(-10)
        $out = Watch-LogAround $folder 'b1' {
            Write-Log $folder 'b.log' "b2`r`n" -Append
            Write-Log $folder 'a.log' "a2`r`n" -Append
        }
        # The second poll visits a.log first, then b.log, so the output returns to each
        $out | Should -Be @('', '==> a.log <==', 'a1', '', '==> b.log <==', 'b1', '', '==> a.log <==', 'a2', '', '==> b.log <==', 'b2')
    }
}
