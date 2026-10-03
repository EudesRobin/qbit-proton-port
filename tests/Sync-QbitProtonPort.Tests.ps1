#Requires -Version 7.3
<#
.SYNOPSIS
    Pester 6 tests of Sync-QbitProtonPort.ps1, run by harness/Test-Unit.ps1.

.DESCRIPTION
    The script is dot-sourced: its functions are defined, its main block doesn't run. Every path it uses
    points into TestDrive, Proton VPN and the network adapter are mocked, and Write-Log is mocked so that
    nothing is written outside TestDrive. Log lines follow the format of docs/EXTERNAL-CONTRACTS.md, with
    timestamps relative to now, as the script compares them with the current time.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'The paths set in BeforeAll are read by the dot-sourced functions of the script.')]
param()

BeforeAll {
    $env:QBIT_PROTON_PORT_HOME = Join-Path $TestDrive 'data'
    . (Join-Path $PSScriptRoot '..' 'Sync-QbitProtonPort.ps1')
    $ProtonLogs = Join-Path $TestDrive 'proton'
    $QbitIni    = Join-Path $TestDrive 'qBittorrent.ini'
    $EnvFile    = Join-Path $TestDrive '.env'
    New-Item -ItemType Directory -Path $ProtonLogs, $DataDir -Force | Out-Null

    # A line of the Proton VPN client log, $Age seconds old.
    function Format-ProtonLine([int] $Age, [string] $Text) {
        $time = [datetime]::UtcNow.AddSeconds(-$Age).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
        "$time | INFO  | PROCESS.COMM | $Text | {""Caller"":""Test""}"
    }
    function Format-PortLine([int] $Age, [int] $Public, [int] $Private = $Public) {
        Format-ProtonLine $Age "Received PortForwarding Status 'SleepingUntilRefresh', Port pair $Public->$Private, expiring in 00:01:00"
    }
    function Set-ProtonLog([string[]] $Current, [string[]] $Previous = @()) {
        Set-Content (Join-Path $ProtonLogs 'client-logs.txt') $Current -Encoding utf8
        $old = Join-Path $ProtonLogs 'client-logs.1.txt'
        if ($Previous) { Set-Content $old $Previous -Encoding utf8 } elseif (Test-Path $old) { Remove-Item $old }
    }
}

AfterAll { Remove-Item env:QBIT_PROTON_PORT_HOME -ErrorAction Ignore }

Describe 'Dot-sourcing' {
    It 'defines the functions without running the script' {
        # The main block would create the .env file from the template in the data folder.
        Get-Command Set-IniListenPort -CommandType Function | Should -Not -BeNullOrEmpty
        Test-Path (Join-Path $DataDir '.env') | Should -BeFalse
    }
}

Describe 'Get-ProtonForwardedPort' {
    BeforeEach {
        Mock Write-Log {}
        Mock Get-Process { [pscustomobject]@{ Name = 'ProtonVPN.Client' } } -ParameterFilter { $Name -eq 'ProtonVPN.Client' }
        Mock Get-NetAdapter { [pscustomobject]@{ Name = 'ProtonVPN'; Status = 'Up' } }
    }

    It 'returns a port reported a few seconds ago' {
        Set-ProtonLog (Format-PortLine 5 45626)
        Get-ProtonForwardedPort -Interface 'ProtonVPN' | Should -Be 45626
    }

    It 'returns the latest port when several are reported' {
        Set-ProtonLog @((Format-PortLine 30 40000), (Format-PortLine 5 45626))
        Get-ProtonForwardedPort -Interface 'ProtonVPN' | Should -Be 45626
    }

    It 'reads the rotated log when the current one has no port yet' {
        Set-ProtonLog -Current (Format-ProtonLine 2 'Connected') -Previous (Format-PortLine 10 45626)
        Get-ProtonForwardedPort -Interface 'ProtonVPN' | Should -Be 45626
    }

    It 'refuses a port older than 90 seconds' {
        Set-ProtonLog (Format-PortLine 120 45626)
        { Get-ProtonForwardedPort -Interface 'ProtonVPN' } | Should -Throw '*last port report is*'
    }

    It 'refuses a port when the connection stopped after it' {
        Set-ProtonLog @((Format-PortLine 10 45626), (Format-ProtonLine 5 'Status updated to Disconnected'))
        { Get-ProtonForwardedPort -Interface 'ProtonVPN' } | Should -Throw '*stopped*'
    }

    It 'refuses a port when port forwarding stopped after it' {
        Set-ProtonLog @((Format-PortLine 10 45626), (Format-ProtonLine 5 "Port forwarding status changed from 'SleepingUntilRefresh' to 'Stopped'."))
        { Get-ProtonForwardedPort -Interface 'ProtonVPN' } | Should -Throw '*stopped*'
    }

    It 'refuses a log without any port' {
        Set-ProtonLog (Format-ProtonLine 5 'Connected')
        { Get-ProtonForwardedPort -Interface 'ProtonVPN' } | Should -Throw '*exposes no forwarded port*'
    }

    It 'refuses a port below 1024' {
        Set-ProtonLog (Format-PortLine 5 80)
        { Get-ProtonForwardedPort -Interface 'ProtonVPN' } | Should -Throw '*invalid port (80)*'
    }

    It 'uses the public port and warns when public and private ports differ' {
        Set-ProtonLog (Format-PortLine 5 45626 45627)
        Get-ProtonForwardedPort -Interface 'ProtonVPN' | Should -Be 45626
        Should -Invoke Write-Log -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*different ports*' }
    }

    It 'fails when Proton VPN is not running' {
        Mock Get-Process { } -ParameterFilter { $Name -eq 'ProtonVPN.Client' }
        Set-ProtonLog (Format-PortLine 5 45626)
        { Get-ProtonForwardedPort -Interface 'ProtonVPN' } | Should -Throw 'Proton VPN is not running.'
    }

    It 'fails when the VPN adapter is not up' {
        Mock Get-NetAdapter { [pscustomobject]@{ Name = 'ProtonVPN'; Status = 'Disconnected' } }
        Set-ProtonLog (Format-PortLine 5 45626)
        { Get-ProtonForwardedPort -Interface 'ProtonVPN' } | Should -Throw '*is not up*'
    }
}

Describe 'Set-IniListenPort' {
    BeforeEach {
        Mock Write-Log {}
        Remove-Item "$QbitIni*" -ErrorAction Ignore
    }

    It 'replaces the port of the [BitTorrent] section' {
        Set-Content $QbitIni "[BitTorrent]`r`nSession\Port=1000`r`nSession\Interface=ProtonVPN`r`n`r`n[Preferences]`r`nWebUI\Port=8080" -NoNewline
        Set-IniListenPort -Port 45626
        $text = Get-Content $QbitIni -Raw
        $text | Should -Match 'Session\\Port=45626'
        $text | Should -Not -Match 'Session\\Port=1000'
        $text | Should -Match 'WebUI\\Port=8080'
    }

    It 'adds the port at the end of [BitTorrent], not in the next section' {
        Set-Content $QbitIni "[BitTorrent]`r`nSession\Interface=ProtonVPN`r`n`r`n[Preferences]`r`nWebUI\Port=8080" -NoNewline
        Set-IniListenPort -Port 45626
        $lines = @(Get-Content $QbitIni)
        $lines.IndexOf('Session\Port=45626') | Should -Be 2
        $lines.IndexOf('Session\Port=45626') | Should -BeLessThan $lines.IndexOf('[Preferences]')
    }

    It 'adds the [BitTorrent] section when it is missing' {
        Set-Content $QbitIni "[Preferences]`r`nWebUI\Port=8080" -NoNewline
        Set-IniListenPort -Port 45626
        (Get-Content $QbitIni -Raw) | Should -Match '\[BitTorrent\]\r\nSession\\Port=45626'
    }

    It 'keeps the line endings of the file' {
        Set-Content $QbitIni "[BitTorrent]`nSession\Port=1000`nSession\Interface=ProtonVPN" -NoNewline
        Set-IniListenPort -Port 45626
        (Get-Content $QbitIni -Raw) | Should -Not -Match "`r"
    }

    It 'makes a backup once, and keeps the first one' {
        Set-Content $QbitIni "[BitTorrent]`r`nSession\Port=1000" -NoNewline
        Set-IniListenPort -Port 45626
        Set-IniListenPort -Port 45627
        (Get-Content "$QbitIni.bak" -Raw) | Should -Match 'Session\\Port=1000'
    }

    It 'warns when qBittorrent is not bound to an interface yet' {
        Set-Content $QbitIni "[BitTorrent]`r`nSession\Port=1000" -NoNewline
        Set-IniListenPort -Port 45626
        Should -Invoke Write-Log -ParameterFilter { $Level -eq 'WARN' -and $Message -like '*not bound to the VPN interface*' }
    }

    It 'fails when the settings file does not exist' {
        { Set-IniListenPort -Port 45626 } | Should -Throw 'qBittorrent settings not found*'
    }
}

Describe 'Read-EnvFile and Set-EnvValue' {
    BeforeEach { Remove-Item $EnvFile -ErrorAction Ignore }

    It 'reads settings, without quotes, comments or blank lines' {
        Set-Content $EnvFile "# comment`r`n`r`nQBIT_API_PORT=8080`r`nQBIT_PATH=""C:\Program Files\qBittorrent\qbittorrent.exe"""
        $settings = Read-EnvFile
        $settings['QBIT_API_PORT'] | Should -Be '8080'
        $settings['QBIT_PATH'] | Should -Be 'C:\Program Files\qBittorrent\qbittorrent.exe'
        $settings.Count | Should -Be 2
    }

    It 'creates the file from the template, then fails' {
        { Read-EnvFile } | Should -Throw 'Created * from the template*'
        Test-Path $EnvFile | Should -BeTrue
    }

    It 'updates an existing setting and adds a missing one' {
        Set-Content $EnvFile "QBIT_API_PORT=8080`r`nVPN_INTERFACE=ProtonVPN"
        Set-EnvValue -Name 'QBIT_API_PORT' -Value '9090'
        Set-EnvValue -Name 'QBIT_CERT_SHA256' -Value ('AB' * 4)
        $settings = Read-EnvFile
        $settings['QBIT_API_PORT'] | Should -Be '9090'
        $settings['VPN_INTERFACE'] | Should -Be 'ProtonVPN'
        $settings['QBIT_CERT_SHA256'] | Should -Be ('AB' * 4)
    }
}

Describe 'Get-Setting' {
    It 'fails on a missing or empty setting' {
        { Get-Setting -Settings @{ A = ' ' } -Name 'A' } | Should -Throw 'Setting A is missing or empty*'
        { Get-Setting -Settings @{} -Name 'B' } | Should -Throw 'Setting B is missing or empty*'
    }
}
