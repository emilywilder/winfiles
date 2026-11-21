# The bootstrap

`bootstrap.cmd` gets a fresh machine to where `just install <host>` can run, and reads nothing from `dsc/`. Where it fits in an install is in [install.md](../install.md); what it leaves behind, and how to remove it, is in [dev/dependencies.md](../dev/dependencies.md#what-the-bootstrap-leaves-behind).

## What the install can assume

The install assumes only what the bootstrap guarantees:
- winget's `jdx.mise` on the user `PATH`;
- the repo trusted by mise;
- `mise.toml`'s tools installed;
- a recent App Installer.

The install doesn't check for the bootstrap or name it. The home configuration also lists `jdx.mise`, and manages the bootstrap's copy from then on, as nix-darwin manages the Nix its installer put there.

## The two `.cmd` files

`bootstrap.cmd` and `install.cmd` are called the same way: unelevated, from cmd or PowerShell, with arguments passed on and the exit code passed back. A `.cmd` runs whatever the execution policy is, so each starts Windows PowerShell 5.1 with `-ExecutionPolicy Bypass` for that one process; the policy itself is never changed. `.gitattributes` keeps them CRLF ([reference](../reference/windows.md#cmdexe-and-lf-line-endings)).

Neither changes the persistent `PATH`. So `just` and `pwsh` only reach a plain terminal once the configuration has installed its own copies (Scoop's `just`, the PowerShell MSIX). Until then, use `install.cmd`, or `mise exec -- just install <host>`.

- `bootstrap.cmd` runs `scripts\Initialize-Winfiles.ps1 <args>`.
- `install.cmd` changes to the repo's folder and runs `scripts\Invoke-Install.ps1 <args>` under 5.1. That writes the resume entry ([resume.md](resume.md)) and runs `scripts\Start-Clean.ps1 just install <args>` ([clean-environment.md](clean-environment.md)).

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
mise trust; mise install                                     # just, pwsh, gsudo, yq and DSC
mise exec -- just hosts                                      # proves a recipe runs; lists the configurations
```

It ends by printing `.\install.cmd <host>`. It takes no host: running the install is a separate step.

## Why each step is there

- **App Installer first.** A new image can ship an App Installer too old for the install: 1.26 fails elevated and breaks `msstore` ([reference](../reference/winget.md#app-installer-126-elevated)). Only the bootstrap updates it, so on an old image, run the bootstrap before `just install`.
- **The rest in a new process,** because `winget install` fails in the same process right after App Installer has updated itself ([reference](../reference/winget.md#winget-right-after-its-own-update)).
- **Registering a staged update.** winget can report success while the new App Installer is only staged. Windows then swaps it in at the next sign-in, which can break a resumed install halfway through ([reference](../reference/winget.md#app-installer-update-left-staged)). So when the registered version hasn't changed, the bootstrap registers the update itself, and stops if that doesn't take. Trade-off: this only covers the update the bootstrap starts; the Store can swap App Installer under any run. Revisit if a run fails like this without a bootstrap just before it.
- **One retry on `0x8A15000F`** (source data missing), after `winget source update` ([reference](../reference/winget.md#0x8a15000f-on-the-first-call)). A second failure points at `winget source reset`. Only the failing path is tested (below).
- **`--source winget`** keeps winget away from `msstore`, whose terms prompt would stop a fresh install ([reference](../reference/winget.md#the-msstore-source-on-a-fresh-install)). `--accept-package-agreements` accepts mise's licence. winget still asks for UAC for the Visual C++ runtime that `jdx.mise` depends on, and the script says so first.
- **The `PATH` reload** changes only the script's own process, which the `PATH` constraint allows. winget puts mise's folder on the user `PATH` rather than in `WinGet\Links` ([reference](../reference/winget.md#where-winget-puts-jdxmise)).
- **`just hosts` is the check that it worked.** It runs mise's `just`, which runs a recipe line in mise's `pwsh`, so a broken tool stops the bootstrap instead of the install.
- **`mise.toml`'s `min_version`** is the mise winfiles was last checked with. Neither the bootstrap nor the home configuration upgrades mise, so an older one stops with `mise version ... is required` and the `winget upgrade jdx.mise` hint.

## Not done yet

- **The retry's success path.** After `0x8A15000F` the bootstrap runs `winget source update` and retries once; Pester covers only the second failure, because the success path goes on to change the machine. Check it the next time a clean VM bootstrap hits the error, or force it in a VM. The cause of the error is unknown (first winget call after a checkpoint restore, 2026-11-19, gone on the next try).
