# The test VM

How clean installs are tested. What the VM does, and what full runs in it have confirmed, is in [reference/test-vm.md](../reference/test-vm.md); run timings are in [benchmarks.md](../benchmarks.md#clean-installs-in-the-test-vm). The Pester tests are in [testing.md](testing.md).

## Creating it

Clean installs are tested in a Hyper-V VM, not Windows Sandbox, which can't run WSL 2 ([reference](../reference/test-vm.md#windows-sandbox)). `just test-vm <iso>` (`scripts/New-TestVm.ps1`) creates it, and doesn't start it. With `-Unattended` it skips Windows Setup and signs in automatically at every boot, so the install's restart needs no attention ([reference](../reference/test-vm.md#automatic-sign-in-and-the-blank-password)). It prints the commands for taking a `clean` checkpoint and returning to it. Clean runs restore the `updated` checkpoint.

## The hosts

A test VM's computer name doesn't decide its configuration, so pass the host:
- **`vm`** has every shared module, and none of a real machine's hardware: `.\install.cmd vm`.
- **`vm-quick`** goes through every step of `just install` (features, WSL, both configurations, `check`, `post-install`) and every kind of resource, faster: `.\install.cmd vm-quick`. The shared modules that configure rather than install are included as they are. The package documents are replaced by a few small packages in `dsc/hosts/vm-quick/`, chosen so each package resource still takes its paths:
  - a `Microsoft.WinGet/Package` already installed (Edge), and one to install machine-wide (WinDirStat);
  - a `Winfiles.WinGet/Package` with `_scope: User` (gh);
  - a `Winfiles.Scoop/Package` with no bucket (jq), and one with `bucket: extras` (everything).

  Every Scoop bucket is still added. emily's WSL document there installs a pinned Alpine minirootfs instead of NixOS-WSL, and leaves out `~/.wslconfig` and `~/.wslgconfig`. Its `# post-install:` note is the reminder of what it leaves out.

  Trade-off: a package that only fails in the real lists, or a NixOS-WSL image problem, only shows up under `vm`, so run `vm` before relying on a change to either. Revisit if the two drift, for example when a shared module gains an install that `vm-quick` doesn't cover.

## The recipes

| Recipe | What |
|---|---|
| `just test-vm-copy [name]` | packs the repo with `git archive` and copies it in over PowerShell Direct. By default this is the working tree: commits plus uncommitted changes to tracked files, through `git stash create`. Untracked files are left out, so `git add` new files first. It replaces `~\src\winfiles` in the VM, so edits made inside the VM are lost |
| `just test-vm-unelevated <name> '<command>'` | starts a command unelevated, through a scheduled task in the VM for its user, and reads the output back as it runs, e.g. `'cmd /c .\install.cmd vm-quick'`. It needs someone signed in (a disconnected session counts); UAC prompts still show on the VM's desktop, and after the restart someone signs in and presses Enter. It exits 3010 when the VM stops answering, or when the restart stops the task |
| `just test-vm-run <name> '<command>'`, `just test-vm-shell [name]` | for reading results, e.g. `just test-vm-run <name> 'mise exec -- just check vm'`. PowerShell Direct runs elevated with no UAC, so never run `bootstrap.cmd` or `install.cmd` this way ([reference](../reference/test-vm.md#powershell-direct)) |
| `just test-vm-log [name] [-All]` | follows `run.log` in the VM, showing its last `-Tail` lines first. `-All` also follows winget's `DiagOutputDir`, for the detail behind a failed package (`-All`, not `-Debug`, which is a PowerShell common parameter). It prints `-- no new lines for about Ns` every 30s, so quiet can be told from stuck, and reconnects after a guest restart. It asks for UAC, for `Get-VM` |

Run `bootstrap.cmd` and `install.cmd` in the VM's desktop, or through `just test-vm-unelevated`. That saves typing and returns the output, but isn't unattended. Trade-off: `test-vm-unelevated` needs someone signed in at the VM. Revisit if a run has to work with nobody signed in.

`run.log` shows what the scripts do, but not what Scoop and DSC do in between, so those parts of a run look idle. `Winfiles/Wsl` and `Winfiles.WinGet/Package` write their own lines there ([run/output.md](../run/output.md)). Trade-off: `test-vm-log` shows winget's detail only with `-All`. Revisit if `-All` ends up being passed every time, or if the Scoop or DSC gap gets in the way.
