# winget and App Installer

How winget and App Installer behaved when checked, and what in winfiles relies on it. Each entry is a fact about winget, not winfiles' design, which is in the area docs that link here.

## App Installer 1.26 elevated

With App Installer 1.26.509 (winget 1.11), on an image that hadn't been through Windows Update, the WinGet module fails when elevated (`Failed to create instance: 0x800706BA`) but not unelevated, and `Microsoft.WinGet/Source` removes `msstore` and then fails to add it back. Upgrading unelevated gives no prompt, and winget 1.29 fixes both.

- Checked: 2026-11-02, test VM.
- Used by: the bootstrap updates App Installer first (`docs/install.md`).

## winget right after its own update

A `winget install` in the same process, right after App Installer updated itself, failed with `Unrecognized command: '...\WindowsApps\winget.exe'` both times it was tried. In a new process it worked.

- Checked: 2026-11-15, test VM, 1.29.379 to 1.29.380.
- Used by: the bootstrap runs the rest of its steps in a new process (`-MiseOnly`).

## App Installer update left staged

winget can report that the App Installer update succeeded while it is only staged. winget's log had `0x80073D02: Unable to install because the following apps need to be closed Microsoft.DesktopAppInstaller_1.29.379.0` (the app being winget itself). 1.29.379 stayed registered, and Windows registered 1.29.380 at the next sign-in, after the WSL restart. That swap moved the old package folder while the resumed install's system step was starting, and DSC failed with exit code 2 before running winget.

The registered version is `(Get-AppxPackage Microsoft.DesktopAppInstaller).Version`, the check that Microsoft's App Installer page gives. `Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ForceApplicationShutdown` registers the staged version.

- Checked: 2026-11-17, test VM, from the `updated` checkpoint.
- Used by: the bootstrap registers the staged update itself when the version hasn't changed.

## 0x8A15000F on the first call

`0x8A15000F` ("Failed when opening source(s)") came from the first winget call on a test VM just restored from `updated`. The cause wasn't established; it was gone on the next try. winget's own advice for it is `winget source reset`.

- Seen: 2026-11-19, test VM, once.
- Used by: the bootstrap's single retry after `winget source update`.

## 0x8A15002B

`winget install` of a package that is already current exits `0x8A15002B`. The bootstrap treats it as success.

## The msstore source on a fresh install

On a fresh install, the `msstore` source stops to ask you to accept its terms, and it sends your region. `--source winget` avoids it.

## Where winget puts jdx.mise

winget adds mise's folder (`...\WinGet\Packages\jdx.mise_...\mise\bin`) to the user `PATH` and makes no link in `WinGet\Links`. Its `Command line alias added: "mise"` line names the package's commands; it isn't a link.

- Checked: 2026-11-16, test VM, winget 1.29.380 (no `Links` folder at all).
- Used by: the bootstrap reloads `PATH` from the registry for its own process.

## winget dscv3 prints nothing while installing

`Microsoft.WinGet/Package` (`winget dscv3`) writes no progress while a package installs. In a clean `vm` install (45 `Microsoft.WinGet/Package` and 37 `Winfiles.WinGet/Package` resources), the console showed no line for the 13m27s of `system`.

- Seen: 2026-11-17, test VM.

## 0x80071130 after a portable install

`winget dscv3 package --get` failed with `0x80071130 Fast Cache data not found` right after a portable install of `Kubernetes.kubectl`, 7m07s into a `vm` user batch. A rerun passed. winget's reason is on its stderr and in its log (`just test-vm-log -All`).

- Seen: 2026-11-19, test VM, once.
- Used by: `Winfiles.WinGet/Package` writes a failed call's id, operation and HRESULT to `run.log` under `[winget]`. A retry is in `docs/optional-goals.md`.
