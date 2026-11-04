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
    file. Scoop and DSC don't write there, so their lines don't show.
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

# Runs in the VM, where PowerShell Direct gives Windows PowerShell 5.1. Each file is opened on every poll, because
# a directory listing can lag behind a writer that keeps its handle open. Only the bytes past the offset are read.
$watch = {
    param(
        [int]$Tail,
        [string]$Directory = "$env:LOCALAPPDATA\Packages\Microsoft.DesktopAppInstaller_*\LocalState\DiagOutputDir"
    )
    # Enough for the last lines of a file that already exists, without reading all of a large MSI log
    $tailBytes = 64KB
    $started = Get-Date
    $since = $started.AddMinutes(-1)
    $files = @{}
    $current = $null
    while ($true) {
        foreach ($entry in Get-ChildItem $Directory -File -Filter *.log -ErrorAction Ignore | Sort-Object CreationTime) {
            $file = $files[$entry.FullName]
            if (-not $file -and $entry.CreationTime -lt $since -and $entry.LastWriteTime -lt $since) { continue }
            try {
                $stream = [IO.FileStream]::new($entry.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite,Delete')
            } catch [IO.IOException], [UnauthorizedAccessException] {
                # Locked or deleted for now, so try again on the next poll
                continue
            }
            try {
                if (-not $file) {
                    # Too short to have a whole byte order mark yet
                    if ($stream.Length -lt 3) { continue }
                    $mark = [byte[]]::new(3)
                    [void]$stream.Read($mark, 0, 3)
                    $encoding, $offset = if ($mark[0] -eq 0xFF -and $mark[1] -eq 0xFE) { [Text.Encoding]::Unicode, 2 }
                        elseif ($mark[0] -eq 0xFE -and $mark[1] -eq 0xFF) { [Text.Encoding]::BigEndianUnicode, 2 }
                        elseif ($mark[0] -eq 0xEF -and $mark[1] -eq 0xBB -and $mark[2] -eq 0xBF) { [Text.Encoding]::UTF8, 3 }
                        else { [Text.Encoding]::UTF8, 0 }
                    # A file from before the start shows its last lines, and a newer one all of them
                    $existed = $entry.CreationTime -lt $started
                    $midFile = $existed -and $stream.Length - $offset -gt $tailBytes
                    if ($midFile) {
                        $offset = $stream.Length - $tailBytes
                        # Stay on a character boundary in UTF-16
                        if ($encoding -ne [Text.Encoding]::UTF8) { $offset -= $offset % 2 }
                    }
                    $file = @{ Offset = $offset; Decoder = $encoding.GetDecoder(); Partial = ''; Existed = $existed; MidFile = $midFile }
                    $files[$entry.FullName] = $file
                }
                if ($stream.Length -le $file.Offset) { continue }

                $stream.Position = $file.Offset
                $bytes = [byte[]]::new($stream.Length - $file.Offset)
                $count = $stream.Read($bytes, 0, $bytes.Length)
                $file.Offset += $count
                # The decoder keeps a character split across two reads, and Partial a line that hasn't ended
                $chars = [char[]]::new($file.Decoder.GetCharCount($bytes, 0, $count))
                $length = $file.Decoder.GetChars($bytes, 0, $count, $chars, 0)
                $lines = @(($file.Partial + [string]::new($chars, 0, $length)) -split '\r?\n')
                $file.Partial = $lines[-1]
                $lines = @($lines | Select-Object -SkipLast 1)
                # The first line after starting mid-file is only the end of a line
                if ($file.MidFile -and $lines) { $lines = @($lines | Select-Object -Skip 1); $file.MidFile = $false }
                if ($file.Existed) {
                    $lines = @($lines | Select-Object -Last $Tail)
                    $file.Existed = $false
                }
                if ($lines) {
                    if ($current -ne $entry.FullName) {
                        "`n==> $($entry.Name) <=="
                        $current = $entry.FullName
                    }
                    $lines
                }
            } finally {
                $stream.Dispose()
            }
        }
        Start-Sleep 2
    }
}

try {
    $vm = Get-VM -Name $Name
    if ($vm.State -ne 'Running') { throw "VM '$Name' isn't running (state: $($vm.State)). Start it and wait for the desktop first." }
    if (-not $Credential) { $Credential = Get-TestVmCredential $vm }
} catch {
    [Console]::Error.WriteLine("$_")
    exit 1
}

while ($true) {
    # A guest restart ends the session but leaves the VM Running, so keep trying until it's back
    try {
        Invoke-Command -VMName $Name -Credential $Credential $watch -ArgumentList $Tail
    } catch {
        Write-Warning "Lost the connection to '$Name', retrying: $($_.Exception.Message)"
        Start-Sleep 5
    }
    $state = (Get-VM -Name $Name).State
    if ($state -ne 'Running') {
        "VM '$Name' stopped (state: $state)."
        exit 0
    }
}
