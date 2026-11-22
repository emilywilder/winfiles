#Requires -Version 7
#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

<#
.SYNOPSIS
    Follows the run log of a running test VM, and with -All its winget and
    installer logs too.

.DESCRIPTION
    Connects over PowerShell Direct, signing in with the local administrator
    that New-TestVm.ps1 -Unattended keeps in the VM's notes; for a VM
    installed by hand, pass -Credential. By default it follows run.log in
    ~\.local\state\winfiles, where the bootstrap and the install write what
    phase they are in and when they start and finish (scripts/winlog.ps1).
    With -All it also follows winget's DiagOutputDir: each package adds new
    files there, so it follows every file written to since a minute before it
    started, with a header when the output moves to another file. It says
    which folders it follows, and notes every 30 seconds with nothing new, so
    a quiet run can be told from a stuck one. Scoop and DSC write only to
    run.log, and only at the phase level.
    A VM that isn't running fails. Once following, a guest restart reconnects,
    and the script exits when the VM stops. Press Ctrl+C to stop following.

.EXAMPLE
    gsudo pwsh -File .\scripts\Watch-TestVmLog.ps1 -Name winfiles-test -Tail 50 -All

    Follows the run log and winget's logs in winfiles-test, starting from the last 50 lines of each.
#>
[CmdletBinding()]
param(
    # The name of the VM.
    [string]$Name = 'winfiles-test',

    # How many lines to show of a file that already existed at the start.
    [int]$Tail = 20,

    # The VM's administrator, for a VM not made with -Unattended.
    [pscredential]$Credential,

    # Also follow winget's and the installers' logs, for the detail behind a failed package.
    [switch]$All
)

$ErrorActionPreference = 'Stop'
try {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'testvm.ps1')

    # Runs in the VM, where PowerShell Direct gives Windows PowerShell 5.1, so its functions are defined inside it.
    # Each file is opened on every poll, because a directory listing can lag behind a writer that keeps its handle
    # open.
    $watch = {
        [CmdletBinding()]
        param(
            # How many lines to show of a file that already existed at the start.
            [int]$Tail,

            # Also follow winget's logs, in $Directory. Second, so that Invoke-Command's -ArgumentList can pass it
            # by position.
            [bool]$All = $false,

            # winget's log folder.
            [string]$Directory = (
                "$env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_*\LocalState\DiagOutputDir"),

            # The folder of run.log, which Write-WinfilesLog appends to: Windows PowerShell writes the bootstrap's
            # lines in the ANSI code page and pwsh the install's in UTF-8 without a mark, but they are ASCII, so
            # reading it as UTF-8 is right.
            [string]$RunLogFolder = "$env:USERPROFILE\.local\state\winfiles",

            # Stop after this many polls, for tests/scripts/Watch-TestVmLog.Tests.ps1; 0 follows until the session
            # ends.
            [int]$Polls = 0,

            # Print a note after this many polls (2s each) with no new lines, so quiet can be told from stuck; 0
            # for none.
            [int]$Heartbeat = 15
        )


        function Open-Log {
            <#
            .SYNOPSIS
            Opens a log alongside its writer, or returns nothing while it's locked or deleted, to try again on the
            next poll.
            #>
            [CmdletBinding()]
            [OutputType([IO.FileStream])]
            param(
                # The log's path.
                [Parameter(Mandatory)]
                [string]$Path
            )

            try {
                $share = [IO.FileShare]'ReadWrite,Delete'
                [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
            } catch [IO.IOException], [UnauthorizedAccessException] {
                $failure = $_
                Write-Verbose -Message "Not open yet: $($failure.Exception.Message)"
            }
        }


        function Read-ByteOrderMark {
            <#
            .SYNOPSIS
            Returns the encoding a file's byte order mark names, and the offset of the text after it.
            #>
            [CmdletBinding()]
            [OutputType([array])]
            param(
                # The open file, at its start.
                [Parameter(Mandatory)]
                [IO.FileStream]$Stream
            )

            $mark = [byte[]]::new(3)
            [void]$Stream.Read($mark, 0, 3)
            if ($mark[0] -eq 0xFF -and $mark[1] -eq 0xFE) {
                [Text.Encoding]::Unicode, 2
            } elseif ($mark[0] -eq 0xFE -and $mark[1] -eq 0xFF) {
                [Text.Encoding]::BigEndianUnicode, 2
            } elseif ($mark[0] -eq 0xEF -and $mark[1] -eq 0xBB -and $mark[2] -eq 0xBF) {
                [Text.Encoding]::UTF8, 3
            } else {
                [Text.Encoding]::UTF8, 0
            }
        }


        function New-FollowedLog {
            <#
            .SYNOPSIS
            Returns where to start following a file: a file from before $Started shows its last lines, and a newer
            one all of them.

            .DESCRIPTION
            Returns nothing for a file too short to have a whole byte order mark yet. It only reads the file.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'It makes an object in memory, and changes nothing')]
            [CmdletBinding()]
            [OutputType([hashtable])]
            param(
                # The file.
                [Parameter(Mandatory)]
                [IO.FileInfo]$Entry,

                # The file, open.
                [Parameter(Mandatory)]
                [IO.FileStream]$Stream,

                # When the watch started.
                [Parameter(Mandatory)]
                [datetime]$Started
            )

            # Enough for the last lines of a file that already exists, without reading all of a large MSI log
            $tailBytes = 64KB
            if ($Stream.Length -ge 3) {
                $encoding, $offset = Read-ByteOrderMark -Stream $Stream
                $existed = $Entry.CreationTime -lt $Started
                $midFile = $existed -and $Stream.Length - $offset -gt $tailBytes
                if ($midFile) {
                    $offset = $Stream.Length - $tailBytes
                    # Stay on a character boundary in UTF-16
                    if ($encoding -ne [Text.Encoding]::UTF8) {
                        $offset -= $offset % 2
                    }
                }
                @{
                    Offset  = $offset
                    Decoder = $encoding.GetDecoder()
                    Partial = ''
                    Existed = $existed
                    MidFile = $midFile
                }
            }
        }


        function Read-NewLogLine {
            <#
            .SYNOPSIS
            Returns the lines a log completed since the last read.

            .DESCRIPTION
            Only the bytes past the offset are read. The decoder keeps a character split across two reads, and
            Partial a line that hasn't ended.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param(
                # The log, from New-FollowedLog.
                [Parameter(Mandatory)]
                [hashtable]$Log,

                # The file, open.
                [Parameter(Mandatory)]
                [IO.FileStream]$Stream,

                # How many lines to show of a file that already existed at the start.
                [Parameter(Mandatory)]
                [int]$Tail
            )

            if ($Stream.Length -gt $Log.Offset) {
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
                if ($Log.MidFile -and $lines) {
                    $lines = @($lines | Select-Object -Skip 1)
                    $Log.MidFile = $false
                }
                if ($Log.Existed) {
                    $lines = @($lines | Select-Object -Last $Tail)
                    $Log.Existed = $false
                }
                $lines
            }
        }


        $started = Get-Date
        $since = $started.AddMinutes(-1)
        $logs = @{}
        $current = $null
        $poll = 0
        $where = $null
        $idle = 0       # polls since a log had new lines
        $sinceNote = 0  # polls since anything was printed
        # run.log is one file for every run, so it isn't skipped for being old: it shows its last lines, then
        # follows. Winget starts a file per package, so only the ones written to since a minute before the start
        # count
        $sources = @()
        if ($RunLogFolder) {
            $sources += @{ Path = $RunLogFolder; Filter = 'run.log'; Recent = $false }
        }
        if ($All) {
            $sources += @{ Path = $Directory; Filter = '*.log'; Recent = $true }
        }
        while (-not $Polls -or $poll -lt $Polls) {
            $poll++
            $printed = $false
            $folders = @()
            $entries = @()
            foreach ($source in $sources) {
                # Resolved first: with a wildcard in the middle of the path, Get-ChildItem lists the matching
                # folder itself, not its files
                $resolved = @(Resolve-Path -Path $source.Path -ErrorAction Ignore |
                        ForEach-Object -MemberName Path)
                $folders += $resolved
                $entries += @($resolved |
                        ForEach-Object -Process {
                            Get-ChildItem -LiteralPath $_ -File -Filter $source.Filter -ErrorAction Ignore
                        } |
                        Sort-Object -Property CreationTime |
                        ForEach-Object -Process { @{ Entry = $_; Recent = $source.Recent } })
            }
            # Status lines start with "-- ", apart from the log lines
            if (($folders -join ', ') -ne $where) {
                $where = $folders -join ', '
                if ($where) {
                    "-- following $where"
                } else {
                    "-- waiting for $(($sources | ForEach-Object -Process { $_.Path }) -join ', ') to exist"
                }
                $printed = $true
            }
            foreach ($item in $entries) {
                $entry = $item.Entry
                $log = $logs[$entry.FullName]
                $old = $entry.CreationTime -lt $since -and $entry.LastWriteTime -lt $since
                if (-not $log -and $item.Recent -and $old) {
                    continue
                }
                $stream = Open-Log -Path $entry.FullName
                if (-not $stream) {
                    continue
                }
                try {
                    if (-not $log) {
                        $log = New-FollowedLog -Entry $entry -Stream $stream -Started $started
                        if (-not $log) {
                            continue
                        }
                        $logs[$entry.FullName] = $log
                    }
                    $lines = @(Read-NewLogLine -Log $log -Stream $stream -Tail $Tail)
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
            if (-not $Polls -or $poll -lt $Polls) {
                Start-Sleep -Seconds 2
            }
        }
    }


    function Watch-VmLog {
        <#
        .SYNOPSIS
        Follows the VM's logs until it stops, reconnecting after a guest restart, which ends the session but leaves
        the VM Running.
        #>
        [CmdletBinding()]
        param(
            # The VM's name.
            [Parameter(Mandatory)]
            [string]$Name,

            # The VM's administrator.
            [Parameter(Mandatory)]
            [pscredential]$Credential,

            # How many lines to show of a file that already existed at the start.
            [Parameter(Mandatory)]
            [int]$Tail,

            # Also follow winget's logs.
            [bool]$All = $false
        )

        $again = $false
        $running = $true
        while ($running) {
            try {
                # The watch's first poll always prints a status line, so its first output shows the session is
                # back. The host's own messages are in colour and set apart from the log lines, which come from the
                # VM
                $remote = @{
                    VMName       = $Name
                    Credential   = $Credential
                    ScriptBlock  = $watch
                    ArgumentList = $Tail, $All
                }
                Invoke-Command @remote | ForEach-Object -Process {
                    if ($again) {
                        Write-Host -Object "`nReconnected to '$Name', following again." -ForegroundColor Green
                        $again = $false
                    }
                    $_
                }
            } catch {
                $failure = $_
                Write-Warning -Message "Lost the connection to '$Name', retrying: $($failure.Exception.Message)"
                Start-Sleep -Seconds 5
            }
            $state = (Get-VM -Name $Name).State
            if ($state -ne 'Running') {
                Write-Warning -Message "VM '$Name' stopped (state: $state)."
                $running = $false
            }
            $again = $true
        }
    }


    try {
        $Credential = Get-RunningTestVmCredential -Name $Name -Credential $Credential
    } catch {
        $failure = $_
        [Console]::Error.WriteLine("$failure")
        exit 1
    }
    Watch-VmLog -Name $Name -Credential $Credential -Tail $Tail -All $All.IsPresent
} catch {
    # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
    $failure = $_
    throw $failure
} finally {
    $ErrorActionPreference = 'Continue'
}
