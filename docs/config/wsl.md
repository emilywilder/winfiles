# WSL

WSL is optional, and so is everything a user puts in it. winfiles does only the Windows side: everything inside a distribution (`wsl.*` options, `/etc/wsl.conf`, users) belongs to the distribution's own configuration. WSL's behaviour is in [reference/wsl.md](../reference/wsl.md).

| Document | Entry | What |
|---|---|---|
| `dsc/modules/system/wsl.dsc.yaml` | system | `Winfiles.Wsl/Wsl`, the WSL package and Virtual Machine Platform, and WSL's Hyper-V firewall (setting it needs elevation); the entry orders it after the host's features |
| `dsc/modules/home/wsl.dsc.yaml` | home | marks WSL's first run done (`OOBEComplete`, from WindowsDeveloperConfig), so the "Welcome to WSL" window doesn't open |
| `dsc/<user>@<host>.home.dsc.yaml` | home | the user's distributions, and `~/.wslconfig` and `~/.wslgconfig` if they want them, after the `WSL` Include |

The two modules are the WSL code every host shares. What differs by host or user is passed in or written out: the SSH port as the `wslSshPort` parameter, and each distribution and config file as a resource in the user's home entry.

A test (`WSL in the entry documents`, in `tests/scripts/ConvertTo-FlatConfiguration.Tests.ps1`) fails when a home entry installs a distribution and its host's system entry has no `Winfiles.Wsl/Wsl`.

## The WSL package

`Winfiles.Wsl/Wsl`'s `test` is in the desired state when:
- WSL is installed at `minimumVersion` (2.4.4 by default, the first with `--from-file` and `--name`);
- Virtual Machine Platform is enabled;
- no restart is pending;
- a hypervisor runs.

`set` runs `wsl --update` for an old WSL, and `wsl --install --no-distribution` for a missing WSL or a disabled feature. It needs elevation only when there's something to do.

- **Restarts.** It never restarts Windows. It reports `_restartRequired` and exits 0, since DSC stops the whole configuration on a non-zero exit. `get` reports it while a restart is pending, and `test` also while Virtual Machine Platform is off, since enabling it leaves one pending. So a run knows ahead of time, and applies WSL first ([run/restarts.md](../run/restarts.md)). A WSL that only needs installing or updating isn't predicted to need a restart; the machine shows it afterwards. `wsl.exe`'s 1641 (success, restart already started) is accepted like 3010.
- **The hypervisor check** catches virtualization that's off in the firmware, or not passed through to a VM. It's only judged once no restart is pending, since the hypervisor starts at boot.
- **Running `wsl.exe`.** The resource runs it through `cmd /c "wsl.exe ... <con > file 2>&1"`, because the inbox `wsl.exe` refuses a piped stdin ([reference](../reference/wsl.md#the-inbox-wslexe)). Its arguments, output and exit code go to `run.log` under `[wsl]`, since DSC shows a resource's stderr only at `trace`. Trade-off: the output reaches the console only when the install fails, not as progress. Revisit if watching it matters.
- **Elevation** is read through `whoami.exe /groups`, so a test can mock it.
- **Shared checks.** `Winfiles.Wsl/Distribution` makes the same checks before installing a distribution. Both read them from `dsc/resources/wslstate.ps1`, which they dot-source.
- **It needs pwsh,** like the other resources, so it doesn't run by hand on a bare machine. That's fine while the bootstrap installs mise's pwsh first. Revisit if the bootstrap ever has to run before mise.

## Distributions

Each distribution is a `Winfiles.Wsl/Distribution` resource of its own in the user's home entry, and none is fine. So far emily has NixOS-WSL and both config files on iris, NixOS-WSL alone on `vm`, and Alpine on `vm-quick`.

- A distribution's `source` is a URL, a local `.wsl`/`.tar` file, or a name from `wsl --list --online`. Without one, the resource's `name` is installed from the online list.
- The resource reads state from the `HKCU\...\Lxss` registration. It never unregisters or moves a distribution, and `location` only applies at install time.
- Before installing, it checks through CIM that the feature is enabled, that a hypervisor runs, that WSL is 2.4.4 or later, and that no restart is pending. If not, it exits 3.
- `~/.wslconfig` and `~/.wslgconfig` are written from inline content by `Winfiles/FileContentList`, one resource per file, since there's no built-in file resource.

Trade-off: each user's distributions are written out in their home entry, rather than passed to a module, so the number of distributions is just the number of resources. So NixOS-WSL is written twice, for iris and vm. A `copy` loop would do it in one module, but DSC deprecates `copy` ([ruled-out.md](../reference/ruled-out.md#a-copy-loop-for-wsl-distributions)), and a list resource would hide the distributions behind a parameter ([ruled-out.md](../reference/ruled-out.md#list-resources-for-a-hosts-items)). Revisit if several users come to share distributions (below).

## Firewall

`modules/system/wsl.dsc.yaml` limits inbound access to WSL to SSH from the local network.
- It sets WSL's default inbound action to Block, on WSL's Hyper-V firewall creator and each of its profiles, creating the creator's setting if WSL hasn't ([reference](../reference/wsl.md#hyper-v-firewall)).
- It declares one Hyper-V rule: TCP `wslSshPort` (2122 by default, the port emily's NixOS configuration gives sshd), Private profile, `LocalSubnet`. A host whose user runs sshd on another port sets `wslSshPort` in `parametersContent` on its system entry's `WSL` Include.
- The rule covers every distribution, since they share WSL's one VM. Another service in a distribution that should be reachable needs its own rule.
- It uses the NetSecurity cmdlets, since `Microsoft.Windows/FirewallRuleList` only manages host rules. Reading them needs no elevation, so `test` stays unelevated.

## Not done yet

- **A shared catalogue of WSL distributions.** A parameterised module can't be included once per distribution, since names must be unique across the flattened documents; one document per distribution (`hosts/iris/home/wsl-<name>.dsc.yaml`) could be included by name instead. Worth it if several users come to share distributions, or the copies drift.
