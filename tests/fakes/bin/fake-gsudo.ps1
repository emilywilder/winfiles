# A stand-in for gsudo.exe: writes its arguments, one per line, to the file named by $env:WINFILES_FAKE_GSUDO, and
# exits with $env:FAKE_EXIT. It runs nothing, so a test can see what a script would have run elevated or unelevated.
Set-Content $env:WINFILES_FAKE_GSUDO $args
exit [int]$env:FAKE_EXIT
