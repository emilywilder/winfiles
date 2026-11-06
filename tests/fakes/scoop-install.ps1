# A stand-in for Scoop's installer (get.scoop.sh), which Winfiles/Scoop downloads and runs. Tests serve it with
# Start-FakeWebServer (tests/resources/Resource.ps1). Like the real one, it installs to $env:SCOOP and reports
# through Write-Host and Write-Error. $env:WINFILES_FAKE_SCOOP_INSTALL picks how it goes:
#   (unset)  installs Scoop
#   warn     installs Scoop, and writes an error on the way, which mustn't stop the resource
#   nothing  finishes without installing anything
Write-Host 'Initializing...'
if ($env:WINFILES_FAKE_SCOOP_INSTALL -eq 'warn') { Write-Error 'A fake problem that the installer carries on past' }
if ($env:WINFILES_FAKE_SCOOP_INSTALL -ne 'nothing') {
    $bin = New-Item -ItemType Directory -Force (Join-Path $env:SCOOP 'apps\scoop\current\bin')
    Set-Content (Join-Path $bin 'scoop.ps1') '# fake Scoop'
}
Write-Host 'Scoop was installed successfully!'
