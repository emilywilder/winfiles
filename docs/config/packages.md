# Packages

Where packages are listed, and which installer each kind goes through: [winget.md](winget.md), [scoop.md](scoop.md), or by hand ([manual.md](manual.md)).

A host's packages are its own: one resource per package, in `packages-<category>.dsc.yaml` documents in `dsc/hosts/<host>/system` and `dsc/hosts/<host>/home`, split however suits that host. Two hosts that both want dev tools each list their own; a host that wants exactly another's includes its documents, as `vm` does iris's ([layout.md](layout.md)).
- iris has base, dev, gaming, internet, productivity and media on each side, and `hosts/iris/system/packages-runtimes.dsc.yaml`, which the system entry includes before the others, with `dependsOn` on it.
- `hardware.dsc.yaml` on either side holds what only one machine's hardware wants.
- A package that only one document needs a runtime for keeps that runtime in the same document, with `dependsOn` on it ([layout.md](layout.md)).
- Scoop's buckets, which package documents depend on, are in `modules/home/scoop-core.dsc.yaml` ([scoop.md](scoop.md)).
- MSIX frameworks (VCLibs, UI.Xaml, .NET Native, Windows App Runtime) are left out: the image and the Store supply most of them, and winget installs one that an app declares along with it ([reference](../reference/winget.md#dependencies-of-an-app)). Revisit if a new app's dependency fails to install: list the dependency first.

Packages managed elsewhere are left out of these lists:

| Package | Managed by |
|---|---|
| PowerShell | `modules/system/powershell.dsc.yaml` ([powershell.md](powershell.md)) |
| DSC | `mise.toml` ([dev/tooling.md](../dev/tooling.md)) |
| WSL | `Winfiles.Wsl/Wsl`, in `modules/system/wsl.dsc.yaml` ([wsl.md](wsl.md)) |
| IntelliJ IDEA | JetBrains Toolbox |
| Python, Meld | Scoop, in `hosts/iris/home/packages-dev.dsc.yaml` |
| Discord | Scoop, in `hosts/iris/home/packages-internet.dsc.yaml`: winget's installer asks for UAC mid-run ([reference](../reference/apps.md)) |
| What can't be installed unattended | `dsc/hosts/<host>/manual.yaml` ([manual.md](manual.md)) |
