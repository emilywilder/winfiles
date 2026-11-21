# Bootstrap and install

How a machine goes from a fresh Windows 11 install to its configuration, and why each step works the way it does. Dated evidence about the tools is in [reference/](reference/), and timings are in [benchmarks.md](benchmarks.md).

```powershell
.\bootstrap.cmd        # unelevated: winget, mise and mise.toml's tools; lists the hosts; applies nothing
.\install.cmd <host>   # then, from any terminal: just install; resumes at the sign-in after its restart, once Enter is pressed
```

## Two stages

The bootstrap gets the machine to where `just install <host>` can run, and reads nothing from `dsc/`. The install assumes only what the bootstrap guarantees:
- winget's `jdx.mise` on the user `PATH`;
- the repo trusted by mise;
- `mise.toml`'s tools installed;
- a recent App Installer.

The install doesn't check for the bootstrap or name it. The home configuration also lists `jdx.mise`, and manages the bootstrap's copy from then on, as nix-darwin manages the Nix its installer put there. What the bootstrap leaves behind, and how to remove it, is in [dependencies.md](dependencies.md).

The two `.cmd` files are called the same way: unelevated, from cmd or PowerShell, with arguments passed on and the exit code passed back. A `.cmd` runs whatever the execution policy is, so each starts Windows PowerShell 5.1 with `-ExecutionPolicy Bypass` for that one process; the policy itself is never changed. `.gitattributes` keeps them CRLF ([reference](reference/windows.md#cmdexe-and-lf-line-endings)).

Neither changes the persistent `PATH`. So `just` and `pwsh` only reach a plain terminal once the configuration has installed its own copies (Scoop's `just`, the PowerShell MSIX). Until then, use `install.cmd`, or `mise exec -- just install <host>`.

- `bootstrap.cmd` runs `scripts\Initialize-Winfiles.ps1 <args>`.
- `install.cmd` changes to the repo's folder and runs `scripts\Invoke-Install.ps1 <args>` under 5.1. That writes the resume entry ([Continuing after a restart](#continuing-after-a-restart)) and runs `scripts\Start-Clean.ps1 just install <args>` ([A run inherits nothing](#a-run-inherits-nothing)).

## The bootstrap

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

- **App Installer first.** A new image can ship an App Installer too old for the install: 1.26 fails elevated and breaks `msstore` ([reference](reference/winget.md#app-installer-126-elevated)). Only the bootstrap updates it, so on an old image, run the bootstrap before `just install`.
- **The rest in a new process,** because `winget install` fails in the same process right after App Installer has updated itself ([reference](reference/winget.md#winget-right-after-its-own-update)).
- **Registering a staged update.** winget can report success while the new App Installer is only staged. Windows then swaps it in at the next sign-in, which can break a resumed install halfway through ([reference](reference/winget.md#app-installer-update-left-staged)). So when the registered version hasn't changed, the bootstrap registers the update itself, and stops if that doesn't take. Trade-off: this only covers the update the bootstrap starts; the Store can swap App Installer under any run. Revisit if a run fails like this without a bootstrap just before it.
- **One retry on `0x8A15000F`** (source data missing), after `winget source update` ([reference](reference/winget.md#0x8a15000f-on-the-first-call)). A second failure points at `winget source reset`. Only the failing path is tested; checking the success path is in [optional-goals.md](optional-goals.md).
- **`--source winget`** keeps winget away from `msstore`, whose terms prompt would stop a fresh install ([reference](reference/winget.md#the-msstore-source-on-a-fresh-install)). `--accept-package-agreements` accepts mise's licence. winget still asks for UAC for the Visual C++ runtime that `jdx.mise` depends on, and the script says so first.
- **The `PATH` reload** changes only the script's own process, which the `PATH` constraint allows. winget puts mise's folder on the user `PATH` rather than in `WinGet\Links` ([reference](reference/winget.md#where-winget-puts-jdxmise)).
- **`just hosts` is the check that it worked.** It runs mise's `just`, which runs a recipe line in mise's `pwsh`, so a broken tool stops the bootstrap instead of the install.
- **`mise.toml`'s `min_version`** is the mise winfiles was last checked with. Neither the bootstrap nor the home configuration upgrades mise, so an older one stops with `mise version ... is required` and the `winget upgrade jdx.mise` hint.

## What `just install` runs

`just install [host] [user]` defaults to the computer name and the username. It fails before any change when there's no configuration for them. Then it runs these steps, each of which skips what's already done:

```powershell
gsudo --direct just install-steps <host> <user>   # install-elevated: the one UAC prompt (none from an elevated shell)
pwsh -File ./scripts/Invoke-Configuration.ps1 set  dsc/<host>.system.dsc.yaml dsc/<user>@<host>.home.dsc.yaml   # configure
pwsh -File ./scripts/Invoke-Configuration.ps1 test dsc/<host>.system.dsc.yaml dsc/<user>@<host>.home.dsc.yaml   # check: one total; exits 1 if anything is missing
pwsh -File ./scripts/Show-PostInstall.ps1 dsc/hosts/<host> dsc/users/<user>@<host>                             # post-install: what's left to do by hand
```

`Invoke-Configuration.ps1 set` works in four steps:
1. It flattens the two entries into one aggregate and splits it into batches by privilege ([The flat copy](#the-flat-copy)).
2. It finds what will need a restart, and applies that first ([What needs a restart](#what-needs-a-restart)).
3. It applies the other batches in order: elevated ones as they are, and unelevated ones through `Invoke-AsUser.ps1` (`gsudo -i Medium`). Scoop is installed by the first user batch.
4. If only the new computer name is still pending at the end, it restarts and exits 3010.

### Privilege

The whole run is elevated once, at its start. `install-elevated` runs the private recipe `install-steps` through `Invoke-AsAdmin.ps1`, in a second `just`. It does this after `require` has checked that the configurations exist, so a wrong host name never reaches the prompt. The restart then comes while someone is watching, and nothing after the prompt needs attention.

Plain `just system` and `just check` elevate the same way, around their whole run; `just home` never asks. `check` is elevated because the optional features need elevation even for `get`.

`Invoke-AsUser.ps1` drops to unelevated with `gsudo -i Medium --direct`. That gives the same token as a normal unelevated shell, and keeps the caller's console, so DSC's progress bar still draws ([reference](reference/windows.md#dropping-privilege-from-an-elevated-shell)).

Trade-off: the elevated run is one more `just` and pwsh process deep, and mise, DSC's downloads and git clones run elevated for the whole install. Some files it creates, such as the flat copies, are owned by Administrators ([reference](reference/windows.md#files-an-elevated-run-creates)). Revisit if either matters.

gsudo's credential cache (`gsudo cache on`) isn't used: just runs each recipe line in its own process, and the cache's per-process scope hasn't been checked against that.

### Failures

- **A Scoop app that fails doesn't stop the run.** The list logs an `ERROR`, keeps the app in `missing` and exits 0, so later resources still apply. `check` then fails `just install`.
- **A winget package that fails stops its batch.** Each winget package is a resource of its own, so a failure exits non-zero, DSC stops the batch with winget's code, and `Set-Winfiles.ps1` names the batch. That was accepted: a list carries on so that one bad id doesn't hide the ids after it in the same resource, which can't happen with one resource per package.
- **Any other failure stops the run** where it happens, before `check`.

`system`, `home` and `check` are `[no-exit-message]`. A stop for a restart shows only the script's warning, and `Set-Winfiles.ps1` prints a failure itself, so just's red lines would only repeat it.

Each `set` and `check` writes DSC's JSON results, with each resource's duration, to `~/.local/state/winfiles/dsc/<time>-<set|test>-<document>.json`. They're outside the repo because `just test-vm-copy` replaces the repo. Nothing removes them, and `just dsc` doesn't write them.

Trade-off: `check` adds about 80s to a run on iris ([benchmarks](benchmarks.md#check)), for one list of what's missing. And `just home` on its own exits 0 after a failed Scoop app, so a script has to run `just check` to notice. Revisit if `check` becomes slow enough to skip, or if a failed package gets missed.

### Post-install notes

A step winfiles can't do goes in a YAML comment in `dsc/hosts/<host>/` or `dsc/users/<user>@<host>/`. The comment starts with `# post-install: ` and runs to the end of that block of comment lines, beside the setting it's about. `just post-install` prints the host's notes, then the user's.

`just install` runs it last, so a stop for a restart or a failed `check` hides the notes until a run gets through. Trade-off: nothing can tell whether a note has been done, so they print on every `just install`. Revisit if they start being ignored.

## The flat copy

DSC never gets the entry documents. `Invoke-Configuration.ps1` flattens them into one copy, with each Include replaced by its document's resources, under `~/.local/state/winfiles/flat/`. Every run, `check` included, applies or tests that copy, so `check` tests what `set` applied, and the progress bar names each resource. How the copy is made, what it refuses, and why, is in [flat-configuration.md](flat-configuration.md).

### Batches by privilege

The copy is split into batches, each of one privilege level, by `metadata.winget.securityContext: elevated` (the system entry has it; the home entry doesn't). `Invoke-Configuration.ps1 set|test <entry>...` runs each batch as its own dsc process, through `Invoke-AsAdmin.ps1` or `Invoke-AsUser.ps1`:
- A `set` stops at the first batch that fails, with its exit code.
- A `test` runs every batch, lists what differs under each batch's "N of M in desired state", and ends with one total.

## What needs a restart

No document lists restarts, because a restart is something the run does. Resources report that they will need one with `_restartRequired`, which DSC 3.3.0 takes from `test` and `set` results. `Winfiles/Wsl` and `Winfiles/ComputerName` report it.

1. Before applying anything, `Find-RestartResources.ps1` tests each elevated batch. It prints a `winfiles-restart: <type>|<name>` line for each resource that reported a restart.
2. If any did, the batches are made again with `ConvertTo-FlatConfiguration.ps1 -First`. That puts those resources, and everything they depend on, in a first elevated batch (stage `restart`). The optional features come along through WSL's `dependsOn`.
3. `Set-RestartStage.ps1` tests that batch and applies what differs. If Windows then has a restart pending, the run restarts and exits 3010.
4. After each of the other elevated batches, the machine is asked again, which catches a restart nothing reported. That check hasn't fired in a real run yet ([optional-goals.md](optional-goals.md)).

After the restart, `install` runs again. The test now finds those resources done, so nothing has to be remembered across the restart. A clean install restarts once, for the features, WSL and the rename together.

The built-in `Microsoft.Windows/OptionalFeatureList` can't report a restart from `test`, and its per-feature `restartRequired` says `Possible` for every feature, so winfiles doesn't use it. A restart the features need is read from the machine after they're applied ([reference](reference/dsc.md#optionalfeaturelist-and-restarts)). DSC puts `restartRequired` on each resource's own entry in a result, so `Get-RestartReport` in `scripts/dsclog.ps1` reads the flattened entries ([reference](reference/dsc.md#where-restartrequired-lands)).

`scripts/restart.ps1`, which the resume shares, reads what counts as pending from the machine:
- **Component servicing (`RebootPending`)** blocks the run, because installers refuse to run while it's set.
- **A pending rename** can wait for a restart that's happening anyway.

The run restarts Windows by itself only when nothing was pending before this run applied anything. It counts down 10 seconds in a `Write-Progress` bar, for Ctrl+C, and doesn't use `-Force`. Otherwise it only asks, since the restart may be Windows Update's.

`Winfiles/ComputerName` is in its desired state only once the active name matches, so `check` fails while a rename waits.

Trade-offs:
- Every elevated batch is tested once more before the first `set` (11–24s, [benchmarks](benchmarks.md#finding-what-needs-a-restart)). In return, nobody has to write down the restart set, and there's no restart when nothing needs one. Revisit if that test gets slow enough to notice, or if a resource can't report its restart from `test`.
- The reasons for a restart are read from the machine rather than counted. A count would be lost across the restart, and it can't see a restart that Windows Update or an installer asked for. Revisit if a reason is missed.
- Whether a restart blocks installers is the machine's answer (`RebootPending`), not a table of resource types. Revisit if a resource needs to say it itself.
- `PendingFileRenameOperations` isn't read, since nearly every installer sets it. Revisit if an install step fails because of it.
- The rename is applied with the features and WSL, before the installers, so one restart serves all three. Revisit if renaming ahead of the installers causes trouble.

## Continuing after a restart

`install.cmd` picks the run up again at the next sign-in, through a per-user `RunOnce` entry, so a clean install doesn't wait for someone to notice the restart. A plain `just install` has to be rerun by hand.

`Invoke-Install.ps1` writes `HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce\winfiles` before it runs the install, because writing it afterwards would race the shutdown. When the run ends, it removes the entry, unless the exit code is 3010 or 194 (3010 cut to its low byte by `mise exec`, [reference](reference/windows.md#mise-exec-and-exit-codes)). The value is:

```
cmd.exe /c start "winfiles" powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File scripts\Resume-Winfiles.ps1 <args>
```

- It opens whichever terminal Windows defaults to, so nothing depends on `wt.exe`, which the home configuration only installs later. `start` returns at once.
- `Resume-Winfiles.ps1` does these, in order:
  1. Moves to the repo (RunOnce starts it in System32).
  2. Stops before UAC if `RebootPending` is still set.
  3. Waits for Enter.
  4. Waits up to 60s for `cdn.winget.microsoft.com:443`, since Wi-Fi can still be connecting at sign-in.
  5. Runs `install.cmd <args>` as a child, so the window stays open on the result. That run registers the entry again if it stops for another restart.
- Windows deletes a RunOnce value before running it, and the name has no `!`, so only a run that stops for a restart writes it back. Declining UAC, or any failure, ends the chain ([reference](reference/windows.md#runonce)).
- A command over RunOnce's 260 characters only gets a warning, and the install goes ahead without the resume.

The resume waits for Enter because a sign-in doesn't mean someone is at the machine. The test VM signs in by itself, and Windows cancels a UAC prompt that nobody answers, which ends the chain ([reference](reference/windows.md#an-unanswered-uac-prompt)).

Trade-off: the resume needs a key press after every restart, even when the person has just signed in themselves, and a restart put off with Ctrl+C can bring the window back days later. Revisit if the resume has to run unattended. Skipping its UAC prompt with a scheduled task was considered and not done ([ruled-out.md](reference/ruled-out.md#a-scheduled-task-for-the-resumes-uac-prompt)).

## A run inherits nothing

A run is the same from any terminal. These go through `scripts/Invoke-Clean.ps1`:
- `install.cmd`;
- `just system`, `home`, `check`, `manual` and `post-install`;
- `just test`.

`Invoke-Clean.ps1` starts the command under `mise exec`, with `Start-Process -UseNewEnvironment`. Windows builds that environment for the user from the registry and the logon session (`CreateEnvironmentBlock`). So even a caller's changed `USERNAME` or `USERPROFILE` doesn't reach a run, and no list of variables has to be kept.

So `just`, `pwsh`, `gsudo` and DSC are always `mise.toml`'s. Only the outer `just`, and the shell of that one recipe line, come from the caller; from `install.cmd`, those are mise's too. `just dsc` doesn't go through this, since it's for working on the configuration by hand.

- **Start-Clean.ps1.** `install.cmd` can't start `Invoke-Clean.ps1` directly. Right after the bootstrap, the only pwsh is mise's, and the bootstrap's terminal has a `PATH` from before mise was installed. So `Start-Clean.ps1`, under 5.1, reads the machine and user `PATH` from the registry, finds mise, and runs `mise exec -- pwsh Invoke-Clean.ps1 just install ...`. It keeps to 5.1 syntax, and passes no arguments with quotes inside, since 5.1 mangles them ([reference](reference/windows.md#windows-powershell-51-passing-arguments)). Without a `mise` on `PATH`, it says so and exits 1. Other ways of finding mise are in [ruled-out.md](reference/ruled-out.md#finding-mise-from-installcmd).
- **Other mise configuration.** Both `mise` calls list the configuration in effect (`mise config ls --json`). Every file but the repo's `mise.toml` is added to `MISE_IGNORED_CONFIG_PATHS`, with a warning naming it (`scripts/miseignore.ps1`). Otherwise a global config, or a `mise.toml` in a parent folder, would add its tools and env to every run ([reference](reference/windows.md#mise-configuration-files)).
- **pwsh 7.3 or later.** `CreateEnvironmentBlock` arrived in 7.1, and quotes inside arguments pass correctly from 7.3 ([reference](reference/windows.md#start-process--usenewenvironment)). An older pwsh gets an error and exit 1 from an explicit check, not from `#Requires`: a recipe line carries on past a failed `#Requires`, and `exit $LASTEXITCODE` then reports 0.
- **A second pwsh.** The command runs as `pwsh -ExecutionPolicy Bypass -EncodedCommand`. That's because `-UseNewEnvironment` ignores `-Environment`, which would otherwise restore `PSExecutionPolicyPreference`, and `Start-Process` joins arguments without quoting them. Bypass matters because mise's pwsh defaults to RemoteSigned, which refuses a script with a mark of the web, as a repo from a downloaded ZIP has ([reference](reference/windows.md#remotesigned-and-the-mark-of-the-web)).

Trade-offs ([benchmarks](benchmarks.md#a-clean-run)):
- A variable set only in the calling shell, such as a proxy, doesn't reach a run; set it persistently if a run needs it. Revisit if mise or just gains a way to clear an environment.
- `Start-Clean.ps1` adds about 0.7s in front of `install.cmd`. Revisit if the bootstrap can leave mise's pwsh where a `.cmd` can find it.
- The second pwsh adds about 0.55s per recipe line. Its output also skips PowerShell's pipeline, so `$x = & ./scripts/Invoke-Clean.ps1 ...` captures nothing, though no recipe does this. Revisit if `-Environment` starts working alongside `-UseNewEnvironment`, or if a recipe needs to capture the output.
- Checking the mise configuration costs one more `mise` call, about 50ms per recipe.

## What a run says

The console gets only what the person needs: failures, warnings, what a `set` left missing, and `check`'s results. Progress goes only to `~/.local/state/winfiles/run.log`, through `Write-WinfilesLog` (`scripts/winlog.ps1`, 5.1-compatible), as timed `[phase] message` lines. `just test-vm-log` follows it. It's the one record of a whole install across its restarts, and nothing removes it.

| Phase | Written by | What |
|---|---|---|
| `bootstrap` | `Initialize-Winfiles.ps1` | its steps, then "done" |
| `install` | the justfile | `started`; `finished` only when `system`, `home` and `check` all passed |
| `apply`, `system`, `home`, `restart` | `Invoke-Configuration.ps1`, `Find-RestartResources.ps1`, `Set-RestartStage.ps1`, `Set-Winfiles.ps1`, `restart.ps1` | what will need a restart, "applying <document>", "done in 3m12s, 41 resources", what a list left missing, "dsc failed with exit code N", the restart |
| `check` | `Test-Winfiles.ps1` | the totals |
| `privilege` | `Invoke-AsAdmin.ps1`, `Invoke-AsUser.ps1` | "asking for UAC" before a prompt; gsudo's exit code and time after it |
| `resume` | `Invoke-Install.ps1`, `Resume-Winfiles.ps1` | the RunOnce entry registered, kept or removed; resumed after sign-in, Enter pressed, winget's source not reached, the exit code |
| `wsl`, `winget` | `Winfiles/Wsl`, `Winfiles.WinGet/Package` | `wsl.exe`'s arguments, output and exit code; a failed winget call's package id, operation and HRESULT |

Reading the log:
- **Only the log says an install finished;** the console doesn't. Revisit if someone running `install.cmd` by hand wants that line.
- **No "kept" line after a restart.** When the run restarts Windows itself, the shutdown ends `Invoke-Install.ps1` before the run returns. So a restart line is followed straight by "resumed after sign-in", and the last "asking for UAC" before it has no line for gsudo's exit code.
- **Counts come from DSC's JSON.** An Include's `set` result nests its resources under `afterState`, unlike `test`, so `dsclog.ps1` reads both shapes ([reference](reference/dsc.md#include-result-shapes)).

What dsc prints on stderr, including its `ERROR` line for a failed resource, goes to the console only, since capturing stderr would lose the progress bar ([reference](reference/dsc.md#the-progress-bar)). So a resource that can fail has to write its own failure to the log. `Winfiles/Wsl` and `Winfiles.WinGet/Package` do; the Scoop, file and registry resources don't yet.

Trade-off: the events come from the scripts around DSC, not from inside it, so the log shows nothing between "applying" and "done" for a long `home`. Revisit with the resource-level events in [optional-goals.md](optional-goals.md).
