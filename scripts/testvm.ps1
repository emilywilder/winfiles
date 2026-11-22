# Shared by the scripts that sign in to a test VM over PowerShell Direct, which dot-source it.


function Get-TestVmCredential {
    <#
    .SYNOPSIS
    Returns the local administrator New-TestVm.ps1 -Unattended keeps in a VM's notes.

    .DESCRIPTION
    The notes say "... Local administrator: <user> / <password>", where the password may be empty. It's a test VM's
    throwaway account, written there in plain text on purpose, so the plain-text conversion is expected.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = "A test VM's throwaway password, kept in its notes on purpose")]
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        # The VM.
        [Parameter(Mandatory)]
        [Microsoft.HyperV.PowerShell.VirtualMachine]$VM
    )

    if ($VM.Notes -notmatch 'Local administrator: (\S+) / (\S*)') {
        throw "VM '$($VM.Name)' has no administrator in its notes (not made with -Unattended?). Pass -Credential."
    }
    $password = if ($Matches[2]) {
        ConvertTo-SecureString -String $Matches[2] -AsPlainText -Force
    } else {
        [securestring]::new()
    }
    [pscredential]::new($Matches[1], $password)
}


function Invoke-TestVmUnelevated {
    <#
    .SYNOPSIS
    Runs a command in a VM's ~\src\winfiles as the VM's user without elevation, and returns its exit code.

    .DESCRIPTION
    A PowerShell Direct session is always elevated, so the command goes to a scheduled task for that user (logon
    type Interactive, run level Limited), which runs it at Medium integrity in the user's signed-in session, as a
    terminal on the desktop would. The task runs Windows PowerShell 5.1, which is in the VM before the bootstrap;
    the output is read back while it runs. A UAC prompt in the command still shows on the VM's desktop and waits
    for a click, and a sign-in is needed. Returns 3010 when the VM stops answering or the task was stopped, which
    is what a restart in the command (the install's) looks like from here.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '',
        Justification = 'The remote scriptblock declares its own param() and gets it through -ArgumentList')]
    [CmdletBinding()]
    [OutputType([int])]
    param(
        # The VM's name.
        [Parameter(Mandatory)]
        [string]$Name,

        # The VM's user.
        [Parameter(Mandatory)]
        [pscredential]$Credential,

        # The command, for Windows PowerShell 5.1.
        [Parameter(Mandatory)]
        [string]$Command
    )

    $session = New-PSSession -VMName $Name -Credential $Credential
    $offset = 0
    $exitCode = 3010
    try {
        $files = Invoke-Command -Session $session -ArgumentList $Command -ScriptBlock {
            param($commandText)
            $id = [guid]::NewGuid().ToString('N')
            $files = @{
                Command = Join-Path -Path $env:TEMP -ChildPath "winfiles-$id.command.ps1"
                Wrapper = Join-Path -Path $env:TEMP -ChildPath "winfiles-$id.wrapper.ps1"
                Output  = Join-Path -Path $env:TEMP -ChildPath "winfiles-$id.out.txt"
            }
            Set-Content -Path $files.Command -Value $commandText
            # Native commands' stderr lines come through as their text, without PowerShell's error header
            Set-Content -Path $files.Wrapper -Value @"
`$ErrorActionPreference = 'Continue'
`$repo = Join-Path -Path `$HOME -ChildPath 'src\winfiles'
if (Test-Path -Path `$repo) { Set-Location -Path `$repo }
`$Global:LASTEXITCODE = 0
& '$($files.Command)' 2>&1 |
    ForEach-Object -Process { "`$_" } |
    Out-File -FilePath '$($files.Output)' -Encoding utf8
exit `$LASTEXITCODE
"@
            Set-Content -Path $files.Output -Value ''
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
                "-NoProfile -ExecutionPolicy Bypass -File `"$($files.Wrapper)`"")
            $user = @{
                UserId    = "$env:COMPUTERNAME\$env:USERNAME"
                LogonType = 'Interactive'
                RunLevel  = 'Limited'
            }
            $principal = New-ScheduledTaskPrincipal @user
            $task = @{ TaskName = 'winfiles-unelevated'; Action = $action; Principal = $principal; Force = $true }
            Register-ScheduledTask @task | Out-Null
            Start-ScheduledTask -TaskName 'winfiles-unelevated'
            $files
        }
        do {
            Start-Sleep -Seconds 2
            $state = Invoke-Command -Session $session -ArgumentList $files, $offset -ScriptBlock {
                param($files, $offset)
                # Out-File holds the file open while the command runs, so read it with sharing allowed
                $stream = [IO.File]::Open($files.Output, 'Open', 'Read', 'ReadWrite')
                try {
                    $text = [IO.StreamReader]::new($stream).ReadToEnd()
                } finally {
                    $stream.Dispose()
                }
                [pscustomobject]@{
                    Running = (Get-ScheduledTask -TaskName 'winfiles-unelevated').State -eq 'Running'
                    Text    = if ($text.Length -gt $offset) { $text.Substring($offset) } else { '' }
                    Length  = $text.Length
                }
            }
            if ($state.Text) {
                Write-Host -Object $state.Text -NoNewline
            }
            $offset = $state.Length
        } while ($state.Running)
        $result = Invoke-Command -Session $session -ScriptBlock {
            $result = (Get-ScheduledTaskInfo -TaskName 'winfiles-unelevated').LastTaskResult
            Unregister-ScheduledTask -TaskName 'winfiles-unelevated' -Confirm:$false
            $result
        }
        # LastTaskResult is the exit code of the wrapper, as an unsigned number
        # A restart (or shutdown) stops the task with DBG_TERMINATE_PROCESS, 0x40010004, which just cuts to 4 on
        # its way out (seen 2026-11-18: the install's restart came back as exit 4), so it is reported as the
        # restart it was
        if ([uint32]$result -eq 0x40010004) {
            Write-Warning -Message 'The command was stopped, as it is when it restarts the VM.'
        } else {
            $exitCode = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$result), 0)
        }
    } catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
        $failure = $_
        Write-Warning -Message (
            "The VM stopped answering, as it does when the command restarts it: $($failure.Exception.Message)")
    } finally {
        Remove-PSSession -Session $session -ErrorAction Ignore
    }
    $exitCode
}


function Get-RunningTestVmCredential {
    <#
    .SYNOPSIS
    Returns the credential to sign in to a VM with, failing unless the VM is running.
    #>
    [CmdletBinding()]
    [OutputType([pscredential])]
    param(
        # The VM's name.
        [Parameter(Mandatory)]
        [string]$Name,

        # A credential to use instead of the one in the VM's notes.
        [pscredential]$Credential
    )

    $vm = Get-VM -Name $Name
    if ($vm.State -ne 'Running') {
        throw "VM '$Name' isn't running (state: $($vm.State)). Start it and wait for the desktop first."
    }
    if ($Credential) {
        $Credential
    } else {
        Get-TestVmCredential -VM $vm
    }
}
