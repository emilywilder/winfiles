# Optional goals

Things that would improve winfiles but that nothing needs yet. None is scheduled and none blocks an install. Each item says why it isn't done, what would make it worth doing, and where the background is recorded. Add an item when work turns one up; delete it when it's done (the doc that records the change says so) or when the reason for it goes away. Dated 2026-11-19, from the work on `feat/drop-privs`.

## Checks not made

- **Run iris through the batches.** The documents are migrated and flatten, but only `vm-quick` and `vm` have been installed this way. Worth it before the next install on iris. Background: `install.md`, "What needs a restart".
- **A restart that becomes pending after a non-restart elevated batch.** The check exists in `Invoke-Configuration.ps1` and never fired in either VM run, so it has only been read, not seen. Needs a resource that makes one pending without reporting `_restartRequired`; the optional features are the candidate, but both runs reported WSL first.
- **How many UAC prompts `just system` and `just check` give from an unelevated shell.** `just install` gives one (checked in the VM); whether gsudo prompts once or per elevated batch from a plain terminal is unchecked. Background: `install.md`, "Batches by privilege".
- **The bootstrap retry's success path.** After `0x8A15000F` it runs `winget source update` and retries once; Pester covers only the second failure, because the success path goes on to change the machine. Check it the next time a clean VM bootstrap hits the error, or force it in a VM. Cause of the error is unknown (first winget call after a checkpoint restore, 2026-11-19, gone on the next try).

## Failures that are hard to find

- **Other resources writing their failures to `run.log`.** DSC's stderr goes to the console only (capturing it would lose the progress bar), so a resource has to log for itself. `Winfiles/Wsl` and `Winfiles.WinGet/Package` do; the Scoop and file lists and the registry resources don't. Do it when one of their failures is as hard to find as the winget one was. Background: `install.md`, "What a run says".
- **A retry for `0x80071130`** ("Fast Cache data not found"), seen once from `winget dscv3 package --get` right after a portable `Kubernetes.kubectl` install, 7m07s into a `vm` user batch; a rerun passed. Cause unknown and the package whose `get` failed isn't recorded, so no retry yet. If it recurs, the `[winget]` line in `run.log` now names the package; retry there only if it keeps happening.
- **Resource-level events** at the default level (which package is installing) and the full output at `debug`. Needs stderr read without losing the progress bar. Researched, not tried. Background: `install.md`, "Not done yet, the resource-level events".

## Cheaper or tighter

- **Test fewer resources to find a restart.** Every elevated batch is tested once more before the first `set` (11s on `vm-quick`, 24s on `vm`). Testing only the resource types that can report a restart would cut it. Worth it only if the pass becomes noticeable on a bigger host.
- **Refuse a resource-level `securityContext` in a flat document run by hand.** The flattener removes the tag from its output, but a flat document written another way, with a tag on a whole-resource-tested type, would count it as a difference. Low value: nothing writes one.
- **Refuse `..` in a `configurationFile`.** DSC 3.3.0 does; the flattener resolves it, so a bad entry passes `just install` and fails by hand. Background: `flat-configuration.md`.
- **A Pester test of the restart gate.** A child process can't mock what Windows says about a pending restart, so the old in-process tests went with `Set-System.ps1`. A seam for `Test-BlockingRestartPending` would let a test set it.

## Structure

- **Shared layers or modules that include modules.** Would remove the repeated module lists across `iris`, `vm` and `vm-quick`, but breaks "every document runs under plain dsc" for a module run alone. Revisit if the lists drift. Background: `architecture.md`, `flat-configuration.md`.
- **Optional features that report `_restartRequired` from `test`.** They report nothing, so they ride along through WSL's `dependsOn` and are only caught by the pending-restart check after a batch. A resource of their own that reports it would make that explicit.
- **Move entries out of `dsc/`.** DSC 3.3.0's refusal of `..` is why entries stay there. With flattening reading the files itself, the entries could move later; a separate decision.
