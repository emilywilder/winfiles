# PowerShell style

winfiles' PowerShell follows the PoshCode style guide ([PowerShell Practice and Style](https://github.com/PoshCode/PowerShellPracticeAndStyle), its Style-Guide and Best-Practices), adopted 2026-11-21. `winfiles.ps1 lint` checks what PSScriptAnalyzer can (`scripts/Invoke-Lint.ps1`, with the rules in `PSScriptAnalyzerSettings.psd1`), and `tests/scripts/Invoke-Lint.Tests.ps1` fails when the repo has a finding. The conventions in `CLAUDE.md` say how the guide applies here; this file has what the checks cover and where winfiles differs from the guide on purpose.

## What's checked

- **Layout,** for every PowerShell file, tests included: One True Brace Style (`} else {`), four-space indents, the guide's spacing, no semicolons ending a line, no aliases, cmdlet and parameter casing, and lines of 115 characters at most (also in `.editorconfig`). `Invoke-Formatter` with the same settings lays a file out as the check wants. It leaves a continued expression at its statement's indent, so a long expression goes in parentheses, which it indents.
- **Everything else PSScriptAnalyzer has,** outside the tests: comment-based help on every function, `[CmdletBinding()]`, `SupportsShouldProcess` on what changes the system, positional parameters, approved verbs and singular nouns, `[OutputType()]`. A suppression (`[Diagnostics.CodeAnalysis.SuppressMessageAttribute()]`) gives its reason in `Justification`.
- **Not checked by a tool,** and kept by hand: named parameters on every call outside the tests (PSScriptAnalyzer only flags three or more positional arguments), no `return`, `.PARAMETER` replaced by a comment above each parameter, and the error handling in `CLAUDE.md` (Script conventions, "Errors").

Trade-off: PSScriptAnalyzer 1.25.0's `PSUseCorrectCasing` sometimes fails when it runs with the other rules, so `Invoke-Lint.ps1` runs it in a call of its own, and starts a new process if a file still fails ([the script's help](../../scripts/Invoke-Lint.ps1) has the details). Revisit when a PSScriptAnalyzer release fixes it.

## The tests

Test files (`tests/`, and the surveys' `*.Tests.ps1`) get only the layout rules. Their helpers keep positional parameters and need no help or `[CmdletBinding()]`, since they're called a few lines from where they're defined. Trade-off: the tests read differently from the code they test. Revisit if a test helper grows into something other files call.

## Where winfiles differs from the guide

- **Write-Host for the console.** The guide keeps Write-Host to Show/Format commands. Here the console gets only what the person needs, through Write-Host, and stdout stays free for what's parsed, such as `Find-RestartResource.ps1`'s `winfiles-restart:` lines ([run/output.md](../run/output.md)). PSAvoidUsingWriteHost is excluded.
- **No `param()` on the scripts that pass a command through:** `Invoke-AsAdmin.ps1`, `Invoke-AsUser.ps1`, `Invoke-Clean.ps1`, `Start-Winfiles.ps1`, `Invoke-Dsc.ps1` and `winfiles.ps1` read `$args`, as does `demos/dsc-messages/Invoke-DscMessage.ps1`, since a `param()` block matches a command's own dash arguments to PowerShell's common parameters ([reference](../reference/windows.md#a-param-block-on-the-privilege-helpers)).
- **`Invoke-Clean.ps1` checks its version in code** rather than with `#Requires`, since a `-Command` line carries on past a failed `#Requires` ([run/clean-environment.md](../run/clean-environment.md)).
- **`Start-Winfiles.ps1` runs under Windows PowerShell 5.1,** and so does `miseignore.ps1`, which it dot-sources, so they keep to 5.1 syntax and pass no double quotes inside arguments.
- **Dot-sourced files have a plain comment at the top,** not comment-based help: they're libraries, not commands. Their functions have help.
- **Paths in `.EXAMPLE`s and commands are relative to the repo root,** where `winfiles.ps1` runs every command, rather than built from `$PSScriptRoot`. Inside the scripts, paths come from `$PSScriptRoot`. The exception is `demos/` and `surveys/`, whose `.EXAMPLE`s run from their own folder, since they aren't winfiles commands ([demos-and-surveys.md](demos-and-surveys.md)).
- **JSON has no line limit** (`.editorconfig`): a resource manifest's descriptions are strings, which JSON can't split.
- **LF line endings** in every file but the `.cmd` ones, which are CRLF ([reference](../reference/windows.md#cmdexe-and-lf-line-endings)). `.gitattributes` sets this for a checkout whatever `core.autocrlf` says, and `.editorconfig` for editors. Git normalises what's committed, not a file as a command writes it: `Set-Content` ends what it writes with CRLF. `git ls-files --eol` shows each file's endings.
- **Resources report errors as JSON lines on stderr,** through their trap, rather than leave them to `throw`: DSC shows neither a resource's plain stderr nor, when it fails, anything but the exit code ([config/resources.md](../config/resources.md)).
