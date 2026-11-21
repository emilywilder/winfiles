# Bicep

What Bicep's DSC support offered when researched, and why winfiles doesn't use it yet. Researched 2026-11-21. Used by: the item in [config/layout.md](../config/layout.md#not-done-yet).

## What it is

Since DSC 3.2, `bicep local-deploy <host>.bicepparam` drives DSC resources through `dsc-bicep-ext` (a gRPC server that ships with DSC; it's in the 3.3.0 that mise installs), with Bicep as the orchestrator. The older route, `dsc config` running `bicep build`, was removed in 3.2.0-preview.11.

Bicep would bring real modules with parameters (a shared layer for `iris` and `vm`, one module per WSL distribution), `for` loops and `if` conditions that are Bicep's rather than DSC's deprecated `copy` (PowerShell/DSC#1429), per-host `.bicepparam` files, typed properties with editor support, and dependencies from references.

## Why not yet

- **It only applies.** `bicep local-deploy` (Bicep CLI 0.49.2, `--help` read 2026-11-21) has no test, get or what-if mode, so `just check`, testing before `set` and finding the resources that report `_restartRequired` would all go.
- **The documents would stop being DSC's.** They would no longer run under plain `dsc config test|set` or `winget configure`, which breaks the three tests in [architecture.md](../architecture.md#organized-like-nix-run-like-dsc), and the flat copy, batches and aggregate would have nothing to work on.
- **One process, one privilege.** A deployment runs at one level, where winfiles splits each run into elevated and unelevated batches.
- **Custom resources need published types.** The `Winfiles/*` resources would need Bicep types generated from their manifests and published with `bicep publish-extension` (to an OCI registry or a local package), redone on every schema change. Run-time type discovery is listed as a future improvement in bicep-types-dsc.
- **It's experimental twice over.** Both `localDeploy` (a `bicepconfig.json` flag) and the DSC extension are experimental, with no stability date. The modules issue (PowerShell/DSC#1269) was still open. Whether DSC's progress bar, resource warnings and `restartRequired` get through Bicep's per-resource output isn't documented.

Revisit when `local-deploy` gains a test or what-if mode, local resources can be used without publishing types, and local-deploy leaves experimental; then try one module first.

## Sources

- [microsoft/bicep-types-dsc](https://github.com/microsoft/bicep-types-dsc) (the extension, type generation, setup)
- [Announcing DSC v3.2.0](https://devblogs.microsoft.com/powershell/announcing-dsc-v3-2-0/) ("Bicep integration via gRPC (experimental)")
- [Bicep never left: the return of DSC support](https://www.idontlikeai.dev/bicep-never-left-the-peaceful-return-of-microsoft-dsc-support/) (the old `bicep build` route and its removal)
- [How Bicep is bringing back IntelliSense to DSC](https://www.idontlikeai.dev/how-bicep-is-bringing-back-intellisense-to-microsoft-desired-state-configuration/)
- [DSC v3.2: Bicep and Windows resources](https://www.pr0mpt.com/2026-05-19-dsc-v3-2-bicep-and-windows-resources/)
- [Bicep local-deploy quickstart](https://github.com/Azure/bicep/blob/main/docs/experimental/local-deploy-dotnet-quickstart.md) and [local-deploy](https://github.com/Azure/bicep/blob/main/docs/experimental/local-deploy.md) (`bicep local-deploy`, `localDeploy` flag, output)
- [Bicep configuration file](https://learn.microsoft.com/azure/azure-resource-manager/bicep/bicep-config)
- [PowerShell/DSC#1269](https://github.com/PowerShell/DSC/issues/1269) (Bicep modules) and [PowerShell/DSC#1429](https://github.com/PowerShell/DSC/issues/1429) (`copy` deprecated)
