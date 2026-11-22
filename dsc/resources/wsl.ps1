#Requires -Version 7.4

<#
.SYNOPSIS
Implements Winfiles.Wsl/Wsl (see wsl.dsc.resource.json): the WSL package and Virtual Machine Platform.

.DESCRIPTION
DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
`wsl --install --no-distribution` installs the WSL package and enables Virtual Machine Platform in one step (the
winget package doesn't enable the feature). Enabling the feature needs a restart, which only the install can do, so
the resource never restarts Windows: it reports `_restartRequired` to DSC (DSC 3.3.0 collects it into the result's
executionInformation.restartRequired) and exits 0, since DSC stops the whole configuration on a non-zero exit.
get says so while a restart is pending. test also says so while Virtual Machine Platform is off, since enabling it
leaves one pending, so a run can know ahead of time that set will need a restart. A WSL that only needs installing
or updating, with the feature already on, isn't predicted to: the machine shows it afterwards (restart.ps1).
The checks are in wslstate.ps1, shared with Winfiles.Wsl/Distribution, which makes them before installing a
distribution.
A restart pending for another reason, Windows Update's say, counts too: installers refuse to run then, so the
machine isn't in the desired state until it's restarted.

.EXAMPLE
'{}' | ./wsl.ps1 test

Reports whether WSL is installed and ready, from dsc/resources.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    # The DSC operation.
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('get', 'test', 'set')]
    [string]$Operation,

    # A line of the instance's JSON, from DSC on stdin.
    [Parameter(ValueFromPipeline)]
    [AllowEmptyString()]
    [string]$InputObject
)

begin {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'common.ps1')
    . (Join-Path -Path $PSScriptRoot -ChildPath 'wslstate.ps1')
    # For the run log (`just test-vm-log`), where wsl.exe's output goes: DSC shows none of it unless wsl.exe fails
    . (Join-Path -Path $PSScriptRoot -ChildPath '..\..\scripts\winlog.ps1')
    $lines = [Collections.Generic.List[string]]::new()
}

process {
    $lines.Add($InputObject)
}

end {
    # A trap only covers the scope that declares it, so common.ps1 can't hold this one
    trap { Exit-ResourceError -ErrorRecord $_ }

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    try {
        $desired = Read-ResourceInput -Line $lines
        # The first WSL with --from-file and --name, which Winfiles.Wsl/Distribution uses
        $minimum = [version]($desired.minimumVersion ?? '2.4.4')

        # wsl.exe writes UTF-16 unless told otherwise
        $env:WSL_UTF8 = '1'


        function Test-Elevated {
            <#
            .SYNOPSIS
            Tests whether this process is elevated: its token has the High mandatory level, S-1-16-12288.

            .DESCRIPTION
            Asks whoami.exe rather than the .NET principal, so a test can mock it.
            #>
            [CmdletBinding()]
            [OutputType([bool])]
            param()

            [bool](& whoami.exe /groups | Select-String -SimpleMatch -Pattern 'S-1-16-12288')
        }


        function Get-State {
            <#
            .SYNOPSIS
            Returns the resource's state: WSL's version, the feature, the hypervisor and a pending restart.
            #>
            [CmdletBinding()]
            [OutputType([Collections.Specialized.OrderedDictionary])]
            param()

            $version = Get-WslVersion
            [ordered]@{
                minimumVersion         = "$minimum"
                version                = if ($version) { "$version" }
                virtualMachinePlatform = [bool](Test-VirtualMachinePlatform)
                hypervisor             = Test-Hypervisor
                restartPending         = [bool](Test-RestartPending)
            }
        }


        function Test-Ready {
            <#
            .SYNOPSIS
            Tests whether a state has WSL installed, new enough, and the feature enabled, restarted for or not.
            #>
            [CmdletBinding()]
            [OutputType([bool])]
            param(
                # A state from Get-State.
                [Parameter(Mandatory)]
                [Collections.IDictionary]$State
            )

            $State.virtualMachinePlatform -and $State.version -and [version]$State.version -ge $minimum
        }


        function Start-WslConsole {
            <#
            .SYNOPSIS
            Runs wsl.exe with its output in a file, and returns its exit code.

            .DESCRIPTION
            The inbox wsl.exe (System32, on a machine without the WSL package) fails with exit code 1 and only "For
            more information please visit https://aka.ms/wslinstall" when its stdin isn't a console, and under DSC
            it is DSC's pipe. cmd's `<con` reads the console the process is attached to, whatever its stdin is.
            Checked 2026-11-18 in the test VM, elevated, with stdin piped: `wsl --install --no-distribution <con
            >file 2>&1` worked, and cmd returned wsl.exe's exit code. Without `<con`, or with `<NUL`, it failed.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'The script asks ShouldProcess before installing or updating WSL')]
            [CmdletBinding()]
            [OutputType([int])]
            param(
                # wsl.exe's arguments.
                [Parameter(Mandatory)]
                [string[]]$WslArgument,

                # The file for wsl.exe's stdout and stderr.
                [Parameter(Mandatory)]
                [string]$OutFile
            )

            & cmd.exe /c "wsl.exe $($WslArgument -join ' ') <con > `"$OutFile`" 2>&1" | Out-Null
            $LASTEXITCODE
        }


        function Invoke-Wsl {
            <#
            .SYNOPSIS
            Runs wsl.exe, and returns its exit code and output.

            .DESCRIPTION
            Its output also goes to stderr, so stdout stays JSON, and to the run log. It's returned too, because
            DSC logs stderr at trace only and a failure has to carry wsl.exe's own explanation.
            #>
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param(
                # wsl.exe's arguments.
                [Parameter(Mandatory)]
                [string[]]$WslArgument
            )

            $said = [Collections.Generic.List[string]]::new()
            $outFile = [IO.Path]::GetTempFileName()
            Write-WinfilesLog -Phase wsl -Message "running wsl.exe $WslArgument"
            try {
                $exitCode = Start-WslConsole -WslArgument $WslArgument -OutFile $outFile
                # The inbox wsl.exe ignores WSL_UTF8 and writes UTF-16, which arrives as text with a NUL between
                # the characters
                if ([IO.File]::Exists($outFile)) {
                    foreach ($line in Get-Content -LiteralPath $outFile) {
                        $text = "$line" -replace "`0", ''
                        $said.Add($text)
                        [Console]::Error.WriteLine($text)
                        if ($text.Trim()) {
                            Write-WinfilesLog -Phase wsl -Message "wsl.exe: $($text.Trim())"
                        }
                    }
                }
            } finally {
                Remove-Item -LiteralPath $outFile -ErrorAction SilentlyContinue
            }
            Write-WinfilesLog -Phase wsl -Message "wsl.exe $WslArgument exited with code $exitCode"
            [pscustomobject]@{ ExitCode = $exitCode; Output = $said.ToArray() }
        }


        function Invoke-WslChecked {
            <#
            .SYNOPSIS
            Runs wsl.exe, and throws, with its last lines, when it fails, so the rest of the set isn't tried.

            .DESCRIPTION
            Windows Installer's codes for success are 3010, with a restart required, and 1641, with the restart
            already started.
            #>
            [CmdletBinding()]
            param(
                # wsl.exe's arguments.
                [Parameter(Mandatory)]
                [string[]]$WslArgument
            )

            $run = Invoke-Wsl -WslArgument $WslArgument
            if ($run.ExitCode -eq 1641) {
                Write-ResourceMessage -Level warn -Text "wsl.exe $WslArgument has started a restart"
            } elseif ($run.ExitCode -notin 0, 3010) {
                $last = $run.Output | Where-Object -FilterScript { $_.Trim() } | Select-Object -Last 10
                $said = $last -join ' | '
                $reason = if ($said) { ": $said" } else { '' }
                throw (New-ResourceError -ExitCode 2 -Message (
                        "wsl.exe $WslArgument exited with code $($run.ExitCode)$reason"))
            }
        }


        $state = Get-State
        $settingUp = $Operation -eq 'set' -and -not (Test-Ready -State $state)
        # `wsl --install` isn't known to update an older WSL package, so update it explicitly. The inbox wsl.exe
        # has no version. Both are asked about before either runs, so -WhatIf needs no elevation
        $updating = $settingUp -and $state.version -and [version]$state.version -lt $minimum -and
        $PSCmdlet.ShouldProcess('WSL', "Update to $minimum or later (wsl --update)")
        $installing = $settingUp -and (-not $state.version -or -not $state.virtualMachinePlatform) -and
        $PSCmdlet.ShouldProcess('WSL', 'Install WSL and Virtual Machine Platform (wsl --install)')
        if ($updating -or $installing) {
            if (-not (Test-Elevated)) {
                throw (New-ResourceError -ExitCode 2 -Message 'Installing WSL needs elevation')
            }
            if ($updating) {
                Invoke-WslChecked -WslArgument '--update'
            }
            if ($installing) {
                Invoke-WslChecked -WslArgument '--install', '--no-distribution'
            }
            $state = Get-State
            if (-not $state.restartPending -and -not (Test-Ready -State $state)) {
                $found = if ($state.version) { "WSL $($state.version)" } else { 'only the inbox WSL' }
                $feature = if ($state.virtualMachinePlatform) { 'enabled' } else { 'not enabled' }
                throw (New-ResourceError -ExitCode 2 -Message (
                        ("wsl.exe finished, but WSL still isn't ready, and no restart is pending: " +
                        "this machine has $found ($minimum or later is needed), " +
                        "and Virtual Machine Platform is $feature")))
            }
        }
        # Only after the restart can the hypervisor be judged: until then it isn't running, and restarting is the
        # fix
        $noHypervisor = (Test-Ready -State $state) -and -not $state.restartPending -and -not $state.hypervisor
        if ($Operation -eq 'set' -and $noHypervisor) {
            throw (New-ResourceError -ExitCode 2 -Message (
                    ('Virtual Machine Platform is enabled, but no hypervisor is running, ' +
                    'so WSL 2 can''t start, and restarting again won''t help. ' +
                    'Turn on virtualization (Intel VT-x or AMD-V) in the BIOS/UEFI settings; in a Hyper-V VM, ' +
                    'turn on nested virtualization (Set-VMProcessor -ExposeVirtualizationExtensions $true) ' +
                    'while the VM is off')))
        }

        $restart = $state.restartPending -or ($Operation -eq 'test' -and -not $state.virtualMachinePlatform)
        if ($restart) {
            $state['_restartRequired'] = @(@{ system = $env:COMPUTERNAME })
        }
        if ($Operation -eq 'test') {
            $state['_inDesiredState'] = ([bool](Test-Ready -State $state) -and -not $state.restartPending -and
                -not $noHypervisor)
        }
        if ($Operation -eq 'set' -and $state.restartPending) {
            $message = 'Windows has a restart pending. Restart before anything else is installed'
            Write-ResourceMessage -Level warn -Text $message
        }
        ConvertTo-Json -InputObject $state -Compress -Depth 3
    } catch {
        # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
        $failure = $_
        throw $failure
    } finally {
        $ErrorActionPreference = 'Continue'
    }

    # The manifest ends its command with `exit $LASTEXITCODE`, so always exit explicitly
    exit 0
}
