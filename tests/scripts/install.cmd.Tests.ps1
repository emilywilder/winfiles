# install.cmd for real, with mise and just from this machine, but only with a host that has no configuration: `just
# install` then stops in `require`, before UAC or any change. What it would install is just install's business.
# USERPROFILE points into TestDrive, so Invoke-Install.ps1's run.log lines don't land in the real one;
# Invoke-Clean.ps1 builds the run's own environment from Windows, so the run itself still gets the real profile.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\resources\Resource.ps1')
    $installCmd = Join-Path $repo 'install.cmd'
    $userProfile = Join-Path $TestDrive 'home'
}

Describe 'install.cmd' {
    It 'runs just install with its arguments from any folder, and passes its exit code back' {
        $result = Invoke-Child $TestDrive @{ USERPROFILE = $userProfile } { & $installCmd no-such-host }
        $result.ExitCode | Should -Be 1
        $result.Stderr | Should -Contain 'No configuration at dsc/no-such-host.system.dsc.yaml. These exist:'
        $result.Stdout | Should -Contain 'iris.system'
    }

    It 'leaves out the calling shell''s environment, as Invoke-Clean.ps1 does' {
        # A PATH with Windows PowerShell and no mise, like a terminal opened before the bootstrap installed mise
        $system32 = Join-Path $env:SystemRoot 'System32'
        $path = "$system32;$(Join-Path $system32 'WindowsPowerShell\v1.0')"
        $environment = @{ PATH = $path; USERPROFILE = $userProfile }
        $result = Invoke-Child $TestDrive $environment { & $installCmd no-such-host }
        $result.ExitCode | Should -Be 1
        $result.Stderr | Should -Contain 'No configuration at dsc/no-such-host.system.dsc.yaml. These exist:'
    }
}
