# Architecture

How the configuration is structured, and why. This is the overview: each area links to the doc that covers its details and trade-offs. How a run applies the documents is in [install.md](install.md).

## Structure

The layout is modelled on NixOS and Home Manager (see nix-starter-configs). Each configuration is an entry document directly in `dsc/`, split by the privilege its `set` needs:

| Document | Like | Privilege | Applied by |
|---|---|---|---|
| `dsc/<host>.system.dsc.yaml` | `nixosConfigurations.<host>` | elevated, declared once at its top | `just system` |
| `dsc/<user>@<host>.home.dsc.yaml` | a standalone `homeConfigurations."<user>@<host>"` | unelevated | `just home` |
| `dsc/modules/{system,home}/` | modules | the entry's | through an entry |
| `dsc/hosts/<host>/` | one machine's differences | the entry's | through an entry |
| `dsc/users/<user>@<host>/` | one user's own choices on a host | unelevated | through the home entry |

Entries only list Includes; modules hold nothing specific to one person or machine, and don't include each other, so each also runs on its own. The hosts are `iris`, and `vm` and `vm-quick` for test VMs. The rules, and how to add a host, are in [config/layout.md](config/layout.md).

`just system`, `home`, `check` and `install` don't give DSC the entries. They flatten them, split the result into batches by privilege, and run each batch at its level ([run/flat-configuration.md](run/flat-configuration.md)).

## Organized like Nix, run like DSC

Nix is the model for how the files are laid out, not for how they're evaluated: there are no options, no list merging and no generations. Everything winfiles adds has to pass three tests:

1. Every checked-in document runs under plain `just dsc config test|set --file <document>`, and gives the output DSC gives.
2. winfiles' scripts only turn documents into documents (the flat copy, the batches, the aggregate), and DSC does all the work on resources.
3. Take the scripts away, and the documents still apply, one at a time, in an order you choose.

So the checked-in documents contain only what DSC understands, plus metadata it ignores (`metadata.winget.securityContext`, Microsoft's own name, as `winget configure` reads it). Privilege and restarts, which DSC has no notion of, live in the scripts. Where Nix does something DSC can't (modules that include each other, `lib.mkIf`), it's left out, not imitated with a dialect ([ruled-out.md](reference/ruled-out.md#a-dialect-of-the-documents)).

## What's configured

- **Optional features.** One `Microsoft.Windows/OptionalFeatureList` per host: Virtual Machine Platform, plus Hyper-V on iris. [config/features.md](config/features.md)
- **Packages.** A document per feature (base, dev, gaming, internet, productivity, media) in each of `modules/system` and `modules/home`. [config/packages.md](config/packages.md)
  - **winget:** one resource per package; machine-wide in `system`, per-user (`_scope: User`) in `home`. [config/winget.md](config/winget.md)
  - **Scoop:** installed by its own installer, unelevated, with lists of buckets and apps. [config/scoop.md](config/scoop.md)
  - **By hand:** what can't be installed unattended, which `just manual` downloads. [config/manual.md](config/manual.md)
- **WSL.** The WSL package and Virtual Machine Platform in the system entry, its Hyper-V firewall, and each user's distributions in their own document. [config/wsl.md](config/wsl.md)
- **PowerShell.** The PowerShell 7 MSIX and remoting off in the system entry; module folders, PSGallery, modules and profile stubs in the home entry. [config/powershell.md](config/powershell.md)
- **The computer name,** after the host, applied with the restart. [config/computer-name.md](config/computer-name.md)
- **Registry settings and policies,** in `modules/{system,home}/settings.dsc.yaml` and `modules/system/policies.dsc.yaml`, many taken from WindowsDeveloperConfig. [config/settings.md](config/settings.md)

Where no built-in resource does the job, winfiles has its own `Winfiles/*` resources: [config/resources.md](config/resources.md).
