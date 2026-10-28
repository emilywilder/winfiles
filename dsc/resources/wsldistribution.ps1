# Implements Winfiles/WslDistribution (see wsldistribution.dsc.resource.json).
# DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
# State is read from WSL's per-user registration under HKCU, which avoids parsing `wsl --list`.
# It only installs: it never unregisters, moves or renames a distribution.
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
    $name = $desired.name
    $wantDefault = [bool]$desired.default

    # wsl.exe writes UTF-16 unless told otherwise
    $env:WSL_UTF8 = '1'
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'

    function Get-Registration {
        if (-not (Test-Path $lxss)) { return $null }
        $default = (Get-ItemProperty $lxss).DefaultDistribution
        Get-ChildItem $lxss | ForEach-Object { Get-ItemProperty $_.PSPath } |
            Where-Object DistributionName -eq $name |
            Select-Object -First 1 |
            ForEach-Object {
                [pscustomobject]@{ BasePath = $_.BasePath; IsDefault = $_.PSChildName -eq $default }
            }
    }

    # Sends wsl.exe output to stderr so stdout stays JSON; returns whether it succeeded
    function Invoke-Wsl {
        & wsl.exe @args 2>&1 | ForEach-Object { [Console]::Error.WriteLine($_) }
        $LASTEXITCODE -eq 0
    }

    $registration = Get-Registration

    if ($Operation -eq 'set') {
        if (-not $registration) {
            $source = [Environment]::ExpandEnvironmentVariables([string]$desired.source)
            if (-not $source) { throw "No source to install $name from" }

            $tempDir = $null
            try {
                $file = $null
                if ($source -match '^https?://') {
                    $tempDir = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) "wsl-$([guid]::NewGuid())")
                    $file = Join-Path $tempDir ([IO.Path]::GetFileName(([uri]$source).AbsolutePath))
                    Invoke-WebRequest -Uri $source -OutFile $file
                } elseif (Test-Path -LiteralPath $source -PathType Leaf) {
                    $file = (Resolve-Path -LiteralPath $source).Path
                }

                if ($file -and $desired.sha256) {
                    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
                    if ($hash -ne $desired.sha256) { throw "SHA256 of $source is $hash, expected $($desired.sha256)" }
                }

                $wslArgs = if ($file) { @('--install', '--from-file', $file) } else { @('--install', $source) }
                $wslArgs += @('--name', $name, '--no-launch')
                if ($desired.location) {
                    $wslArgs += @('--location', [Environment]::ExpandEnvironmentVariables($desired.location))
                }
                if (-not (Invoke-Wsl @wslArgs)) {
                    [Console]::Error.WriteLine("Failed to install ${name} from ${source}")
                    $failed = $true
                }
            } finally {
                if ($tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
            }
            $registration = Get-Registration
        }

        if ($registration -and $wantDefault -and -not $registration.IsDefault) {
            if (-not (Invoke-Wsl --set-default $name)) {
                [Console]::Error.WriteLine("Failed to make $name the default distribution")
                $failed = $true
            }
            $registration = Get-Registration
        }
    }

    $installed = [bool]$registration
    $isDefault = $installed -and $registration.IsDefault
    $state = [ordered]@{ name = $name }
    # Echo optional inputs only when given: the schema doesn't allow null for them
    foreach ($property in 'source', 'sha256', 'location') {
        if ($desired.$property) { $state[$property] = $desired.$property }
    }
    $state['default'] = $wantDefault
    $state['installed'] = $installed
    $state['isDefault'] = $isDefault
    $state['basePath'] = $registration.BasePath
    if ($Operation -eq 'test') { $state['_inDesiredState'] = $installed -and ($isDefault -or -not $wantDefault) }
    $state | ConvertTo-Json -Compress

    if ($failed) { exit 2 }
}
