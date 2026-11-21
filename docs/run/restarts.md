# Restarts

How a run finds what will need a restart, applies it first, and restarts once. Continuing after the restart is in [resume.md](resume.md).

## Resources report it

No document lists restarts, because a restart is something the run does. Resources report that they will need one with `_restartRequired`, which DSC 3.3.0 takes from `test` and `set` results. `Winfiles/Wsl` and `Winfiles/ComputerName` report it.

1. Before applying anything, `Find-RestartResources.ps1` tests each elevated batch. It prints a `winfiles-restart: <type>|<name>` line for each resource that reported a restart.
2. If any did, the batches are made again with `ConvertTo-FlatConfiguration.ps1 -First`. That puts those resources, and everything they depend on, in a first elevated batch (stage `restart`). The optional features come along through WSL's `dependsOn`.
3. `Set-RestartStage.ps1` tests that batch and applies what differs. If Windows then has a restart pending, the run restarts and exits 3010.
4. After each of the other elevated batches, the machine is asked again, which catches a restart nothing reported. That check hasn't fired in a real run yet (below).
5. If only the new computer name is still pending at the end of the run, it restarts and exits 3010.

After the restart, `install` runs again. The test now finds those resources done, so nothing has to be remembered across the restart. A clean install restarts once, for the features, WSL and the rename together.

The built-in `Microsoft.Windows/OptionalFeatureList` can't report a restart from `test`, and its per-feature `restartRequired` says `Possible` for every feature, so winfiles doesn't use it. A restart the features need is read from the machine after they're applied ([reference](../reference/dsc.md#optionalfeaturelist-and-restarts)). DSC puts `restartRequired` on each resource's own entry in a result, so `Get-RestartReport` in `scripts/dsclog.ps1` reads the flattened entries ([reference](../reference/dsc.md#where-restartrequired-lands)).

## What counts as pending

`scripts/restart.ps1`, which the resume shares, reads what counts as pending from the machine:
- **Component servicing (`RebootPending`)** blocks the run, because installers refuse to run while it's set.
- **A pending rename** can wait for a restart that's happening anyway.

The run restarts Windows by itself only when nothing was pending before this run applied anything. It counts down 10 seconds in a `Write-Progress` bar, for Ctrl+C, and doesn't use `-Force`. Otherwise it only asks, since the restart may be Windows Update's.

`Winfiles/ComputerName` is in its desired state only once the active name matches, so `check` fails while a rename waits ([architecture.md](../architecture.md#winfilescomputername)).

## Trade-offs

- Every elevated batch is tested once more before the first `set` (11–24s, [benchmarks](../benchmarks.md#finding-what-needs-a-restart)). In return, nobody has to write down the restart set, and there's no restart when nothing needs one. Revisit if that test gets slow enough to notice, or if a resource can't report its restart from `test`.
- The reasons for a restart are read from the machine rather than counted. A count would be lost across the restart, and it can't see a restart that Windows Update or an installer asked for. Revisit if a reason is missed.
- Whether a restart blocks installers is the machine's answer (`RebootPending`), not a table of resource types. Revisit if a resource needs to say it itself.
- `PendingFileRenameOperations` isn't read, since nearly every installer sets it. Revisit if an install step fails because of it.
- The rename is applied with the features and WSL, before the installers, so one restart serves all three. Revisit if renaming ahead of the installers causes trouble.

## Not done yet

- **A restart that becomes pending after a non-restart elevated batch.** The check exists in `Invoke-Configuration.ps1` and never fired in either VM run, so it has only been read, not seen. Needs a resource that makes one pending without reporting `_restartRequired`; the optional features are the candidate, but both runs reported WSL first.
- **A Pester test of the restart gate.** A child process can't mock what Windows says about a pending restart, so the end of `Set-RestartStage.ps1` and the check after each batch are untested. A seam for `Test-BlockingRestartPending` would let a test set it.
- **Test fewer resources to find a restart.** Testing only the resource types that can report a restart would cut the extra pass (11s on `vm-quick`, 24s on `vm`). Worth it only if the pass becomes noticeable on a bigger host.
