# Implements Test/SlowList (see slowlist.dsc.resource.json), a stand-in for the slow list resources.
# DSC pipes the instance as JSON on stdin; the operation is the first argument. Only JSON goes to stdout.
# set waits `delay` seconds per item and reports it according to `mode`:
#   quiet      nothing (how the list resources behave today)
#   warn/info  one {"<level>":"..."} line on stderr, which DSC logs at that level
#   levels     one line at each level (error, warn, info, debug, trace) plus a plain-text line
#   env        an info line that includes DSC_TRACE_LEVEL, to see what a child dsc passes down
#   writehost, writeinfo, writewarn, progress
#              PowerShell's own output cmdlets, which don't work for resources: the first three go to
#              stdout and break the JSON result, and Write-Progress is dropped
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('get', 'test', 'set')]
    [string]$Operation,

    [Parameter(ValueFromPipeline)]
    [string]$InputJson
)

begin {
    $ErrorActionPreference = 'Stop'
    $lines = [System.Collections.Generic.List[string]]::new()
}

process {
    if ($InputJson) { $lines.Add($InputJson) }
}

end {
    $desired = $lines -join "`n" | ConvertFrom-Json
    $items = @($desired.items)
    $mode = if ($desired.mode) { $desired.mode } else { 'quiet' }
    $delay = if ($null -ne $desired.delay) { [int]$desired.delay } else { 2 }

    # DSC reads stderr line by line; flush so each line goes out when it's written
    function Write-Message([string]$Level, [string]$Text) {
        [Console]::Error.WriteLine((@{ $Level = $Text } | ConvertTo-Json -Compress))
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
                'warn' { Write-Message warn $text }
                'info' { Write-Message info $text }
                'levels' {
                    foreach ($level in 'error', 'warn', 'info', 'debug', 'trace') { Write-Message $level "$level $text" }
                    [Console]::Error.WriteLine("plain $text")
                    [Console]::Error.Flush()
                }
                'env' { Write-Message info "$text DSC_TRACE_LEVEL=$env:DSC_TRACE_LEVEL" }
                'writehost' { Write-Host "writehost $text" }
                'writeinfo' { Write-Information "writeinfo $text" -InformationAction Continue }
                'writewarn' { Write-Warning "writewarn $text" }
                'progress' { Write-Progress -Activity 'SlowList' -Status $text -PercentComplete (100 * $i / $items.Count) }
            }
        }
    }

    $state = [ordered]@{ items = $items; mode = $mode; delay = $delay }
    if ($Operation -eq 'test') { $state['_inDesiredState'] = $false }
    $state | ConvertTo-Json -Compress
    exit 0
}
