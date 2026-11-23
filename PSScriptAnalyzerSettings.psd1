# What `winfiles.ps1 lint` (scripts/Invoke-Lint.ps1) checks, and how Invoke-Formatter lays code out: the PoshCode
# style guide as far as PSScriptAnalyzer can check it. Where winfiles differs on purpose is in docs/dev/style.md.
@{
    IncludeDefaultRules = $true
    ExcludeRules        = @(
        # The console gets Write-Host, and stdout stays for what's parsed (docs/dev/style.md)
        'PSAvoidUsingWriteHost'
    )
    Rules               = @{
        # One True Brace Style: `} else {`, opening braces at the end of a line
        PSPlaceOpenBrace                          = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace                         = @{
            Enable             = $true
            NewLineAfter       = $false
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }
        PSUseConsistentIndentation                = @{
            Enable              = $true
            Kind                = 'space'
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }
        PSUseConsistentWhitespace                 = @{
            Enable                          = $true
            CheckInnerBrace                 = $true
            CheckOpenBrace                  = $true
            CheckOpenParen                  = $true
            CheckOperator                   = $true
            CheckPipe                       = $true
            CheckPipeForRedundantWhitespace = $true
            CheckSeparator                  = $true
            CheckParameter                  = $true
            IgnoreAssignmentOperatorInsideHashTable = $true
        }
        PSAlignAssignmentStatement                = @{
            Enable         = $true
            CheckHashtable = $true
        }
        PSAvoidSemicolonsAsLineTerminators        = @{ Enable = $true }
        PSAvoidLongLines                          = @{
            Enable            = $true
            MaximumLineLength = 115
        }
        PSUseCorrectCasing                        = @{ Enable = $true }
        PSAvoidUsingPositionalParameters          = @{
            Enable           = $true
            CommandAllowList = @()
        }
        PSProvideCommentHelp                      = @{
            Enable                  = $true
            ExportedOnly            = $false
            BlockComment            = $true
            VSCodeSnippetCorrection = $false
            Placement               = 'begin'
        }
    }
}
