# A stand-in for Scoop's bin\scoop.ps1, covering the two commands Winfiles/ScoopPackageList runs: `install` and
# `bucket add`. New-FakeScoop (tests/resources/Resource.ps1) copies it to <root>\apps\scoop\current\bin, where the
# resource looks for Scoop. Like the real one, it leaves the files the resource reads state from:
# apps\<name>\current\scoop-install.json and buckets\<name>.
# <root>\fake-scoop.json lists what fails: { failing: [<app>], failingBuckets: [<bucket>] }. Every call is appended
# to <root>\fake-scoop-calls.txt, one line of arguments each.
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$config = Get-Content -Raw (Join-Path $root 'fake-scoop.json') | ConvertFrom-Json
Add-Content (Join-Path $root 'fake-scoop-calls.txt') ($args -join ' ')

switch ($args[0]) {
    'bucket' {
        $name = $args[2]
        if ($name -in @($config.failingBuckets)) {
            Write-Error "Failed to add the $name bucket"
        } else {
            New-Item -ItemType Directory -Force (Join-Path $root "buckets\$name") | Out-Null
            Write-Host "The $name bucket was added successfully."
        }
    }
    'install' {
        # Scoop moves on past an app that fails, so this does too
        foreach ($app in $args[1..($args.Count - 1)]) {
            $bucket, $name = if ($app -match '/') { $app -split '/', 2 } else { 'main', $app }
            Write-Host "Installing '$name' (1.0.0) [64bit] from '$bucket' bucket"
            if ($name -in @($config.failing)) {
                Write-Error "Couldn't install $name"
            } else {
                $current = New-Item -ItemType Directory -Force (Join-Path $root "apps\$name\current")
                @{ bucket = $bucket; architecture = '64bit' } | ConvertTo-Json |
                    Set-Content (Join-Path $current 'scoop-install.json')
            }
        }
    }
    default { throw "The fake Scoop doesn't know '$($args -join ' ')'" }
}
