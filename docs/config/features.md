# Optional features

`dsc/hosts/<host>/system/features.dsc.yaml` holds the Windows optional features a host relies on, in one `Microsoft.Windows/OptionalFeatureList`: Virtual Machine Platform, plus Hyper-V on iris, which hosts the test VMs. Add new features there. DISM doesn't enable a feature's children along with it, so each one is listed, parents first.

The system entry includes it, so `winfiles.ps1 system` applies it and `winfiles.ps1 check` tests it. The resource needs elevation even for `get` ([reference](../reference/dsc.md#optionalfeaturelist-and-elevation)), so the document can only run on its own from an elevated shell: `winfiles.ps1 dsc config test --file dsc/hosts/iris/system/features.dsc.yaml`. It can't report a restart from `test`, so it reaches the restart batch through WSL's `dependsOn` ([run/restarts.md](../run/restarts.md)).

## Not done yet

- **Optional features that report `_restartRequired` from `test`.** They report nothing, so they ride along through WSL's `dependsOn` and are only caught by the pending-restart check after a batch. A resource of their own that reports it would make that explicit.
