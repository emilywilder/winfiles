# How dsc shows messages from resources

A visual check, run by hand in a real console, of what DSC does with the lines a resource writes to stderr. It answers whether a slow resource such as `Winfiles/WinGetPackageList` can show which item it's on, while DSC's progress bar sits at "1/3 set 'packages'". Rerun it when `mise.toml` pins a new DSC, and compare with the results below.

`Test/SlowList` is a stand-in resource: `set` waits two seconds per item and reports each one as its `mode` says (see `slowlist.ps1`). It lives here, not in `dsc/resources`, so `just dsc` never discovers it. `just dsc-messages` limits discovery to DSC's own folder and this one.

## Running it

From the repo, in a terminal of its own (DSC only draws its progress bar in an interactive console). Each run takes about 15 seconds and ends with DSC's JSON result; watch the lines and the bar while it runs.

```powershell
mise exec -- just dsc-messages machine-quiet            # today: no messages
mise exec -- just dsc-messages machine-warn             # warn: shows at the default level
mise exec -- just dsc-messages machine-info -l info     # info: needs -l info, and brings DSC's own info lines
mise exec -- just dsc-messages machine-levels -l info   # every level on each item
mise exec -- just dsc-messages machine-env -l info      # shows the DSC_TRACE_LEVEL the child dsc received
mise exec -- just dsc-messages nested-warn              # two levels of Include
mise exec -- just dsc-messages machine-writehost        # Write-Host from a resource: breaks it (exit 2)
```

The documents:

- `list-<mode>`: the slow list on its own, as a child `dsc` runs it.
- `machine-<mode>`: laid out like `dsc/winfiles.machine.dsc.yaml`. There are three resources, and the middle one is an Include of the list. This is one level of Include, which is what `just install` runs.
- `nested-<mode>`: an Include of `machine-<mode>`. These are two levels, like a `set` of the whole `dsc/winfiles.dsc.yaml`.

Arguments after the document name go to `dsc` before `config set`, for example `-l info` or `--trace-format json`.

## Results

### DSC 3.3.0 (2026-10-29)

**Format.** A line holding a JSON object with one key, `{"error"|"warn"|"info"|"debug"|"trace":"..."}`, is logged at that level. Plain text, and JSON in any other shape, is logged at `trace` only. An `{"error":...}` line doesn't fail the resource. DSC's own `psscript.ps1` writes messages the same way.

**Timing.** Messages are live. DSC reads stderr line by line, and each message showed within about 15 ms of being written, long before the resource finished. The resource has to flush after each line.

**Levels.**
- **The default, `warn`,** shows only `warn` and `error` lines, and nothing from DSC itself.
- **`-l info`** (or `DSC_TRACE_LEVEL=info`) adds `info` lines, plus DSC's own. Those are about 4 per child `dsc` process (an Include runs one for each of validate, get and set) and "Invoking set ..." lines. `machine-info` gave 38 stderr lines for 5 items.
- **`debug` and `trace`** are far noisier: a 3-item `set` gave hundreds of lines.

**Include.** Microsoft.DSC/Include runs `dsc --trace-format pass-through config --as-include --as-group set ...`. It passes no `--trace-level`; the child takes the level from `DSC_TRACE_LEVEL`.
- **One level:** messages arrive live, at their own level, wrapped as `trace_message="PID <dsc>: PID <pwsh>: ..."`.
- **Two levels:** every message below `trace` is lost. The middle `dsc` passes it up under the field `trace_message`. DSC's parser (`log_stderr_line` in `dsc-lib/src/dscresources/command_resource.rs`) expects `message`, so the top level treats the line as plain text and logs it at `trace`. A resource can't work around this.

**Writing from a pwsh resource.** Only `[Console]::Error.WriteLine(<json>)`, followed by a flush, works.
- `Write-Host`, `Write-Information` and `Write-Warning` go to stdout. The result is no longer JSON, and DSC fails with "JSON: expected value at line 1 column 1" (exit 2).
- `Write-Progress` is dropped.

**Progress bar.** Messages don't move DSC's progress bar. `--progress-format json` only reports DSC's own top-level steps, and a resource can't add to it.

**For `just install`:**
- **`warn`** works with no new flags and no noise, but labels every item `WARN`.
- **`info`** is labelled honestly, but needs `-l info` on the `set`, which brings DSC's own lines with it.
- **Either way,** messages vanish in a `set` of the whole composition, the two-level case.

### When rerunning on a new DSC

Things to check:
- the two-level case (`nested-warn`): has the `trace_message` mismatch been fixed?
- whether the `PID ...:` prefixes have changed;
- how much `-l info` adds;
- whether `--progress-format` gained a way for resources to report.

Add a section with the version and date rather than editing the one above.
