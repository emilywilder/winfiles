#Requires -Version 7.4

<#
.SYNOPSIS
Implements Winfiles/CodePage (see codepage.dsc.resource.json): UTF-8 as the system code page, or not.

.DESCRIPTION
DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
"Beta: Use Unicode UTF-8 for worldwide language support" in Settings writes 65001 to the ACP, MACCP and OEMCP
values of HKLM\SYSTEM\CurrentControlSet\Control\Nls\CodePage, and Windows reads them at boot.
Microsoft.Windows/Registry could write them, but it can't tell DSC that a restart is needed, which this resource
does (docs/config/code-page.md). Switching it off writes the code pages the system locale defaults to, which
GetLocaleInfoEx gives, since they differ by locale (1252, 437 and 10000 for en-US).
Windows keeps the code pages it's using (GetACP, GetOEMCP) apart from the registry values it will use at the next
restart. There is no API for the active Mac code page, so it's left out of the active pair. test is in the desired
state only once the registry values and the active pair match. set writes only the values that differ.
Every operation tells DSC about the restart through _restartRequired, a top-level property DSC 3.3.0 collects into
the result's executionInformation.restartRequired (docs/reference/dsc.md#where-restartrequired-lands). get says so
while the active pair isn't the registry's. test and set say so while the active pair isn't the wanted one, which
includes before anything is written, so a test run shows ahead of time that set will need a restart. DSC only
reports it: it doesn't restart, so the install does (docs/run/restarts.md).

.EXAMPLE
'{"utf8":true}' | ./codepage.ps1 test

Reports whether UTF-8 is the system code page, from dsc/resources.
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
        if ($desired.utf8 -isnot [bool]) {
            throw (New-ResourceError -ExitCode 2 -Message "'utf8' must be true or false")
        }

        $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage'
        # The registry values, in the order they're reported
        $valueNames = 'ACP', 'OEMCP', 'MACCP'


        # What these read is the registry and Windows itself, which the tests can't replace with files, so they're
        # functions to mock
        function Get-ActiveCodePage {
            <#
            .SYNOPSIS
            Returns the ANSI and OEM code pages the running system uses, which only a restart changes.
            #>
            [CmdletBinding()]
            [OutputType([hashtable])]
            param()

            if (-not ('Winfiles.CodePageNative' -as [type])) {
                Add-Type -Namespace Winfiles -Name CodePageNative -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint GetACP();
[DllImport("kernel32.dll")] public static extern uint GetOEMCP();
'@
            }
            @{ ACP = [int][Winfiles.CodePageNative]::GetACP(); OEMCP = [int][Winfiles.CodePageNative]::GetOEMCP() }
        }


        function Get-PendingCodePage {
            <#
            .SYNOPSIS
            Returns the three code pages the registry holds, which Windows uses from the next restart, with $null
            for one that isn't a number.
            #>
            [CmdletBinding()]
            [OutputType([hashtable])]
            param()

            $properties = Get-ItemProperty -Path $key
            $pending = @{}
            foreach ($name in $valueNames) {
                $number = 0
                $pending[$name] = if ([int]::TryParse([string]$properties.$name, [ref]$number)) { $number }
            }
            $pending
        }


        function Get-LocaleCodePage {
            <#
            .SYNOPSIS
            Returns the three code pages the system locale defaults to, which are the ones without UTF-8.
            #>
            [CmdletBinding()]
            [OutputType([hashtable])]
            param()

            if (-not ('Winfiles.CodePageLocale' -as [type])) {
                Add-Type -Namespace Winfiles -Name CodePageLocale -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
public static extern int GetLocaleInfoEx(string name, uint type, System.Text.StringBuilder data, int size);
'@
            }
            # LOCALE_NAME_SYSTEM_DEFAULT, and the LOCALE_IDEFAULT*CODEPAGE types
            $systemDefault = '!x-sys-default-locale'
            $types = @{ ACP = 0x1004; OEMCP = 0x000B; MACCP = 0x1011 }
            $locale = @{}
            foreach ($name in $valueNames) {
                $text = [Text.StringBuilder]::new(16)
                if ([Winfiles.CodePageLocale]::GetLocaleInfoEx($systemDefault, $types[$name], $text, 16) -le 0) {
                    throw (New-ResourceError -ExitCode 3 -Message "Windows gave no default code page for $name")
                }
                $locale[$name] = [int]$text.ToString()
            }
            $locale
        }


        function Set-PendingCodePage {
            <#
            .SYNOPSIS
            Writes one of the registry's code pages, as the text Windows keeps it in.
            #>
            [CmdletBinding(SupportsShouldProcess)]
            param(
                # ACP, OEMCP or MACCP.
                [Parameter(Mandatory)]
                [ValidateSet('ACP', 'OEMCP', 'MACCP')]
                [string]$Name,

                # The code page.
                [Parameter(Mandatory)]
                [int]$CodePage
            )

            if ($PSCmdlet.ShouldProcess("$Name in $key", "Set the code page to $CodePage")) {
                Set-ItemProperty -Path $key -Name $Name -Value ([string]$CodePage) -Type String
            }
        }


        $wanted = if ($desired.utf8) { @{ ACP = 65001; OEMCP = 65001; MACCP = 65001 } } else { Get-LocaleCodePage }

        if ($Operation -eq 'set') {
            $pending = Get-PendingCodePage
            foreach ($name in $valueNames) {
                if ($pending[$name] -ne $wanted[$name]) {
                    try {
                        Set-PendingCodePage -Name $name -CodePage $wanted[$name]
                    } catch {
                        $failure = $_
                        throw (New-ResourceError -ExitCode 2 -Message (
                                "Setting $name to $($wanted[$name]) failed: $($failure.Exception.Message)"))
                    }
                }
            }
        }

        $pending = Get-PendingCodePage
        $active = Get-ActiveCodePage
        $pendingIsWanted = -not ($valueNames | Where-Object { $pending[$_] -ne $wanted[$_] })
        $activeIsWanted = $active.ACP -eq $wanted.ACP -and $active.OEMCP -eq $wanted.OEMCP

        # get says what the registry holds; the others say what was asked for, as ComputerName does with its name
        $utf8 = if ($Operation -eq 'get') {
            -not ($valueNames | Where-Object { $pending[$_] -ne 65001 })
        } else {
            $desired.utf8
        }
        $state = [ordered]@{
            utf8                = $utf8
            pendingAnsiCodePage = $pending.ACP
            pendingOemCodePage  = $pending.OEMCP
            pendingMacCodePage  = $pending.MACCP
            activeAnsiCodePage  = $active.ACP
            activeOemCodePage   = $active.OEMCP
        }
        $restart = if ($Operation -eq 'get') {
            $active.ACP -ne $pending.ACP -or $active.OEMCP -ne $pending.OEMCP
        } else {
            -not $activeIsWanted
        }
        if ($restart) {
            $state['_restartRequired'] = @(@{ system = [Environment]::MachineName })
        }
        if ($Operation -eq 'test') {
            $state['_inDesiredState'] = $pendingIsWanted -and $activeIsWanted
        }
        if ($Operation -eq 'set' -and $restart) {
            Write-ResourceMessage -Level warn -Text (
                "The code pages are set, but the system keeps using $($active.ACP) and $($active.OEMCP) " +
                'until the next restart')
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
