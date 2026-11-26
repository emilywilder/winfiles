# The bootstrap

`bootstrap.cmd` gets a fresh machine to where `winfiles.ps1 switch <host>` can run, and reads nothing from `dsc/`. Where it fits in an install is in [install.md](../install.md); what it leaves behind, and how to remove it, is [below](#what-it-leaves-behind).

## What the install can assume

The install assumes only what the bootstrap guarantees:
- winget's `jdx.mise` on the user `PATH`;
- the repo trusted by mise;
- `mise.toml`'s tools installed;
- a recent App Installer.

The install doesn't check for the bootstrap or name it. The home configuration also lists `jdx.mise`, and manages the bootstrap's copy from then on, as nix-darwin manages the Nix its installer put there.

## The `.cmd` files

`bootstrap.cmd`, `install.cmd` and `winfiles.cmd` are called the same way: unelevated, from cmd or PowerShell, with arguments passed on and the exit code passed back. A `.cmd` runs whatever the execution policy is, so each starts Windows PowerShell 5.1 with `-ExecutionPolicy Bypass` for that one process; the policy itself is never changed. `.gitattributes` keeps them CRLF ([reference](../reference/windows.md#cmdexe-and-lf-line-endings)).

None changes the persistent `PATH`. So `pwsh` only reaches a plain terminal once the configuration has installed its own copy (the PowerShell MSIX), and `winfiles.ps1` can't run there until then. `winfiles.cmd` runs any of its commands meanwhile.

- `bootstrap.cmd` runs `scripts\Initialize-Winfiles.ps1 <args>`.
- `winfiles.cmd` changes to the repo's folder and runs `scripts\Start-Winfiles.ps1 <args>` under 5.1, which finds mise from the registry's `PATH` and runs `winfiles.ps1 <args>` in a clean environment ([clean-environment.md](clean-environment.md)). For example `.\winfiles.cmd switch vm-quick`.
- `install.cmd` runs `winfiles.cmd switch --restart <args>`. A run that stops for a restart restarts Windows and arms the resume itself ([resume.md](resume.md)).

Trade-off: `winfiles.cmd` runs every command clean, even the ones `winfiles.ps1` runs in the caller's environment (`dsc`, the test VM commands), and adds about 0.7s in front of each ([benchmarks](../benchmarks.md#a-clean-run)). It's for a machine without pwsh on `PATH`; from a pwsh, `winfiles.ps1` is the same commands. Revisit when a native `winfiles.exe` replaces `Start-Winfiles.ps1` behind it ([dev/tooling.md](../dev/tooling.md#not-done-yet)).

## What it runs

`scripts/Initialize-Winfiles.ps1` runs under 5.1, since nothing else is installed yet. Before changing anything, it checks for:
- an unelevated shell;
- x64 (`mise.lock` only covers windows-x64);
- Windows 11;
- `winget`;
- `mise.toml` and `mise.lock`.

It lists every problem it finds and stops. Otherwise it says what it will do, then runs these, skipping what's already done:

```powershell
winget install --id Microsoft.AppInstaller --exact --source winget --accept-package-agreements   # 0x8A15002B (already current) counts as success
Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ForceApplicationShutdown   # only if the update was left staged
powershell -File Initialize-Winfiles.ps1 -MiseOnly           # the rest, in a new process
winget install --id jdx.mise --exact --source winget --accept-package-agreements   # unless mise is installed
$env:Path = <machine Path>;<user Path>                       # this process only, so mise is found without a new terminal
mise trust; mise install                                     # pwsh, gsudo, yq and DSC
mise exec -- pwsh -File winfiles.ps1 hosts                   # proves a command runs; lists the configurations
```

It ends by printing `.\install.cmd <host>`, and `.\winfiles.cmd switch <host>` for later runs. It takes no host: running the install is a separate step.

## Why each step is there

- **App Installer first.** A new image can ship an App Installer too old for the install: 1.26 fails elevated and breaks `msstore` ([reference](../reference/winget.md#app-installer-126-elevated)). Only the bootstrap updates it, so on an old image, run the bootstrap before the install.
- **The rest in a new process,** because `winget install` fails in the same process right after App Installer has updated itself ([reference](../reference/winget.md#winget-right-after-its-own-update)).
- **Registering a staged update.** winget can report success while the new App Installer is only staged. Windows then swaps it in at the next sign-in, which can break a resumed install halfway through ([reference](../reference/winget.md#app-installer-update-left-staged)). So when the registered version hasn't changed, the bootstrap registers the update itself, and stops if that doesn't take. Trade-off: this only covers the update the bootstrap starts; the Store can swap App Installer under any run. Revisit if a run fails like this without a bootstrap just before it.
- **One retry on `0x8A15000F`** (source data missing), after `winget source update` ([reference](../reference/winget.md#0x8a15000f-on-the-first-call)). A second failure points at `winget source reset`. Only the failing path is tested (below).
- **`--source winget`** keeps winget away from `msstore`, whose terms prompt would stop a fresh install ([reference](../reference/winget.md#the-msstore-source-on-a-fresh-install)). `--accept-package-agreements` accepts mise's licence. winget still asks for UAC for the Visual C++ runtime that `jdx.mise` depends on, and the script says so first.
- **The `PATH` reload** changes only the script's own process, which the `PATH` constraint allows. winget puts mise's folder on the user `PATH` rather than in `WinGet\Links` ([reference](../reference/winget.md#where-winget-puts-jdxmise)).
- **`winfiles.ps1 hosts` is the check that it worked.** It runs the command runner in mise's `pwsh`, which reads `commands.jsonc`, so a broken pwsh or table stops the bootstrap instead of the install.
- **`mise.toml`'s `min_version`** is the mise winfiles was last checked with. Neither the bootstrap nor the home configuration upgrades mise, so an older one stops with `mise version ... is required` and the `winget upgrade jdx.mise` hint.

## What it leaves behind

Nothing removes these. To undo a bootstrap on a machine that `winfiles.ps1 switch` hasn't touched:

- The App Installer update. Leave it: it's Windows' own package, and Windows Update or the Store would update it anyway.
- `winget uninstall --id jdx.mise --exact`, which also takes mise's folder off the user `PATH`. Once `winfiles.ps1 home` has run, the home configuration installs it again; take it out of `hosts/iris/home/packages-base.dsc.yaml` first to keep it gone.
- The Visual C++ runtime, `Microsoft.VCRedist.2015+.x64`. Usually leave it: it's shared, and other programs may need it.
- `%LOCALAPPDATA%\mise`, the tools `mise install` downloaded, and `~\.local\state\mise`, which holds the repo's trust.

The bootstrap changes no `PATH` itself; winget's change for mise is the only one. Like Nix's installer, which prints `uninstall_directions`, this is a list, not a script.

## Not done yet

- **The retry's success path.** After `0x8A15000F` the bootstrap runs `winget source update` and retries once; Pester covers only the second failure, because the success path goes on to change the machine. Check it the next time a clean VM bootstrap hits the error, or force it in a VM. The cause of the error is unknown (first winget call after a checkpoint restore, 2026-11-19, gone on the next try).
