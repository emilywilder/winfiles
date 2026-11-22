#Requires -Version 7.4

<#
.SYNOPSIS
Implements Winfiles/WslDistribution (see wsldistribution.dsc.resource.json): a WSL distribution for this user.

.DESCRIPTION
DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
State is read from WSL's per-user registration under HKCU, which avoids parsing `wsl --list`.
It only installs: it never unregisters, moves or renames a distribution.

.EXAMPLE
'{"name":"NixOS"}' | ./wsldistribution.ps1 test

Reports whether this user has a distribution named NixOS, from dsc/resources.
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
        $name = $desired.name
        $wantDefault = [bool]$desired.default

        # wsl.exe writes UTF-16 unless told otherwise
        $env:WSL_UTF8 = '1'
        $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'


        function Get-Registration {
            <#
            .SYNOPSIS
            Returns the distribution's registration (its BasePath, and whether it's the default), or nothing.
            #>
            [CmdletBinding()]
            [OutputType([pscustomobject])]
            param()

            if (Test-Path -Path $lxss) {
                $default = (Get-ItemProperty -Path $lxss).DefaultDistribution
                Get-ChildItem -Path $lxss |
                    ForEach-Object -Process { Get-ItemProperty -Path $_.PSPath } |
                    Where-Object -Property DistributionName -EQ -Value $name |
                    Select-Object -First 1 |
                    ForEach-Object -Process {
                        [pscustomobject]@{ BasePath = $_.BasePath; IsDefault = $_.PSChildName -eq $default }
                    }
            }
        }


        function Invoke-Wsl {
            <#
            .SYNOPSIS
            Runs wsl.exe with its output on stderr, so stdout stays JSON, and returns whether it succeeded.
            #>
            [CmdletBinding()]
            [OutputType([bool])]
            param(
                # wsl.exe's arguments.
                [Parameter(Mandatory)]
                [string[]]$WslArgument
            )

            & wsl.exe @WslArgument 2>&1 | ForEach-Object -Process { [Console]::Error.WriteLine($_) }
            $LASTEXITCODE -eq 0
        }


        function Assert-Prerequisite {
            <#
            .SYNOPSIS
            Throws, with exit code 3, unless the machine can install a distribution.

            .DESCRIPTION
            Prerequisites from https://learn.microsoft.com/windows/wsl/install: WSL 2 needs Virtual Machine
            Platform (enabling it needs elevation and a restart) and a running hypervisor, and --from-file/--name
            need WSL 2.4.4 or later. Checked before installing, so an unattended set fails clearly instead of
            prompting or half-installing. CIM reads the feature without elevation, unlike
            Microsoft.Windows/OptionalFeatureList. Keep in step with dsc/resources/wsl.ps1 (Winfiles/Wsl), which
            sets both up.
            #>
            [CmdletBinding()]
            param()

            $feature = Get-CimInstance -ClassName Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'"
            if ($feature.InstallState -ne 1) {
                throw (New-ResourceError -ExitCode 3 -Message (
                        'Virtual Machine Platform is not enabled. Run `just system`, then restart'))
            }
            # Right after enabling, the feature already reads as enabled; only this key shows the restart is still
            # to come
            $servicing = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
            if (Test-Path -Path $servicing) {
                throw (New-ResourceError -ExitCode 3 -Message (
                        'Windows has a restart pending. Restart, then run `just install` again'))
            }
            # WSL 2 runs in the hypervisor that Virtual Machine Platform starts at boot. With virtualization off in
            # the firmware, or not passed through to a VM, the feature still reads as enabled, and only the install
            # would fail
            if (-not (Get-CimInstance -ClassName Win32_ComputerSystem).HypervisorPresent) {
                $message = ('No hypervisor is running, so WSL 2 can''t start. ' +
                    'Turn on virtualization in the BIOS/UEFI settings, or nested virtualization for a VM')
                throw (New-ResourceError -ExitCode 3 -Message $message)
            }
            # The version is the file version of the package's wsl.exe; nothing is run. The inbox wsl.exe in
            # System32, with no WSL package, waits 60s for a key press that would install WSL (see Get-WslVersion
            # in dsc/resources/wsl.ps1). A WSL installed elsewhere, such as a Store package, is found by its
            # registration instead
            $wsl = Join-Path -Path $env:ProgramFiles -ChildPath 'WSL\wsl.exe'
            $version = if (Test-Path -Path $wsl) {
                if ("$((Get-Item -LiteralPath $wsl).VersionInfo.ProductVersion)" -match '^(\d+\.\d+\.\d+)') {
                    [version]$Matches[1]
                }
            } else {
                $store = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications'
                $package = Get-ChildItem -Path $store -Name -ErrorAction SilentlyContinue |
                    Where-Object -FilterScript { $_ -like 'MicrosoftCorporationII.WindowsSubsystemForLinux_*' } |
                    Select-Object -First 1
                if ($package -and $package -match '_(\d+\.\d+\.\d+)(\.\d+)?_') {
                    [version]$Matches[1]
                }
            }
            if (-not $version -or $version -lt [version]'2.4.4') {
                $found = if ($version) { "WSL $version" } else { 'The inbox WSL' }
                throw (New-ResourceError -ExitCode 3 -Message ("$found is too old: 2.4.4 or later is needed. " +
                        'Run `just system` or `wsl --update`'))
            }
        }


        $registration = Get-Registration

        if ($Operation -eq 'set' -and -not $registration -and $PSCmdlet.ShouldProcess($name, 'Install')) {
            Assert-Prerequisite
            # Without a source, the name is looked up in wsl.exe's online list (`wsl --list --online`), as
            # `wsl --install <name>` does
            $source = [Environment]::ExpandEnvironmentVariables([string]$desired.source)
            if (-not $source) {
                $source = $name
            }

            $tempDir = $null
            try {
                $file = $null
                if ($source -match '^https?://') {
                    $tempPath = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "wsl-$([guid]::NewGuid())"
                    $tempDir = New-Item -ItemType Directory -Path $tempPath
                    $fileName = [IO.Path]::GetFileName(([uri]$source).AbsolutePath)
                    $file = Join-Path -Path $tempDir -ChildPath $fileName
                    Invoke-WebRequest -Uri $source -OutFile $file
                } elseif (Test-Path -LiteralPath $source -PathType Leaf) {
                    $file = (Resolve-Path -LiteralPath $source).Path
                }

                if ($file -and $desired.sha256) {
                    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
                    if ($hash -ne $desired.sha256) {
                        throw "SHA256 of $source is $hash, expected $($desired.sha256)"
                    }
                }

                $wslArgs = if ($file) { @('--install', '--from-file', $file) } else { @('--install', $source) }
                # Installing by its listed name needs no --name, which older Store (appx) entries in the list
                # refuse
                if ($source -ne $name) {
                    $wslArgs += @('--name', $name)
                }
                $wslArgs += '--no-launch'
                if ($desired.location) {
                    $wslArgs += @('--location', [Environment]::ExpandEnvironmentVariables($desired.location))
                }
                if (-not (Invoke-Wsl -WslArgument $wslArgs)) {
                    throw (New-ResourceError -ExitCode 2 -Message "Failed to install ${name} from ${source}")
                }
            } finally {
                if ($tempDir) {
                    Remove-Item -LiteralPath $tempDir -Recurse -Force
                }
            }
            $registration = Get-Registration
        }

        $makeDefault = $Operation -eq 'set' -and $registration -and $wantDefault -and -not $registration.IsDefault
        if ($makeDefault -and $PSCmdlet.ShouldProcess($name, 'Make the default distribution')) {
            if (-not (Invoke-Wsl -WslArgument '--set-default', $name)) {
                throw (New-ResourceError -ExitCode 2 -Message "Failed to make $name the default distribution")
            }
            $registration = Get-Registration
        }

        $installed = [bool]$registration
        $isDefault = $installed -and $registration.IsDefault
        $state = [ordered]@{ name = $name }
        # Echo optional inputs only when given: the schema doesn't allow null for them
        foreach ($property in 'source', 'sha256', 'location') {
            if ($desired.$property) {
                $state[$property] = $desired.$property
            }
        }
        $state['default'] = $wantDefault
        $state['installed'] = $installed
        $state['isDefault'] = $isDefault
        $state['basePath'] = $registration.BasePath
        if ($Operation -eq 'test') {
            $state['_inDesiredState'] = $installed -and ($isDefault -or -not $wantDefault)
        }
        ConvertTo-Json -InputObject $state -Compress
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
