# WSL

How WSL and `wsl.exe` behaved when checked, and what in winfiles relies on it. The design is in `docs/config/wsl.md`.

## Versions and install by name

- WSL 2.4.4 is the first with `wsl --install --from-file` and `--name`. It's `Winfiles/Wsl`'s default `minimumVersion`.
- `wsl --install <name>` installs a distribution from `wsl --list --online` by name alone. Older Store entries refuse `--name`, so `Winfiles/WslDistribution` passes none. Checked 2026-11-21 in the test VM with Debian (`surveys/wsl-by-name/`); `test` then found it in the desired state.
- `wsl --install --from-file` takes an Alpine minirootfs `.tar.gz`, installed through `Winfiles/WslDistribution` with its sha256 (checked 2026-11-15, iris).
- `wsl --update` updated 2.3.26 to 3.0.5 (2026-11-18, test VM, through `install.cmd vm-quick`). On a machine with no WSL it installed WSL (2026-11-18, `updated` checkpoint). Whether `wsl --install` updates an installed WSL package hasn't been checked, so `Winfiles/Wsl` runs `--update` for an old one.
- `wsl.exe` exits 1641 for success with a restart already started, as well as 3010.

## The inbox wsl.exe

- With no WSL package, the inbox `wsl.exe` in System32 exits 1 with only "For more information please visit https://aka.ms/wslinstall" when its stdin isn't a console, and under DSC stdin is DSC's pipe. `cmd /c "wsl.exe ... <con > file 2>&1"` makes it read the console the process is attached to. Checked 2026-11-18 in the test VM, running `wsl --install --no-distribution` elevated from `updated`:
  - from a console: worked;
  - with output piped: worked;
  - with stdin piped, with or without `<NUL`: failed;
  - with stdin piped and `<con`: worked, with cmd returning the exit code and the output in the file.
- Asked for its version with no WSL package, the inbox `wsl.exe` waits 60 seconds for a key press that would install WSL (seen 2026-11-17). So the resources read the version from the file version of `Program Files\WSL\wsl.exe`, or from the package's registration under `AppxAllUserStore`, and never run `wsl.exe` for it.
- The inbox `wsl.exe` ignores `WSL_UTF8` and writes UTF-16, so its output has NULs to strip.
- A full `install.cmd vm-quick` through DSC and `gsudo --direct` succeeded with `<con`, so the process is attached to a console there (2026-11-18).

## The feature and the restart

- Right after `wsl --install`, before any restart, Virtual Machine Platform already reads as enabled (CIM `InstallState` 1, `RestartNeeded` false, build 26300). The pending restart shows only in `Component Based Servicing\RebootPending`.
- The hypervisor starts at boot, so `Win32_ComputerSystem.HypervisorPresent` only means something once no restart is pending. It catches virtualization turned off in the firmware or not passed through to a VM, where the feature still reads as enabled and WSL as installed.

## First run

`OOBEComplete` under `HKCU\...\Lxss`, set before any distribution is installed, stops the "Welcome to WSL" window from opening (from WindowsDeveloperConfig). In a clean `vm-quick` run (2026-11-18), it was absent before `home`, and the window didn't open.

## Hyper-V firewall

- With mirrored networking, inbound traffic to WSL goes through the Hyper-V firewall, per VM creator. WSL's creator is `{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}`. Host rules that name no program are merged in.
- WSL doesn't register its creator when it's installed or when its service starts (checked on WSL 3.0.3, in a test VM without Hyper-V), so `modules/system/wsl.dsc.yaml` creates the setting itself.
- `Microsoft.Windows/FirewallRuleList` only manages host rules. The WMI adapter found no `root.StandardCimv2/MSFT_NetFirewallHyperV*` resource (each try spent about 35s in adapter discovery). The NetSecurity cmdlets work, and reading needs no elevation.
