# Apps

How individual apps and their installers behaved when checked, where that decides how winfiles installs them.

## Installers that need a run in the test VM

A winget manifest doesn't prove an installer runs unelevated. Only a run in the test VM shows it.

- **KDE Connect.** Its `Scope: user` installer, run with `/S /CurrentUser`, still raises a UAC prompt and waits for it. So it's in `hosts/iris/system`.
- **Discord.** winget's installer starts Discord, which asks for UAC mid-run. So Discord comes from Scoop, in `hosts/iris/home/packages-internet.dsc.yaml`.
- **gh.** Without a scope, winget picks gh's machine-wide MSI, which raises a UAC prompt in an unelevated run (`surveys/winget-paths`, 2026-11-17).

## LyX and Tectonic

LyX's installer looks for `latex.exe`, which Tectonic doesn't have, but LyX can be made to work with Tectonic. Tested on iris with TeX Live moved out of the way, 2026-11-03.
