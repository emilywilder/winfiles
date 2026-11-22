#Requires -Version 7.4

<#
.SYNOPSIS
Implements Test/SlowList (see slowlist.dsc.resource.json), a stand-in for the slow list resources.

.DESCRIPTION
DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
set waits `delay` seconds per item and reports it according to `mode`:
  quiet      nothing
  warn/info  one {"<level>":"..."} line on stderr, which DSC logs at that level
  levels     one line at each level (error, warn, info, debug, trace) plus a plain-text line
  env        an info line that includes DSC_TRACE_LEVEL, to see what a child dsc passes down
  writehost, writeinfo, writewarn, progress
             PowerShell's own output cmdlets, which don't work for resources: the first three go to
             stdout and break the JSON result, and Write-Progress is dropped

.EXAMPLE
'{"items":["a","b"],"mode":"warn","delay":1}' | ./slowlist.ps1 set

Reports each item as a warning, a second apart, from demos/dsc-messages.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'The writehost mode shows what Write-Host does to a resource')]
[CmdletBinding()]
param(
    # The DSC operation.
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('get', 'test', 'set')]
    [string]$Operation,

    # A line of the instance's JSON, from DSC on stdin.
    [Parameter(ValueFromPipeline)]
    [AllowEmptyString()]
    [string]$InputObject
)

begin {
    $lines = [Collections.Generic.List[string]]::new()
}

process {
    if ($InputObject) {
        $lines.Add($InputObject)
    }
}

end {
    $ErrorActionPreference = 'Stop'
    try {
        $desired = $lines -join "`n" | ConvertFrom-Json
        $items = @($desired.items)
        $mode = if ($desired.mode) { $desired.mode } else { 'quiet' }
        $delay = if ($null -ne $desired.delay) { [int]$desired.delay } else { 2 }


        function Write-Message {
            <#
            .SYNOPSIS
            Writes a {"<level>":"..."} line on stderr, flushed, since DSC reads stderr line by line.
            #>
            [CmdletBinding()]
            param(
                # The level.
                [Parameter(Mandatory, Position = 0)]
                [string]$Level,

                # The message.
                [Parameter(Mandatory, Position = 1)]
                [string]$Text
            )

            [Console]::Error.WriteLine((ConvertTo-Json -InputObject @{ $Level = $Text } -Compress))
            [Console]::Error.Flush()
        }


        if ($Operation -eq 'set') {
            $i = 0
            foreach ($item in $items) {
                $i++
                Start-Sleep -Seconds $delay
                # The script's own clock, to compare with DSC's timestamp: they should be milliseconds apart
                $text = "[$((Get-Date).ToString('HH:mm:ss.fff'))] item $i/$($items.Count) '$item'"
                switch ($mode) {
                    'warn' { Write-Message -Level warn -Text $text }
                    'info' { Write-Message -Level info -Text $text }
                    'levels' {
                        foreach ($level in 'error', 'warn', 'info', 'debug', 'trace') {
                            Write-Message -Level $level -Text "$level $text"
                        }
                        [Console]::Error.WriteLine("plain $text")
                        [Console]::Error.Flush()
                    }
                    'env' { Write-Message -Level info -Text "$text DSC_TRACE_LEVEL=$env:DSC_TRACE_LEVEL" }
                    'writehost' { Write-Host -Object "writehost $text" }
                    'writeinfo' { Write-Information -MessageData "writeinfo $text" -InformationAction Continue }
                    'writewarn' { Write-Warning -Message "writewarn $text" }
                    'progress' {
                        $percent = 100 * $i / $items.Count
                        Write-Progress -Activity 'SlowList' -Status $text -PercentComplete $percent
                    }
                }
            }
        }

        $state = [ordered]@{ items = $items; mode = $mode; delay = $delay }
        if ($Operation -eq 'test') {
            $state['_inDesiredState'] = $false
        }
        ConvertTo-Json -InputObject $state -Compress
    } catch {
        # Rethrown, so an error that only ends a statement still ends the script, with exit code 1
        $failure = $_
        throw $failure
    } finally {
        $ErrorActionPreference = 'Continue'
    }
    exit 0
}
