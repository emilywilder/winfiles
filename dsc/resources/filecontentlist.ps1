#Requires -Version 7.4

<#
.SYNOPSIS
Implements Winfiles/FileContentList (see filecontentlist.dsc.resource.json): whole text files from inline content.

.DESCRIPTION
DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
Microsoft.WinGet/UserSettingsFile was ruled out: it only manages winget's settings.json, and DSC 3.3.0 has no
general file resource. Comparing ignores line endings and trailing whitespace, which a YAML block can't preserve.
set keeps a copy of a file it replaces, with .bak at the end of its name.

.EXAMPLE
'{"files":[{"path":"%TEMP%\\a.txt","content":"a"}]}' | ./filecontentlist.ps1 test

Reports whether %TEMP%\a.txt holds "a", from dsc/resources.
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
        $files = @($desired.files)


        function Resolve-FilePath {
            <#
            .SYNOPSIS
            Returns the full path of a file in the list, with its %VAR% placeholders expanded.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param(
                # A file from the instance's list, with path and, optionally, specialFolder.
                [Parameter(Mandatory)]
                [pscustomobject]$File
            )

            $path = [Environment]::ExpandEnvironmentVariables($File.path)
            if ($File.specialFolder) {
                Join-Path -Path ([Environment]::GetFolderPath($File.specialFolder)) -ChildPath $path
            } else {
                $path
            }
        }


        function Format-Text {
            <#
            .SYNOPSIS
            Returns text with LF line endings and no trailing whitespace, the form files are compared in.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param(
                # The text to normalize.
                [Parameter(Mandatory)]
                [AllowEmptyString()]
                [AllowNull()]
                [string]$Text
            )

            (("$Text" -split '\r?\n' | ForEach-Object -MemberName TrimEnd) -join "`n").TrimEnd()
        }


        function Get-OutOfDateFile {
            <#
            .SYNOPSIS
            Returns the path of each file in the list that's missing or holds other content.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param()

            foreach ($file in $files) {
                $path = Resolve-FilePath -File $file
                $current = if (Test-Path -LiteralPath $path -PathType Leaf) {
                    Format-Text -Text (Get-Content -LiteralPath $path -Raw)
                }
                $upToDate = $null -ne $current -and $current -eq (Format-Text -Text $file.content)
                if (-not $upToDate) {
                    $path
                }
            }
        }


        # @() at each call: PowerShell unrolls function output, so 0 or 1 results wouldn't stay arrays
        $outOfDate = @(Get-OutOfDateFile)

        if ($Operation -eq 'set' -and $outOfDate) {
            foreach ($file in $files) {
                $path = Resolve-FilePath -File $file
                if ($path -notin $outOfDate -or -not $PSCmdlet.ShouldProcess($path, 'Write the file')) {
                    continue
                }
                if (Test-Path -LiteralPath $path) {
                    Copy-Item -LiteralPath $path -Destination "$path.$(Get-Date -Format yyyyMMddHHmmss).bak"
                }
                New-Item -ItemType Directory -Force -Path (Split-Path -Path $path) | Out-Null
                Set-Content -LiteralPath $path -Value $file.content -NoNewline
            }
            $outOfDate = @(Get-OutOfDateFile)
            if ($outOfDate -and -not $WhatIfPreference) {
                throw (New-ResourceError -ExitCode 2 -Message (
                        "Still different after writing them: $($outOfDate -join ', ')"))
            }
        }

        $state = [ordered]@{
            files     = $files
            outOfDate = $outOfDate
        }
        if ($Operation -eq 'test') {
            $state['_inDesiredState'] = $outOfDate.Count -eq 0
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
