# The documents `just system` applies first (dsc/<host>.restart.dsc.yaml, see Set-System.ps1) are only YAML that lists
# Includes, which nothing else exercises without a VM or elevation. These checks are on the files themselves: that each
# host has one, that every file it includes exists, and that what it applies first is also in the system document,
# where `just check` tests it. They read the text, so no YAML module is needed.
BeforeDiscovery {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $hostCases = @(Get-ChildItem (Join-Path $repoRoot 'dsc') -File -Filter '*.system.dsc.yaml' |
        ForEach-Object { @{ HostName = $_.Name -replace '\.system\.dsc\.yaml$' } })
}

BeforeAll {
    $script:dsc = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path 'dsc'
    function Get-IncludedFile([string]$Document) {
        Select-String -Path $Document -Pattern '^\s*configurationFile:\s*(\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }
    }
}

Describe 'The per-host restart documents' {
    It '<HostName> has one beside its system document' -ForEach $hostCases {
        Join-Path $dsc "$HostName.restart.dsc.yaml" | Should -Exist
    }

    It '<HostName> includes only files that exist, relative to dsc/' -ForEach $hostCases {
        $files = @(Get-IncludedFile (Join-Path $dsc "$HostName.restart.dsc.yaml"))
        $files | Should -Not -BeNullOrEmpty
        foreach ($file in $files) { Join-Path $dsc $file | Should -Exist }
    }

    It '<HostName> applies the features, WSL and the computer name, which the system document includes too' -ForEach $hostCases {
        $restart = @(Get-IncludedFile (Join-Path $dsc "$HostName.restart.dsc.yaml"))
        $restart | Should -Contain "hosts/$HostName/features.dsc.yaml"
        $restart | Should -Contain 'modules/system/wsl-platform.dsc.yaml'
        $restart | Should -Contain "hosts/$HostName/computername.dsc.yaml"
        # Either the restart document itself, or (hosts not yet moved over) WSL and the name again. A resource name
        # can't appear twice in one flat copy, so a system document does only one of the two
        $system = @(Get-IncludedFile (Join-Path $dsc "$HostName.system.dsc.yaml"))
        if ($system -contains "$HostName.restart.dsc.yaml") {
            $system | Should -Not -Contain 'modules/system/wsl-platform.dsc.yaml'
            $system | Should -Not -Contain "hosts/$HostName/computername.dsc.yaml"
        } else {
            $system | Should -Contain 'modules/system/wsl-platform.dsc.yaml'
            $system | Should -Contain "hosts/$HostName/computername.dsc.yaml"
        }
    }

    It '<HostName> orders WSL after the features' -ForEach $hostCases {
        (Get-Content -Raw (Join-Path $dsc "$HostName.restart.dsc.yaml")) | Should -Match "resourceId\('Microsoft\.DSC/Include', 'Features'\)"
    }
}
