# Architecture

How the configuration is structured, and why. This is the overview: each area links to the doc that covers its details and trade-offs. How a run applies the documents is in [install.md](install.md).

## Structure

The layout is modelled on NixOS and Home Manager (see nix-starter-configs). Each configuration is an entry document directly in `dsc/`, split by the privilege its `set` needs:

| Document | Like | Privilege | Applied by |
|---|---|---|---|
| `dsc/<host>.system.dsc.yaml` | `nixosConfigurations.<host>`, `hosts/<host>/default.nix` | elevated, declared once at its top | `winfiles.ps1 system` |
| `dsc/<user>@<host>.home.dsc.yaml` | a standalone `homeConfigurations."<user>@<host>"`, `hosts/<host>/home.nix` | unelevated | `winfiles.ps1 home` |
| `dsc/modules/{system,home}/` | `modules/nixos`, `modules/home-manager`: reusable code for one concern, with scalar parameters | the folder's: `system` elevated, `home` not | through an entry, or on its own |
| `dsc/hosts/<host>/{system,home}/` | the host's own choices: features, package lists, hardware | the folder's | through an entry, or on its own |

An entry includes the modules its host uses, passing the host's values in `parametersContent`, then the host's own documents; a home entry also holds the user's own resources, such as their WSL distributions. Only entries include, so every other document runs on its own, and an entry reaches each document once. Packages and distributions are written out one resource each in the host's documents, so hosts can differ freely; a host that wants exactly another's includes its documents, as `vm` does iris's. The rules, and how to add a host, are in [config/layout.md](config/layout.md).

`winfiles.ps1 system`, `home`, `check` and `switch` don't give DSC the entries. They flatten them, split the result into batches by privilege, and run each batch at its level ([run/flat-configuration.md](run/flat-configuration.md)).

## Organized like Nix, run like DSC

Nix is the model for how the files are laid out, not for how they're evaluated: there are no options, no list merging and no generations. Everything winfiles adds has to pass three tests:

1. Every entry runs under plain `winfiles.ps1 dsc config test|set --file <entry>`, and gives the output DSC gives. So does every other document, since none of them includes anything.
2. winfiles' scripts only turn documents into documents (the flat copy, the batches, the aggregate), and DSC does all the work on resources.
3. Take the scripts away, and the documents still apply, one at a time, in an order you choose.

So the checked-in documents contain only what DSC understands, plus metadata it ignores (`metadata.winget.securityContext`, Microsoft's own name, as `winget configure` reads it). Privilege and restarts, which DSC has no notion of, live in the scripts. Where Nix does something DSC can't (merging a module imported twice, `lib.mkIf`), it's left out, not imitated with a dialect ([ruled-out.md](reference/ruled-out.md#a-dialect-of-the-documents)).

## What's configured

- **Optional features.** One `Microsoft.Windows/OptionalFeatureList` per host: Virtual Machine Platform, plus Hyper-V on iris. [config/features.md](config/features.md)
- **Packages.** Each host's own documents, `packages-<category>.dsc.yaml` in `hosts/<host>/system` and `hosts/<host>/home`; iris's are base, dev, gaming, internet, productivity and media, plus its runtimes. [config/packages.md](config/packages.md)
  - **winget:** one resource per package; machine-wide in `system`, per-user (`_scope: User`) in `home`. [config/winget.md](config/winget.md)
  - **Scoop:** installed by its own installer, unelevated, then one resource per bucket and per app. [config/scoop.md](config/scoop.md)
  - **By hand:** what can't be installed unattended, which `winfiles.ps1 manual` downloads. [config/manual.md](config/manual.md)
- **WSL.** The WSL package and Virtual Machine Platform, and its Hyper-V firewall, in `modules/system/wsl.dsc.yaml`; each user's distributions in their home entry. [config/wsl.md](config/wsl.md)
- **PowerShell.** The PowerShell 7 MSIX and remoting off in `modules/system/powershell.dsc.yaml`; module folders, PSGallery and profile stubs in `modules/home/powershell.dsc.yaml`, and each host's modules in its `powershell-modules.dsc.yaml`. [config/powershell.md](config/powershell.md)
- **The computer name,** after the host, applied with the restart. [config/computer-name.md](config/computer-name.md)
- **Registry settings and policies,** in `modules/{system,home}/settings.dsc.yaml` and `modules/system/policies.dsc.yaml`, many taken from WindowsDeveloperConfig. Remote Desktop, on iris, in `modules/system/remote-desktop.dsc.yaml`. [config/settings.md](config/settings.md)

Where no built-in resource does the job, winfiles has its own `Winfiles/*` resources: [config/resources.md](config/resources.md).
