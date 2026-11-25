# Packages

Where packages are listed, and which installer each kind goes through: [winget.md](winget.md), [scoop.md](scoop.md), or by hand ([manual.md](manual.md)).

Each feature (base, dev, gaming, internet, productivity, media) has a document of the same name in `dsc/modules/system` and `dsc/modules/home`.
- `modules/system/runtimes.dsc.yaml` holds the shared runtimes.
- `dsc/hosts/<host>/system/hardware.dsc.yaml` and `home/hardware.dsc.yaml` hold what only one machine wants.
- MSIX frameworks (VCLibs, UI.Xaml, .NET Native, Windows App Runtime) are left out: the image and the Store supply most of them, and winget installs one that an app declares along with it ([reference](../reference/winget.md#dependencies-of-an-app)). Revisit if a new app's dependency fails to install: list the dependency first.

Packages managed elsewhere are left out of these lists:

| Package | Managed by |
|---|---|
| PowerShell | `modules/system/powershell.dsc.yaml` ([powershell.md](powershell.md)) |
| DSC | `mise.toml` ([dev/tooling.md](../dev/tooling.md)) |
| WSL | `Winfiles.Wsl/Wsl`, in `modules/system/wsl.dsc.yaml` ([wsl.md](wsl.md)) |
| IntelliJ IDEA | JetBrains Toolbox |
| Python, Meld | Scoop, in `modules/home/dev.dsc.yaml` |
| Discord | Scoop, in `modules/home/internet.dsc.yaml`: winget's installer asks for UAC mid-run ([reference](../reference/apps.md)) |
| What can't be installed unattended | `dsc/hosts/<host>/manual.yaml` ([manual.md](manual.md)) |
