# Shared by the scripts that sign in to a test VM over PowerShell Direct, which dot-source it.
# Reads the local administrator that New-TestVm.ps1 -Unattended keeps in the VM's notes:
# "... Local administrator: <user> / <password>", where the password may be empty
function Get-TestVmCredential {
    param([Microsoft.HyperV.PowerShell.VirtualMachine]$VM)
    if ($VM.Notes -notmatch 'Local administrator: (\S+) / (\S*)') {
        throw "VM '$($VM.Name)' has no administrator in its notes (not made with -Unattended?). Pass -Credential."
    }
    $password = if ($Matches[2]) { ConvertTo-SecureString $Matches[2] -AsPlainText -Force } else { [securestring]::new() }
    [pscredential]::new($Matches[1], $password)
}

# Runs a command in the VM's ~\src\winfiles as the VM's user without elevation, and returns its exit code. A PowerShell
# Direct session is always elevated, so the command goes to a scheduled task for that user (logon type Interactive, run
# level Limited), which runs it at Medium integrity in the user's signed-in session, as a terminal on the desktop would.
# The task runs Windows PowerShell 5.1, which is in the VM before the bootstrap; the output is read back while it runs.
# A UAC prompt in the command still shows on the VM's desktop and waits for a click, and a sign-in is needed.
# Returns 3010 when the VM stops answering or the task was stopped, which is what a restart in the command (the install's)
# looks like from here
function Invoke-TestVmUnelevated {
    param([string]$Name, [pscredential]$Credential, [string]$Command)
    $session = New-PSSession -VMName $Name -Credential $Credential
    $offset = 0
    try {
        $files = Invoke-Command $session {
            param($command)
            $id = [guid]::NewGuid().ToString('N')
            $files = @{ Command = Join-Path $env:TEMP "winfiles-$id.command.ps1"; Wrapper = Join-Path $env:TEMP "winfiles-$id.wrapper.ps1"; Output = Join-Path $env:TEMP "winfiles-$id.out.txt" }
            Set-Content $files.Command $command
            # Native commands' stderr lines come through as their text, without PowerShell's error header
            Set-Content $files.Wrapper @"
`$ErrorActionPreference = 'Continue'
`$repo = Join-Path `$HOME 'src\winfiles'
if (Test-Path `$repo) { Set-Location `$repo }
`$global:LASTEXITCODE = 0
& '$($files.Command)' 2>&1 | ForEach-Object { "`$_" } | Out-File '$($files.Output)' -Encoding utf8
exit `$LASTEXITCODE
"@
            Set-Content $files.Output ''
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$($files.Wrapper)`""
            $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName 'winfiles-unelevated' -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask 'winfiles-unelevated'
            $files
        } -ArgumentList $Command
        while ($true) {
            Start-Sleep 2
            $state = Invoke-Command $session {
                param($files, $offset)
                # Out-File holds the file open while the command runs, so read it with sharing allowed
                $stream = [IO.File]::Open($files.Output, 'Open', 'Read', 'ReadWrite')
                try { $text = [IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
                [pscustomobject]@{
                    Running = (Get-ScheduledTask 'winfiles-unelevated').State -eq 'Running'
                    Text    = if ($text.Length -gt $offset) { $text.Substring($offset) } else { '' }
                    Length  = $text.Length
                }
            } -ArgumentList $files, $offset
            if ($state.Text) { Write-Host $state.Text -NoNewline }
            $offset = $state.Length
            if (-not $state.Running) { break }
        }
        $result = Invoke-Command $session {
            $result = (Get-ScheduledTaskInfo 'winfiles-unelevated').LastTaskResult
            Unregister-ScheduledTask 'winfiles-unelevated' -Confirm:$false
            $result
        }
        # LastTaskResult is the exit code of the wrapper, as an unsigned number
        # A restart (or shutdown) stops the task with DBG_TERMINATE_PROCESS, 0x40010004, which just cuts to 4 on its way out
        # (seen 2026-11-18: the install's restart came back as exit 4), so it is reported as the restart it was
        if ([uint32]$result -eq 0x40010004) {
            Write-Warning 'The command was stopped, as it is when it restarts the VM.'
            return 3010
        }
        [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$result), 0)
    } catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
        Write-Warning "The VM stopped answering, as it does when the command restarts it: $($_.Exception.Message)"
        3010
    } finally {
        Remove-PSSession $session -ErrorAction Ignore
    }
}

# The credential to sign in to a VM with, failing unless the VM is running
function Get-RunningTestVmCredential {
    param([string]$Name, [pscredential]$Credential)
    $vm = Get-VM -Name $Name
    if ($vm.State -ne 'Running') { throw "VM '$Name' isn't running (state: $($vm.State)). Start it and wait for the desktop first." }
    if ($Credential) { $Credential } else { Get-TestVmCredential $vm }
}