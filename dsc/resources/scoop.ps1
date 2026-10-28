# Implements Winfiles/Scoop (see scoop.dsc.resource.json).
# DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
# Installs Scoop itself with Scoop's own installer. Buckets and apps are Winfiles/ScoopPackageList's job.
# The installer refuses an elevated shell, so set exits with 3 there instead of trying. It adds Scoop's
# shims folder to the user PATH, which is allowed for Scoop; this script doesn't touch PATH itself.
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('get', 'test', 'set')]
    [string]$Operation,

    [Parameter(ValueFromPipeline)]
    [string]$InputJson
)

begin {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    $lines = [System.Collections.Generic.List[string]]::new()
}

process {
    if ($InputJson) { $lines.Add($InputJson) }
}

end {
    $desired = $lines -join "`n" | ConvertFrom-Json
    $installerUrl = if ($desired.installerUrl) { $desired.installerUrl } else { 'https://get.scoop.sh' }

    . (Join-Path $PSScriptRoot 'scooproot.ps1')
    $root = Get-ScoopRoot

    function Test-Scoop {
        Test-Path (Join-Path $root 'apps\scoop\current\bin\scoop.ps1')
    }

    $installed = Test-Scoop

    if ($Operation -eq 'set' -and -not $installed) {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) {
            [Console]::Error.WriteLine("Scoop's installer refuses an elevated shell. Apply dsc/winfiles.user.dsc.yaml from a normal shell")
            $blocked = $true
        } else {
            # Download to a file instead of piping into Invoke-Expression, so the installer runs as a script
            $tempDir = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) "scoop-$([guid]::NewGuid())")
            try {
                $installer = Join-Path $tempDir 'install.ps1'
                Invoke-WebRequest -Uri $installerUrl -OutFile $installer
                # The installer reports through Write-Host and Write-Error. Send all of it to stderr, and keep its
                # errors non-terminating, like Invoke-Scoop in scooppackagelist.ps1
                & {
                    $ErrorActionPreference = 'Continue'
                    & $installer *>&1 | ForEach-Object { [Console]::Error.WriteLine("$_") }
                }
            } finally {
                Remove-Item -LiteralPath $tempDir -Recurse -Force
            }
            $root = Get-ScoopRoot
            $installed = Test-Scoop
            if (-not $installed) {
                [Console]::Error.WriteLine("Scoop's installer finished but Scoop isn't at $root")
                $failed = $true
            }
        }
    }

    $state = [ordered]@{
        installerUrl = $installerUrl
        root         = $root
        installed    = $installed
    }
    if ($Operation -eq 'test') { $state['_inDesiredState'] = $installed }
    $state | ConvertTo-Json -Compress

    # The manifest ends its command with `exit $LASTEXITCODE`, so always exit explicitly
    if ($failed) { exit 2 }
    if ($blocked) { exit 3 }
    exit 0
}
