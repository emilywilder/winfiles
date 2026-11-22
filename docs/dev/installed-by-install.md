# What `just install` installs

What `just install` installs itself on the way, in order, and what is installed twice. What has to be in place before it starts is in [dependencies.md](dependencies.md).

## In order

In the order the commands run them. Each skips what's already done.

1. **`system`** (elevated, one UAC prompt, `scripts/Invoke-Configuration.ps1` on `dsc/<host>.system.dsc.yaml`). The resources that report they will need a restart go first, with what they depend on, and a restart pending after them stops the run (3010, so a clean install runs `just install` twice); the rest follow:
   1. What needs a restart, found at run time from what resources report (`_restartRequired`), usually:
      - The host's optional features (Virtual Machine Platform, plus Hyper-V on iris), which WSL depends on. Enabling one leaves a restart pending.
      - WSL (`Winfiles.Wsl/Wsl`).
      - The computer's name (`Winfiles/ComputerName`).
   2. The gate: while Windows has a restart pending, the run restarts it (when this run made it pending) or stops, with 3010. One restart covers all three.
   3. The rest of `dsc/<host>.system.dsc.yaml`, the system configuration:
      - The PowerShell 7 MSIX (`Microsoft.WinGet/Package`).
      - The machine-wide winget packages (runtimes, base with gsudo, and the rest).
      - Policies and settings in the registry, and `msstore` made explicit.
      - WSL's Hyper-V firewall settings.
2. **`home`** (unelevated):
   - Scoop (`Winfiles.Scoop/Scoop`, from its own installer).
   - git through Scoop, which adding buckets needs, then the buckets and apps, including `just` and `yq` in `modules/home/dev.dsc.yaml`.
   - The per-user winget packages, including `jdx.mise` in `modules/home/base.dsc.yaml`.
   - PowerShell's profiles, module junctions and modules.
   - `.wslconfig` and `.wslgconfig`.
   - The user's WSL distributions, if any (`dsc/users/<user>@<host>/wsl.dsc.yaml`: NixOS for emily on iris and vm, Alpine on vm-quick). Each needs Virtual Machine Platform enabled, WSL 2.4.4 or later and no restart pending, and downloads its image.
3. **`check`** and **`post-install`** install nothing.

## Handed over, and installed twice

- `jdx.mise` is handed over: the bootstrap installs it with winget, naming it itself, and `modules/home/base.dsc.yaml` lists the same package, so from the first `just home` the configuration manages the bootstrap's copy. That's how Nix's installer and nix-darwin split it too: the installer installs Nix from its own release, and the configuration then manages that Nix. The list only installs, so it doesn't upgrade mise; `min_version` in `mise.toml` stops a run on an older one with the `winget upgrade jdx.mise` hint.
- `Microsoft.VCRedist.2015+.x64` comes with `jdx.mise`, as its dependency. Nothing in the configuration relies on it: vm-quick's "already installed" package is Edge, which Windows ships.
- `just`, `gsudo`, `yq` and pwsh are installed twice, as different copies: `mise.toml` provides the ones the run uses, and the configurations install their own (Scoop's `just` and `yq`, winget's `gerardog.gsudo`, the PowerShell MSIX). The commands use `mise.toml`'s, through `Invoke-Clean.ps1`, which also ignores any mise configuration other than the repo's `mise.toml`, with a warning.
