# Computer name

`dsc/hosts/<host>/computername.dsc.yaml`, included by each system entry, names the computer after its host with `Winfiles/ComputerName`. The test VMs are renamed `vm` and `vm-quick` too, since their names never picked a host.

- Windows applies a rename at the next restart, so the resource compares the pending name (`ComputerName`) with the active one (`ActiveComputerName`). `test` is in the desired state only once the active one matches.
- `set` renames only when the pending name differs, so rerunning it while a rename waits changes nothing, and just warns that a restart is needed.
- Every operation reports `_restartRequired` while the active name isn't the wanted one. So a `test` run shows ahead of time that `set` will need a restart. DSC only reports it; the run restarts ([run/restarts.md](../run/restarts.md)).
- It uses `Rename-Computer`, not `Microsoft.Windows/Registry` ([reference](../reference/windows.md#renaming-the-computer)).

Trade-off: `winfiles.ps1 check` fails until the restart, and `winfiles.ps1` still picks the old name from `COMPUTERNAME` until then, so `install.cmd <host>` keeps passing the host. Revisit if a check shouldn't fail while a rename waits.
