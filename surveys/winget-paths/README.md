# winget-paths

How each way winfiles can drive winget installs the same packages. It's the evidence for moving the package lists from `Winfiles/WinGetPackageList` to `Microsoft.WinGet/Package`.

## What it does

`winget-paths.Tests.ps1` is a Pester file, run through `scripts/Invoke-Tests.ps1` so Pester stays at the pinned version. It installs real packages, so it and its scripts refuse anything but a Hyper-V guest (`Win32_ComputerSystem` model `Virtual Machine`). On iris every case fails before anything changes (checked 2026-11-17).

The suite always starts unelevated. `WINFILES_WINGET_PATHS_CONTEXT` (`unelevated` or `elevated`, set by the recipe) says how the installs run. For each path in turn:
1. **Clear.** It runs `Clear-WinGetPaths.ps1` unelevated, and fails the path if anything is left.
2. **Install.** It runs `Install-WinGetPathCase.ps1` for the path: directly in the unelevated context, or through UAC in the elevated one. That process installs every package that way and writes the results to a file, so the same code measures both contexts, and the prompt that starts it isn't timed. It passes `dsc`'s folder along, since an elevated process started through UAC gets the account's `PATH`, not mise's.
3. **Check.** One `It` per package checks that package's result.

It clears once more at the end.

The clear is always unelevated, because elevated winget won't uninstall per-user packages (`0x8A15007D`, 2026-11-17). Nothing is uninstalled within a path, since its packages are all different. An earlier design uninstalled before each case. It couldn't test SumatraPDF and Element on more than one path per elevated run, and waits after failed uninstalls took about 19 of the first pair of runs' 28 minutes (2026-11-17).

The paths:

| Path | How | Used by |
|---|---|---|
| `cli` | `winget install` | `bootstrap.cmd` |
| `cli-user` | `winget install --scope user` | the install a stop-gap `_scope` would make |
| `dsc` | `Microsoft.WinGet/Package` through `dsc resource set` (`winget dscv3 package --set`) | PowerShell 7, and the lists after the move |
| `com` | `Install-WinGetPackage` from `Microsoft.WinGet.Client` | `Winfiles/WinGetPackageList` |

For `com`, it also records whether the COM API ran in-process (`WindowsPackageManager.dll` loaded) or through `WindowsPackageManagerServer`. If the system configuration hasn't run yet, it saves `Microsoft.WinGet.Client` from PSGallery into `~/.cache/winfiles/winget-paths/modules`.

The packages, picked with `winget show --scope user|machine` on iris (2026-11-17), are listed in `WinGetPaths.ps1`:
- a machine-only MSI (WinDirStat);
- one installer for both scopes (SumatraPDF);
- three home-list packages with both scopes, to see which one winget picks when given none:
  - gh: a portable zip per user, a WiX MSI per machine;
  - VS Code: separate user and system Inno installers;
  - Obsidian: one Nullsoft exe for both;
- a user-only Squirrel installer (Element);
- an MSIX with a framework dependency (ChromaControl, which declares UI.Xaml 2.6);
- an id that doesn't exist.

Each install records:
- the time, exit code and output;
- the scope the package landed in;
- whether a UAC prompt (`consent.exe`) appeared;
- for ChromaControl, whether UI.Xaml 2.6 was installed with it.

Each install times out after 15 minutes. It writes one line to `run.log` (phase `winget-paths`, read with `just test-vm-log`), and every result goes to `~/.local/state/winfiles/winget-paths/<time>-<context>.json`. Copy that folder out before restoring the VM.

Behaviour that's known and recorded below is asserted as it is, so a case starts failing when winget changes it:
- with no scope given, each package lands in the scope winget picked on 2026-11-17 (`Picks` in `WinGetPaths.ps1`), and `cli-user` lands per-user;
- unelevated, a package winget installs machine-wide (WinDirStat, gh) raises UAC on every path;
- `Install-WinGetPackage` fails to install UI.Xaml 2.6 as a dependency (`0x8A150110`), in either context.

## Running it

From an unelevated terminal in the VM's desktop, not over PowerShell Direct, which runs elevated with no UAC. Copy the repo in first with `just test-vm-copy`, which skips untracked files.

```powershell
mise exec -- just -f surveys/justfile winget-paths                         # unelevated, then elevated
mise exec -- just -f surveys/justfile winget-paths-context elevated        # one context
mise exec -- just -f surveys/justfile winget-paths-clear                   # by hand, after an interrupted run
```

On a fresh install, `just`, `pwsh` and `dsc` come from mise and aren't on `PATH`, so every command needs `mise exec --`.

It's attended, so answer the UAC prompts:
- **Each clear:** one prompt, for its elevated pass.
- **Each elevated path:** one prompt, for its install process.
- **Unelevated:** WinDirStat's and gh's own prompts on each path except `cli-user`. Approve them or dismiss them; the case records either.
- **Clears in the elevated context:** VS Code's uninstaller asks for elevation when the install was elevated. Approve it.

A context with failures stops `winget-paths` before the next context.

`Clear-WinGetPaths.ps1` (the `winget-paths-clear` recipe):
- closes the apps the installers start (VS Code, Obsidian, Element), whose uninstallers fail while they run;
- uninstalls the per-user packages unelevated;
- starts itself elevated through one UAC prompt, for the machine-wide packages and for UI.Xaml 2.6. Unelevated, winget reports UI.Xaml 2.6 uninstalled but keeps listing it (2026-11-17). That pass closes the apps too, in case one was started elevated;
- retries the per-user packages unelevated;
- exits 1 and names anything still installed.

## Results

### 2026-11-17, second run: gh, VS Code and Obsidian

Same VM, versions and checkpoint as below. The other packages behaved as in the first run. Unelevated passed. Elevated had 24 passed and 7 failed: all 7 were `cli-user`, whose clear couldn't uninstall VS Code (see below), and every other path passed. Unelevated, the UAC prompts for WinDirStat and gh were dismissed. Times are in seconds.

| Package | Context | `cli` | `cli-user` | `dsc` | `com` |
|---|---|---|---|---|---|
| gh (zip per user, WiX MSI per machine) | unelevated | **UAC**, dismissed: `0x8A15010C` | 2.9, user | **UAC**, dismissed: exit 2 (`0x8a15010c`) | **UAC**, dismissed: `InstallError 0x8A15010C` |
| | elevated | 1.3, **machine** | not run (clear failed) | 4.2, **machine** | 3.0, **machine** |
| VS Code (user and system Inno) | unelevated | 48.5, user | 45.3, user | 46.8, user | 49.3, user |
| | elevated | 42.9, user | not run | 51.1, user | 44.3, user |
| Obsidian (one Nullsoft exe) | unelevated | 31.0, user | 30.6, user | 29.8, user | 34.0, user |
| | elevated | 28.9, user | not run | 39.2, user | 29.2, user |

What it shows:
- **With no scope given, winget picked gh's machine-wide MSI on every path**, in both contexts. Unelevated, that's a UAC prompt. gh is in a home list, so an unscoped `Microsoft.WinGet/Package` would prompt in the middle of `just home`, and would install machine-wide from `just system`. That's the case for a `_scope` (plan commit 3). `--scope user` installed the portable zip in 2.9s.
- **VS Code and Obsidian picked per-user**, even elevated, like SumatraPDF.
- **Elevated installs of a per-user Inno package leave an uninstaller that asks for elevation.** After VS Code was installed from the elevated `dsc` and `com` paths, its unelevated uninstall raised UAC, and approved, it succeeded. Elevated winget still refuses the uninstall (`0x8A15007D`), so the unelevated pass is the only one that can remove it. For winfiles this means a home package installed from an elevated run takes the unelevated run and a UAC prompt to remove.
- **One clear failed:** after the elevated `cli` path, VS Code's uninstaller exited 1 (`0x8A150030`) in 5s with no prompt, and the elevated pass refused it. The next clear, 14s later, removed it. Not confirmed: the app was probably still running, perhaps started elevated by the installer after the install process stopped it. `Clear-WinGetPaths.ps1` now closes the apps in both passes and retries; that change hasn't been run yet.
- **Time:** unelevated about 13 minutes, elevated about 10, including clears and prompts.

### 2026-11-17, test VM (vm-quick from `updated`), winget 1.29.380, `Microsoft.WinGet.Client` 1.29.380, DSC 3.3.0

Both contexts passed. Unelevated, the UAC prompts for WinDirStat were dismissed. Times are each install's own, in seconds, and exclude the UAC prompt that starts the elevated install process.

| Package | Context | `cli` | `cli-user` | `dsc` | `com` |
|---|---|---|---|---|---|
| WinDirStat (machine-only MSI) | unelevated | UAC, dismissed: `0x8A15010C` (installer 1602) | not run | UAC, dismissed: exit 2 (`0x8a15010c`) | UAC, dismissed: `InstallError 0x8A15010C` |
| | elevated | 1.0, machine | not run | 3.0, machine | 2.0, machine |
| SumatraPDF (one exe, both scopes) | unelevated | 4.5, user | 3.0, user | 5.2, user | 3.9, user |
| | elevated | 3.7, **user** | 3.7, user | 4.1, user | 3.2, user |
| Element (Squirrel, user-only) | unelevated | 24.2, user | 24.1, user | 25.4, user | 25.3, user |
| | elevated | 16.2, user | 0.6\*, user | 1.5\*, user | 0.7\*, user |
| ChromaControl (MSIX, needs UI.Xaml 2.6) | unelevated | 29.0, user + UI.Xaml | 26.5, user + UI.Xaml | 27.8, user + UI.Xaml | **2.3, `DownloadError 0x8A150110`** |
| | elevated | 34.4, user + UI.Xaml | 42.1, user + UI.Xaml | 28.8, user + UI.Xaml | **2.3, `DownloadError 0x8A150110`** |
| An id that doesn't exist | both | `0x8A150014` in 0.3 | `0x8A150014` in 0.3 | exit 2 (`0x8a150014`) in 1.2–1.3 | throws "No packages matched" in 0.3–0.4 |

\* Element's elevated installs after the first returned almost at once but were listed per-user within the 30s wait. A guess, not checked: Squirrel's installer hands off to the unelevated user when run elevated. Don't read these as install times.

What it shows:
- **`Microsoft.WinGet/Package` behaves like `winget install`** on every case, in both contexts, about 1s slower (DSC's start). It installs dependencies, and it doesn't have the COM fault.
  - **On success**, DSC prints the before and after state (`_exist` false then true, with the version).
  - **On failure**, it exits 2, and winget's code is in DSC's error line.
- **The UI.Xaml 2.6 fault is the COM API's** (`Install-WinGetPackage`), in both contexts. The CLI and `dsc` installed ChromaControl and the dependency every time.
- **Without `--scope`, winget picked a per-user installer for SumatraPDF even elevated**, on every path. A machine-only package raised UAC on every path when unelevated.
- **COM ran out-of-process (`WindowsPackageManagerServer`) in both contexts.** The in-process engine shipped with the module wasn't used.
- **`Clear-WinGetPaths.ps1` left nothing behind** in any of its 10 runs. Unelevated, UI.Xaml 2.6 reported "Successfully uninstalled" every time but stayed listed, and the elevated pass removed it each time.
- **Time:** the elevated context took about 6.5 minutes, including the clears and prompts.

An earlier design of this survey, run twice the same day, agreed on every point it reached: COM `0x8A150110` elevated, UAC for WinDirStat unelevated, SumatraPDF per-user unelevated. It also found that elevated winget refuses to uninstall per-user packages (`0x8A15007D`), which is why the clear always runs unelevated.
