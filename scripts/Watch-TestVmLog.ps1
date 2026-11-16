#Requires -Version 7
#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

<#
.SYNOPSIS
    Follows the winget and installer logs of a running test VM.

.DESCRIPTION
    Connects over PowerShell Direct, signing in with the local administrator
    that New-TestVm.ps1 -Unattended keeps in the VM's notes; for a VM
    installed by hand, pass -Credential. Each package adds new files to
    winget's DiagOutputDir, so this follows every file written to since a
    minute before it started, with a header when the output moves to another
    file. It says which folder it follows, and notes every 30 seconds with
    nothing new, so a quiet run can be told from a stuck one. Scoop and DSC
    don't write there, so their lines don't show.
    A VM that isn't running fails. Once following, a guest restart reconnects,
    and the script exits when the VM stops. Press Ctrl+C to stop following.

.PARAMETER Name
    The name of the VM.

.PARAMETER Tail
    How many lines to show of a file that already existed at the start.

.PARAMETER Credential
    The VM's administrator, for a VM not made with -Unattended.

.EXAMPLE
    gsudo pwsh -File .\scripts\Watch-TestVmLog.ps1 -Name winfiles-test -Tail 50
#>
[CmdletBinding()]
param(
    [string]$Name = 'winfiles-test',
    [int]$Tail = 20,
    [pscredential]$Credential
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'testvm.ps1')

# Runs in the VM, where PowerShell Direct gives Windows PowerShell 5.1, so its functions are defined inside it.
# Each file is opened on every poll, because a directory listing can lag behind a writer that keeps its handle open.
$watch = {
    param(
        [int]$Tail,
        [string]$Directory = "$env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_*\LocalState\DiagOutputDir",
        # Stop after this many polls, for tests/scripts/Watch-TestVmLog.Tests.ps1; 0 follows until the session ends
        [int]$Polls = 0,
        # Print a note after this many polls (2s each) with no new lines, so quiet can be told from stuck; 0 for none
        [int]$Heartbeat = 15
    )
    # Opens a log alongside its writer, or returns nothing while it's locked or deleted, to try again on the next poll
    function Open-Log([string]$Path) {
        try {
            [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite,Delete')
        } catch [IO.IOException], [UnauthorizedAccessException] {}
    }

    # The encoding the byte order mark names, and the offset of the text after it
    function Read-ByteOrderMark([IO.FileStream]$Stream) {
        $mark = [byte[]]::new(3)
        [void]$Stream.Read($mark, 0, 3)
        if ($mark[0] -eq 0xFF -and $mark[1] -eq 0xFE) { [Text.Encoding]::Unicode, 2 }
        elseif ($mark[0] -eq 0xFE -and $mark[1] -eq 0xFF) { [Text.Encoding]::BigEndianUnicode, 2 }
        elseif ($mark[0] -eq 0xEF -and $mark[1] -eq 0xBB -and $mark[2] -eq 0xBF) { [Text.Encoding]::UTF8, 3 }
        else { [Text.Encoding]::UTF8, 0 }
    }

    # Where to start following a file: a file from before $Started shows its last lines, and a newer one all of them.
    # Returns nothing for a file too short to have a whole byte order mark yet
    function New-FollowedLog([IO.FileInfo]$Entry, [IO.FileStream]$Stream, [datetime]$Started) {
        # Enough for the last lines of a file that already exists, without reading all of a large MSI log
        $tailBytes = 64KB
        if ($Stream.Length -lt 3) { return }
        $encoding, $offset = Read-ByteOrderMark $Stream
        $existed = $Entry.CreationTime -lt $Started
        $midFile = $existed -and $Stream.Length - $offset -gt $tailBytes
        if ($midFile) {
            $offset = $Stream.Length - $tailBytes
            # Stay on a character boundary in UTF-16
            if ($encoding -ne [Text.Encoding]::UTF8) { $offset -= $offset % 2 }
        }
        @{ Offset = $offset; Decoder = $encoding.GetDecoder(); Partial = ''; Existed = $existed; MidFile = $midFile }
    }

    # The lines completed since the last read. Only the bytes past the offset are read. The decoder keeps a
    # character split across two reads, and Partial a line that hasn't ended
    function Read-NewLogLine([hashtable]$Log, [IO.FileStream]$Stream, [int]$Tail) {
        if ($Stream.Length -le $Log.Offset) { return }
        $Stream.Position = $Log.Offset
        $bytes = [byte[]]::new($Stream.Length - $Log.Offset)
        $count = $Stream.Read($bytes, 0, $bytes.Length)
        $Log.Offset += $count
        $chars = [char[]]::new($Log.Decoder.GetCharCount($bytes, 0, $count))
        $length = $Log.Decoder.GetChars($bytes, 0, $count, $chars, 0)
        $lines = @(($Log.Partial + [string]::new($chars, 0, $length)) -split '\r?\n')
        $Log.Partial = $lines[-1]
        $lines = @($lines | Select-Object -SkipLast 1)
        # The first line after starting mid-file is only the end of a line
        if ($Log.MidFile -and $lines) { $lines = @($lines | Select-Object -Skip 1); $Log.MidFile = $false }
        if ($Log.Existed) {
            $lines = @($lines | Select-Object -Last $Tail)
            $Log.Existed = $false
        }
        $lines
    }

    $started = Get-Date
    $since = $started.AddMinutes(-1)
    $logs = @{}
    $current = $null
    $poll = 0
    $where = $null
    $idle = 0       # polls since a log had new lines
    $sinceNote = 0  # polls since anything was printed
    while (-not $Polls -or $poll -lt $Polls) {
        $poll++
        $printed = $false
        # Resolved first: with a wildcard in the middle of the path, Get-ChildItem lists the matching folder itself, not its files
        $folders = @(Resolve-Path $Directory -ErrorAction Ignore | ForEach-Object Path)
        # Status lines start with "-- ", apart from the log lines
        if (($folders -join ', ') -ne $where) {
            $where = $folders -join ', '
            if ($where) { "-- following $where" } else { "-- waiting for $Directory to exist" }
            $printed = $true
        }
        foreach ($entry in $folders | ForEach-Object { Get-ChildItem -LiteralPath $_ -File -Filter *.log -ErrorAction Ignore } | Sort-Object CreationTime) {
            $log = $logs[$entry.FullName]
            if (-not $log -and $entry.CreationTime -lt $since -and $entry.LastWriteTime -lt $since) { continue }
            $stream = Open-Log $entry.FullName
            if (-not $stream) { continue }
            try {
                if (-not $log) {
                    $log = New-FollowedLog $entry $stream $started
                    if (-not $log) { continue }
                    $logs[$entry.FullName] = $log
                }
                $lines = @(Read-NewLogLine $log $stream $Tail)
                if ($lines) {
                    if ($current -ne $entry.FullName) {
                        "`n==> $($entry.Name) <=="
                        $current = $entry.FullName
                    }
                    $lines
                    $printed = $true
                    $idle = -1
                }
            } finally {
                $stream.Dispose()
            }
        }
        $idle++
        $sinceNote = if ($printed) { 0 } else { $sinceNote + 1 }
        if ($Heartbeat -and $sinceNote -ge $Heartbeat) {
            "-- no new lines for about $($idle * 2)s"
            $sinceNote = 0
        }
        if (-not $Polls -or $poll -lt $Polls) { Start-Sleep 2 }
    }
}

# A guest restart ends the session but leaves the VM Running, so keep reconnecting until the VM stops
function Watch-VmLog([string]$Name, [pscredential]$Credential, [int]$Tail) {
    $again = $false
    while ($true) {
        try {
            # The watch's first poll always prints a status line, so its first output shows the session is back
            Invoke-Command -VMName $Name -Credential $Credential $watch -ArgumentList $Tail | ForEach-Object {
                if ($again) { "-- reconnected to '$Name'"; $again = $false }
                $_
            }
        } catch {
            Write-Warning "Lost the connection to '$Name', retrying: $($_.Exception.Message)"
            Start-Sleep 5
        }
        $state = (Get-VM -Name $Name).State
        if ($state -ne 'Running') {
            "VM '$Name' stopped (state: $state)."
            return
        }
        $again = $true
    }
}

try {
    $Credential = Get-RunningTestVmCredential $Name $Credential
} catch {
    [Console]::Error.WriteLine("$_")
    exit 1
}
Watch-VmLog $Name $Credential $Tail
