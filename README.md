# winfiles: declarative Windows rebuilds, inspired by NixOS and nix-darwin

I do it for Linux and macOS, so why not?

> [!caution]
> This is my personal configuration, and it's still a work in progress. [INSTALL.md](INSTALL.md) covers only my own machines. If you're not me, read [what it changes](INSTALL.md#what-changes-on-your-machine) before running any of it.

## What it is

winfiles keeps the description of a Windows 11 machine in text files: which apps are installed, which Windows features are on, and how a number of settings are set. One command then makes the machine match that description.

```powershell
./winfiles.ps1 switch
```

To change the machine, you edit the files and run the command again. To set up a new machine, you run the same configuration on it. Because the files are in git, you can see what changed, when and why.

The idea comes from `nixos-rebuild switch` and [nix-darwin](https://github.com/nix-darwin/nix-darwin)'s `darwin-rebuild switch`: take a declarative configuration and apply it to the machine. winfiles is the Windows counterpart to my Nix flake configuration for Linux and macOS.

**winfiles doesn't use Nix and isn't a replacement for it.** The right way to use Nix on Windows is inside WSL (Windows Subsystem for Linux). winfiles looks after the Windows side, including installing WSL and a distribution such as [NixOS-WSL](https://github.com/nix-community/NixOS-WSL). What happens inside that distribution is the job of its own configuration.

## What it manages

| Area | Examples |
|---|---|
| Apps | Machine-wide and per-user apps from winget, command-line tools and fonts from Scoop |
| Windows features | WSL 2's Virtual Machine Platform, Hyper-V |
| Settings and policies | File Explorer, taskbar, Start search, theme, browser policies, Remote Desktop, UTF-8 as the system code page |
| The computer's name | Each configuration names the machine it's applied to |
| PowerShell | PowerShell 7, modules, module folders, profile locations |
| WSL | The WSL package, distributions, `.wslconfig`, inbound firewall rules |

Some apps can't be installed without someone clicking through them. winfiles lists those, and can download their installers for you to run.

## The pieces it's built from

You don't need to know these tools to follow the rest of this page.

| Tool | What it does here |
|---|---|
| [DSC v3](https://github.com/PowerShell/DSC) (Desired State Configuration) | Microsoft's engine for declarative configuration. It reads the YAML files, checks each item, and changes what differs |
| [winget](https://learn.microsoft.com/windows/package-manager/) | The package manager that comes with Windows |
| [Scoop](https://scoop.sh) | A second package manager, which installs into your user profile without administrator rights |
| [mise](https://mise.jdx.dev) | Provides the exact versions of the tools winfiles itself runs on: PowerShell 7, DSC, gsudo and yq |
| [gsudo](https://github.com/gerardog/gsudo) | Lets one run move between administrator and normal rights |

## What it looks like

Each thing you want is one entry, called a *resource*. This one says that Visual Studio Code should be installed for the current user:

```yaml
- type: Winfiles.WinGet/Package
  name: Microsoft.VisualStudioCode
  properties:
    id: Microsoft.VisualStudioCode
    source: winget
    acceptAgreements: true
    _scope: User
  metadata:
    description: Install Visual Studio Code
```

Resources are grouped into YAML files (*documents*). Each machine (*host*) has two top-level documents, called *entries*, that pull the others together:

| Entry | What it covers | Rights |
|---|---|---|
| `dsc/<host>.system.dsc.yaml` | The whole machine | Administrator |
| `dsc/<user>@<host>.home.dsc.yaml` | One user's apps and settings | Normal user |

```text
dsc/
  iris.system.dsc.yaml        entry: the "iris" machine
  emily@iris.home.dsc.yaml    entry: my user on it
  modules/{system,home}/      reusable settings, shared between hosts
  hosts/<host>/{system,home}/ each host's own choices, such as its package lists
```

There are three hosts: `iris`, my machine, and `vm` and `vm-quick`, which test installs in a virtual machine.

## What happens when you run it

`switch` does this:

1. **Asks for administrator approval (UAC)** at the start. Steps that must run as a normal user drop back to normal rights by themselves.
2. **Applies whatever needs a restart first**, such as Windows features. If a restart is then pending, it stops and tells you. With `--restart`, it restarts Windows itself and carries on after you sign in and press Enter.
3. **Applies everything else.** Anything that's already correct is left alone, so you can run it as often as you like. A failure stops the run.
4. **Checks the result** and fails if anything is still missing.
5. **Prints the steps you have to do by hand.**

To see how the machine differs from its configuration without applying anything, run:

```powershell
./winfiles.ps1 check
```

## Getting started

[INSTALL.md](INSTALL.md) has the full steps for a [fresh Windows 11 install](INSTALL.md#1-a-fresh-windows-11-install), [a machine that's already set up](INSTALL.md#2-an-already-configured-windows-11-machine) and [a machine winfiles already manages](INSTALL.md#3-a-machine-winfiles-already-manages).

## Where are you coming from?

- [I install things by hand](#if-you-install-things-by-hand)
- [I use Ansible or another enterprise tool](#if-you-use-ansible-or-another-enterprise-tool)
- [I automate my Linux setup](#if-you-automate-your-linux-setup)
- [I use NixOS or nix-darwin](#if-you-use-nixos-or-nix-darwin)

### If you install things by hand

Think of winfiles as a checklist that carries itself out. Instead of downloading installers and clicking through Settings, you write down what you want once.

| By hand | With winfiles |
|---|---|
| Download an installer and click through it | Add the app to a file, then run `switch` |
| Change a toggle in Settings | The setting is written in a file, with a comment saying why |
| Reinstall Windows, then try to remember what you had | Run your configuration on the new install |
| Wonder why something is set the way it is | Read the comment, or the history in git |

Three things may surprise you:

- **The files win.** If you change a managed setting by hand, the next `switch` changes it back. To keep a change, make it in the files.
- **Deleting a line doesn't uninstall anything.** It only means winfiles stops looking after that item. See [removing something](INSTALL.md#removing-something).
- **Your other apps are left alone.** winfiles doesn't uninstall things just because they aren't listed.

There's no undo button. Before the first run on a machine you care about, read [what changes](INSTALL.md#what-changes-on-your-machine).

### If you use Ansible or another enterprise tool

winfiles is local, self-applied configuration for a few personal machines. It isn't a fleet manager. These are rough equivalents, to help you find your way around:

| Ansible | winfiles |
|---|---|
| Playbook for a host | The host's system and home entries |
| Role | A module in `dsc/modules/` |
| Role variables | A module's scalar `parameters`, passed by the entry |
| Host variables and host-specific tasks | `dsc/hosts/<host>/` and the entries |
| Module (`ansible.windows.win_package`, ...) | DSC resource (`Microsoft.WinGet/Package`, ...) |
| Custom module | A `Winfiles/*` resource in `dsc/resources/` |
| `ansible-playbook` | `./winfiles.ps1 switch` |
| `--check` | `./winfiles.ps1 check`, which lists the resources that aren't in the desired state |
| `become` | `securityContext: elevated` on a document or resource; the run changes rights as needed |
| `ansible.windows.win_reboot` | `switch --restart` |

The differences that matter:

- **No control node, inventory or remote push.** Each machine applies its own configuration. Nothing runs on a schedule or reports back.
- **No secrets management** and no central logs. Logs stay on the machine.
- **Plain DSC documents.** There's no templating language or loop of winfiles' own. Every document also runs under plain `dsc config test` and `dsc config set`, through `./winfiles.ps1 dsc` so that DSC can find the custom resources.
- **The scripts add what DSC lacks:** flattening the included documents, ordering them into batches by rights, and handling restarts. DSC does all the work on resources. See [docs/architecture.md](docs/architecture.md).
- **Mostly one resource per item**, such as one per package, so a report names what differs. Registry values are grouped into lists, and a differing list has to be opened to find the value.

winfiles uses DSC v3, which takes YAML or JSON documents. It isn't the older PowerShell DSC with MOF files and the Local Configuration Manager.

### If you automate your Linux setup

If you manage a Linux machine with scripts, dotfiles or a configuration tool, the model will be familiar, but Windows adds some wrinkles:

| Linux habit | The winfiles version |
|---|---|
| A bootstrap script on a new machine | `bootstrap.cmd`, then `install.cmd <host>` |
| A system package manager | winget for most apps |
| Packages in your home directory | Scoop, which installs without administrator rights |
| `sudo` for system steps | UAC approval at the start of the run, with gsudo switching rights |
| A `Makefile` or `justfile` | `winfiles.ps1`, with its commands defined in [`commands.jsonc`](commands.jsonc) |
| `/etc` and dotfiles | The registry, mostly, plus a few config files written from the documents |

- **It's declarative, item by item.** Each resource can test its own state and set it, so you describe the result and don't write the steps. Where no existing resource fits, there's a small custom resource or a PowerShell script with separate get, test and set parts.
- **It isn't a dotfiles manager.** It sets where PowerShell looks for your profile, but your profile's contents live outside this repo. It also doesn't change your `PATH`: that belongs to the profile. winget and Scoop still update `PATH` as they normally do.
- **A run ignores your shell's environment.** It starts from the environment Windows builds for your account, so it behaves the same from any terminal. A variable set only in your current shell, such as a proxy, doesn't reach it.
- **Restarts are part of the job.** Some Windows changes only take effect after one.

### If you use NixOS or nix-darwin

The layout and workflow will look familiar. The guarantees won't.

| Nix | winfiles |
|---|---|
| `nixos-rebuild switch`, `darwin-rebuild switch` | `./winfiles.ps1 switch` |
| `nixosConfigurations.<host>`, `hosts/<host>/default.nix` | `dsc/<host>.system.dsc.yaml` |
| `homeConfigurations."<user>@<host>"`, `home.nix` | `dsc/<user>@<host>.home.dsc.yaml` |
| `modules/nixos`, `modules/home-manager` | `dsc/modules/system`, `dsc/modules/home` |
| `imports = [ ... ]` | `Microsoft.DSC/Include`, used by entries only |
| Pointing `nixos-rebuild` at your flake from anywhere | `winfiles-rebuild`, [if you set it up](INSTALL.md#run-it-from-any-folder) |
| The installer installs Nix, which the configuration then manages | On `iris` and `vm`, the bootstrap installs mise, which the configuration then manages |

What you **don't** get:

- **No generations or rollback.** A run changes the live system in place. Checking out an old commit and running `switch` doesn't undo what a newer one added.
- **No purity or full reproducibility.** `mise.lock` pins the tools that run winfiles, but most apps aren't pinned. You get whatever version is current when an app is installed, and some update themselves.
- **No removal by omission.** Deleting a resource leaves the thing installed or set.
- **No atomic switch.** If a run fails partway, what was already applied stays applied. Fix the problem and run it again.
- **No module system.** There are no options, list merging or conditionals. Modules take a few simple values, and package lists are written out for each host or shared as whole documents.
- **No evaluation step.** The YAML is the configuration. Only DSC's own expressions, such as `parameters()`, are computed.

Nix shapes how the files are laid out, not how they're evaluated. Anything Nix does that DSC can't is left out instead of imitated.

For your Linux environment on Windows, keep using Nix inside WSL. winfiles can install NixOS-WSL and write `.wslconfig`, but it leaves `/etc/wsl.conf`, users and `nixos-rebuild` to your NixOS configuration.

## Commands

Run these from the repo folder.

| Command | What it does |
|---|---|
| `./winfiles.ps1` | Lists all commands |
| `./winfiles.ps1 help <command>` | Shows how to use a command |
| `./winfiles.ps1 switch [host] [user] [--restart]` | Applies both configurations, then checks them |
| `./winfiles.ps1 check [host] [user]` | Tests both configurations without applying them (asks for UAC) |
| `./winfiles.ps1 system [host]` | Applies only the system configuration |
| `./winfiles.ps1 home [user] [host]` | Applies only the user's configuration. Note that the user comes first |
| `./winfiles.ps1 post-install [host] [user]` | Shows the steps to do by hand |
| `./winfiles.ps1 manual [host]` | Downloads installers for missing apps that must be installed by hand |
| `./winfiles.ps1 hosts` | Lists the configurations in the repo |
| `./winfiles.ps1 test` | Runs the tests of winfiles' own code, against fakes |

The host defaults to the computer's name, and the user to your Windows username. On a machine where PowerShell 7 isn't set up yet, use `.\winfiles.cmd` in place of `./winfiles.ps1`.

## Learn more

- [INSTALL.md](INSTALL.md): installing and day-to-day use
- [docs/README.md](docs/README.md): an index of all the documentation
- [docs/architecture.md](docs/architecture.md): how the configuration is organized, and why
- [docs/install.md](docs/install.md): what a run does, in order
- [docs/dev/tooling.md](docs/dev/tooling.md): the tools and commands used to work on winfiles
