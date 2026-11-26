# Installing and using winfiles

This guide is for my own machines: the user `emily` on the hosts below. For what winfiles is, start with [README.md](README.md).

| Host | What it's for |
|---|---|
| `iris` | My real machine. Needs Windows 11 Pro, because it enables Hyper-V |
| `vm` | A full test install in a virtual machine. It uses iris's packages, without its hardware software or Remote Desktop |
| `vm-quick` | A faster test install with only a few packages |

The commands below use `iris`. Pick the section that matches the machine:

1. [A fresh Windows 11 install](#1-a-fresh-windows-11-install)
2. [An already configured Windows 11 machine](#2-an-already-configured-windows-11-machine)
3. [A machine winfiles already manages](#3-a-machine-winfiles-already-manages)

## Before you start

For a first install (sections 1 and 2), you need:

- **Windows 11 on an x64 processor.** `iris` needs the Pro edition. Use a current release, since the WSL setup relies on recent networking and firewall features.
- **Virtualization turned on** in the BIOS/UEFI settings. In a test VM, this means nested virtualization.
- **An administrator account.** Check your username with `$env:USERNAME` in PowerShell, or `echo %USERNAME%` in Command Prompt. It should be `emily`. If it isn't, add `emily` after the host in the commands below that take a user (`.\install.cmd iris emily`). This applies emily's configuration to the account you're signed in to.
- **A network connection** that can reach GitHub, winget's servers, the PowerShell Gallery and `get.scoop.sh`.
- **A copy of this repo.** A fresh Windows install has no git, so bring the repo over some other way, such as a ZIP file or a USB drive.

Put the repo in `%USERPROFILE%\src\winfiles`. Keep the path short, and don't move the folder during an install: continuing after a restart depends on it, and a very long path turns that off.

Unless a step says otherwise, use a **normal (not "Run as administrator") terminal**, in the repo folder:

```powershell
cd $HOME\src\winfiles
```

That line is for PowerShell. In Command Prompt, use `cd %USERPROFILE%\src\winfiles`.

## 1. A fresh Windows 11 install

### Step 1: bootstrap

```powershell
.\bootstrap.cmd
```

This updates App Installer (which provides winget), installs mise, and has mise install PowerShell 7, DSC, gsudo and yq. It might ask for UAC to install a Visual C++ runtime. It doesn't apply any configuration.

If it finds a problem in its first checks, it lists what's wrong and changes nothing. It's safe to run again. When it finishes, it lists the available configurations.

### Step 2: install

```powershell
.\install.cmd iris
```

> [!important]
> Always name the host on a new machine. Windows gives it a generated name such as `DESKTOP-AB12CD3`, which matches no configuration.

What to expect:

1. **Approve the UAC prompt.**
2. winfiles applies what needs a restart first: Windows features, WSL, the computer's name and the UTF-8 code page.
3. **Windows restarts** after a 10-second countdown. Save any open work before you start. Pressing Ctrl+C during the countdown cancels the restart, and the install then won't continue by itself. In that case, restart when you're ready and run `.\install.cmd iris` again.
4. **Sign in.** A window opens and waits for you. **Press Enter**, then **approve the UAC prompt** again.
5. winfiles installs the rest of the system configuration, then your user configuration.
6. It checks everything and prints the steps left to do by hand.

If a UAC prompt goes unanswered, Windows cancels it and the run stops. Run `.\install.cmd iris` again.

A full install takes a while, mostly downloading: one in the test VM took about 47 minutes ([benchmarks](docs/benchmarks.md#clean-installs-in-the-test-vm)). The console shows only warnings, failures and results, so parts of a run can look idle. To follow its progress, open a second PowerShell window:

```powershell
Get-Content $HOME\.local\state\winfiles\run.log -Wait -Tail 20
```

The install has succeeded when the final check reports that all resources are in the desired state. `run.log` then has a line saying the switch `finished`. If something fails, see [If a run fails](#if-a-run-fails).

### Step 3: finish by hand

**Open a new terminal**, so it picks up the new `PATH`, and go back to the repo folder.

1. **Read the post-install notes.** The install printed them. To see them again:

   ```powershell
   .\winfiles.cmd post-install iris
   ```

   For `iris`, they include setting your NixOS password (`wsl -d NixOS -- passwd`) and signing in once with your password so that Remote Desktop accepts it.

2. **Install the apps that can't be installed unattended:**

   ```powershell
   .\winfiles.cmd manual iris
   ```

   This downloads the missing installers to `%USERPROFILE%\.cache\winfiles\manual`. It doesn't run them, so run each one yourself. [`dsc/hosts/iris/manual.yaml`](dsc/hosts/iris/manual.yaml) says why each is on the list.

3. **Restore your PowerShell profile.** winfiles points PowerShell 7 at `~\.config\powershell\`, but your profile's contents aren't in this repo. Put your profile files there. The profile is also what manages your own `PATH` entries.

4. **Set up what's inside NixOS** with your NixOS configuration. winfiles doesn't touch it.

From now on, follow [section 3](#3-a-machine-winfiles-already-manages).

## 2. An already configured Windows 11 machine

Use this for a machine that already has apps and settings you care about.

> [!warning]
> winfiles has no undo or rollback. Back up your files and settings first.

### What changes on your machine

This is what applying `iris` does beyond installing apps. Read it before you continue. The documents linked here, and the entries for [the system](dsc/iris.system.dsc.yaml) and [the user](dsc/emily@iris.home.dsc.yaml), are the full list.

**Your files**

| What | Effect |
|---|---|
| PowerShell 7 profiles (`Documents\PowerShell\profile.ps1` and `Microsoft.PowerShell_profile.ps1`) | Replaced with short files that load your profile from `~\.config\powershell\`. A replaced file is kept beside it, ending in `.bak`. Move your profile contents to the new folder |
| PowerShell `Modules` and `Scripts` folders in `Documents\PowerShell` | Contents move to `~\.local\share\powershell\`, and the old folders become links to it. Items that clash are kept in a `.bak` folder. A link that already points elsewhere is replaced, and its target's contents aren't moved |
| `powershell.config.json` | The user module path is changed |
| `.wslconfig` and `.wslgconfig` | Replaced with the versions in the user entry. The old files are kept, ending in `.bak` |
| Default WSL distribution | NixOS is installed if no distribution is registered under that name, and becomes the default. Other distributions aren't removed |

**The system** ([settings](dsc/modules/system/settings.dsc.yaml), [policies](dsc/modules/system/policies.dsc.yaml), [PowerShell](dsc/modules/system/powershell.dsc.yaml), [WSL](dsc/modules/system/wsl.dsc.yaml), [Remote Desktop](dsc/modules/system/remote-desktop.dsc.yaml), [features](dsc/hosts/iris/system/features.dsc.yaml))

| What | Effect |
|---|---|
| Computer name | Changed to `iris` |
| System code page | Changed to UTF-8. Old programs that expect another code page might show garbled text |
| Windows features | Virtual Machine Platform and Hyper-V are turned on |
| Developer Mode | **Turned off** |
| Sudo for Windows | Turned on, in new-window mode |
| PowerShell remoting | The WinRM service is stopped and set to Manual, so **remoting into this machine stops working** |
| PowerShell 7 | Brought to the latest release on every run. winfiles doesn't remove an older MSI install; uninstall it yourself |
| WSL | Installed or updated if needed. **Inbound connections are blocked by default**; the configuration adds a rule for TCP port 2122 (SSH) from the local subnet on Private networks |
| Remote Desktop | **Turned on**, with its main firewall rules limited to Private networks |
| Browsers | Brave Rewards, Wallet and VPN are disabled by policy, and Edge gets first-run and new-tab policies. The browsers may say they're managed |
| Other settings | Long file paths are enabled, Widgets and web results in Start are turned off, Microsoft Update is turned on, and winget only uses the Microsoft Store source when asked |

**Your Windows preferences** ([settings](dsc/modules/home/settings.dsc.yaml))

File Explorer shows hidden files and file extensions, opens to This PC, and drops recent, frequent and cloud items from Quick Access. Windows switches to the light theme. The taskbar gains End Task, and several search, Start and sync suggestions are turned off.

**Apps**

- Apps that aren't listed are left alone.
- A winget app that winget recognizes as installed is normally left as it is, without being upgraded. PowerShell is the exception. A per-user entry accepts an install in either scope.
- If winget doesn't recognize an app you installed some other way, it may try to install it again.
- If Scoop already has a listed app from a different bucket than the configuration names, the run fails on it. Run `scoop uninstall <app>`, then run `switch` again.
- winget and Scoop add to your `PATH` as they normally do.

If you don't want one of these changes, edit the configuration before you apply it. Deleting a resource means winfiles leaves that item as it is. If other resources depend on the one you delete, update their `dependsOn` too.

### Step 1: prepare

1. Restart Windows if an update or installer is waiting for one.
2. Back up your PowerShell profiles, `.wslconfig` and anything else listed above. Back up any WSL distribution you can't lose.
3. If mise is already installed, upgrade it. The bootstrap doesn't upgrade an existing copy, and an old one stops with a version error:

   ```powershell
   winget upgrade jdx.mise
   ```

   If you have your own mise configuration, winfiles ignores it during its runs and warns you.

### Step 2: bootstrap

```powershell
.\bootstrap.cmd
```

This installs only the tools winfiles needs ([details](docs/run/bootstrap.md)). It doesn't apply any configuration.

### Step 3: see what differs

```powershell
.\winfiles.cmd check iris
```

Approve the UAC prompt. This lists each resource that isn't in the desired state, without applying the configuration. It ends with a failure if anything differs, which is expected here.

The list tells you *which* items would change, not everything about *how*. Compare it with the tables above. Detailed results are saved in `%USERPROFILE%\.local\state\winfiles\dsc`.

### Step 4: apply

When you're satisfied, run:

```powershell
.\winfiles.cmd switch iris
```

Without `--restart`, winfiles never restarts Windows itself, which protects your open work. If it needs a restart, it stops and tells you what's left and which command to run. Restart when you're ready, then run:

```powershell
.\winfiles.cmd switch iris
```

If you'd rather have it restart and continue after you sign in, use `.\install.cmd iris` instead, as in [section 1](#step-2-install).

### Step 5: finish by hand

Follow [finish by hand](#step-3-finish-by-hand) from section 1. Check your `.bak` files for anything you want to carry over. To keep a `.wslconfig` change, make it in [the user entry](dsc/emily@iris.home.dsc.yaml), or the next run replaces it again.

## 3. A machine winfiles already manages

Open a normal PowerShell 7 terminal in the repo folder. The computer is now named after its host, so you can leave out the host and user.

### The usual routine

1. Update the repo, if the changes were made elsewhere:

   ```powershell
   git pull
   ```

   If your copy came from a ZIP file or USB drive and isn't a git clone, git can't update it. Replace it with a clone once git is installed (the configuration installs git through Scoop). Keep any local edits.

2. See what differs:

   ```powershell
   ./winfiles.ps1 check
   ```

3. Apply:

   ```powershell
   ./winfiles.ps1 switch
   ```

4. If it stops for a restart, restart and run `switch` again. Or use `./winfiles.ps1 switch --restart` to have it restart and continue.

`switch` skips what's already correct, so you can run it at any time. It also puts back any managed setting you changed by hand.

> [!tip]
> If `pwsh` isn't found, or PowerShell refuses to run `winfiles.ps1` because of its execution policy (likely with a downloaded ZIP), use `.\winfiles.cmd` instead, for example `.\winfiles.cmd switch`. It takes the same commands.

### If the tools changed

If an update changed `mise.toml` or `mise.lock`, run the bootstrap again before `switch`:

```powershell
.\bootstrap.cmd
```

If a run says a newer mise version is required, run `winget upgrade jdx.mise` first.

### Adding something

1. Find the document it belongs in:

   | What | Where |
   |---|---|
   | An app for one host | `dsc/hosts/<host>/{system,home}/packages*.dsc.yaml` |
   | A setting every host that uses a module should get | `dsc/modules/{system,home}/` |
   | A WSL distribution, or something personal to your user | The user's home entry |

   `vm` includes most of iris's package documents, so a change to one affects both.

2. Copy a neighboring resource and edit it. For winget apps, [docs/config/winget.md](docs/config/winget.md#adding-a-package) says whether it goes under `system` or `home`. For Scoop, see [docs/config/scoop.md](docs/config/scoop.md). For where other things go, see [docs/config/layout.md](docs/config/layout.md).
3. Run the tests, which don't change the machine:

   ```powershell
   ./winfiles.ps1 test
   ```

4. Run `check`, then `switch`.
5. Commit the change.

### Removing something

Deleting a resource only stops winfiles from managing it. It doesn't uninstall or revert anything.

- **A winget app:** add `_exist: false` under the resource's `properties`, apply it with `switch`, then delete the resource. Or uninstall it yourself and delete the resource.
- **A Scoop app:** the resource can't uninstall. Run `scoop uninstall <app>` and delete the resource.
- **Anything else,** such as a setting or WSL distribution: delete the resource, then change it back yourself.

Remember to remove it from every host that lists it.

### Run it from any folder

This is the equivalent of pointing `nixos-rebuild` at your flake:

```powershell
./winfiles.ps1 install-rebuild
```

It writes `winfiles-rebuild.ps1` to `~\bin`. That folder must already be on your `PATH`; winfiles won't add it. You can then run, for example, `winfiles-rebuild switch` from anywhere. If you move the repo, run `install-rebuild` again from its new location.

### Other useful commands

```powershell
./winfiles.ps1                      # list all commands
./winfiles.ps1 help switch          # how to use a command
./winfiles.ps1 system               # apply only the system configuration
./winfiles.ps1 home                 # apply only your user configuration
./winfiles.ps1 post-install         # steps to do by hand
./winfiles.ps1 manual               # download missing installers that need you
./winfiles.ps1 scoop-notes          # suggestions from installed Scoop apps

# Test a single document with DSC
./winfiles.ps1 dsc config test --file dsc/modules/system/policies.dsc.yaml
```

Always run DSC through `./winfiles.ps1 dsc`, not a bare `dsc`, so it can find winfiles' custom resources. `dsc config test` reports success even when something differs, so read its output.

## If a run fails

A failure stops the run where it happens. Anything already applied stays applied.

1. Read the error in the console. It names the batch (a group of resources) or resource that failed.
2. Look in the log:

   ```powershell
   Get-Content $HOME\.local\state\winfiles\run.log -Tail 50
   ```

   DSC's detailed results are in `%USERPROFILE%\.local\state\winfiles\dsc`.

3. Fix the cause, then run the same command again. What's already done is skipped.

| Problem | What to do |
|---|---|
| No configuration is found | Name the host: `.\winfiles.cmd switch iris`. If your username isn't `emily`, add it too: `.\winfiles.cmd switch iris emily` |
| Exit code 3010 | Not an error: a restart is needed. Restart, then run the command shown |
| The install didn't continue after a restart | Run `.\install.cmd iris` again |
| A download or package failed | Check the network, then run again |
| A WSL error about the hypervisor | Turn on virtualization in the BIOS/UEFI settings, then restart |
| A newer mise version is required | `winget upgrade jdx.mise` |
| `check` fails for the computer name or UTF-8 | Restart: both take effect only after one |

## Trying changes in a virtual machine

Use the `vm-quick` host for a fast test and `vm` for a full one. Name the host, since a VM's computer name doesn't choose it:

```powershell
.\install.cmd vm-quick
```

[docs/dev/test-vm.md](docs/dev/test-vm.md) explains how to create the VM and copy the repo into it. Run `bootstrap.cmd` and `install.cmd` on the VM's desktop or with `test-vm-unelevated`, not in an elevated session.
