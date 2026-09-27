#Requires -Version 7.3
<#
.SYNOPSIS
    Sync the Proton VPN forwarded port into qBittorrent's listening port, then launch qBittorrent if needed.

.DESCRIPTION
    Reads the port currently forwarded by Proton VPN from its client log, then:
      - qBittorrent not running: writes the port to qBittorrent.ini and launches it in the background;
      - qBittorrent running: checks the listening port through the WebUI API and fixes it live.
    The network interface is also bound to the VPN adapter, so traffic stops if the VPN drops.
    Fails (exit 1) without launching anything if Proton VPN is not connected or exposes no port.

    The WebUI API is reached over HTTPS on 127.0.0.1 with a pinned self-signed certificate,
    and authenticated with an API key stored DPAPI-encrypted in secret.xml.
    Settings (.env), secret.xml and logs live in %LOCALAPPDATA%\qbit-proton-port
    (override with the QBIT_PROTON_PORT_HOME environment variable).

.EXAMPLE
    ./Sync-QbitProtonPort.ps1                  # sync, launch qBittorrent if needed
    ./Sync-QbitProtonPort.ps1 -SyncOnly        # sync only if qBittorrent runs (scheduled task)
    ./Sync-QbitProtonPort.ps1 -NewCertificate  # create/renew the WebUI HTTPS certificate
    ./Sync-QbitProtonPort.ps1 -ResetCredential # store a new API key
    ./Sync-QbitProtonPort.ps1 -RegisterTask    # re-sync every 5 minutes while logged on
    ./Sync-QbitProtonPort.ps1 -ShowConfig      # show where settings, key and logs are stored
#>
[CmdletBinding(DefaultParameterSetName = 'Sync')]
param(
    [Parameter(ParameterSetName = 'Sync')] [switch] $SyncOnly,
    [Parameter(ParameterSetName = 'Sync')] [switch] $PauseOnError,
    [Parameter(ParameterSetName = 'NewCertificate', Mandatory)] [switch] $NewCertificate,
    [Parameter(ParameterSetName = 'ResetCredential', Mandatory)] [switch] $ResetCredential,
    [Parameter(ParameterSetName = 'RegisterTask', Mandatory)] [switch] $RegisterTask,
    [Parameter(ParameterSetName = 'UnregisterTask', Mandatory)] [switch] $UnregisterTask,
    [Parameter(ParameterSetName = 'ShowConfig', Mandatory)] [switch] $ShowConfig
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root        = $PSScriptRoot
# Settings, API key and logs live outside the repository, in a per-user, non-roaming folder.
$DataDir     = if ($env:QBIT_PROTON_PORT_HOME) { $env:QBIT_PROTON_PORT_HOME } else { Join-Path $env:LOCALAPPDATA 'qbit-proton-port' }
$EnvFile     = Join-Path $DataDir '.env'
$SecretFile  = Join-Path $DataDir 'secret.xml'
$LogDir      = Join-Path $DataDir 'logs'
$LogFile     = Join-Path $LogDir 'sync.log'
$QbitIni     = Join-Path $env:APPDATA 'qBittorrent\qBittorrent.ini'
$SslDir      = Join-Path $env:APPDATA 'qBittorrent\ssl'
$ProtonLogs  = Join-Path $env:LOCALAPPDATA 'Proton\Proton VPN\Logs'
$TaskName    = 'Sync qBittorrent port with Proton VPN'
$MaxPortAge  = [TimeSpan]::FromSeconds(90)   # Proton logs the port every ~10 s
$CertWarnAge = [TimeSpan]::FromDays(30)

# --- Logging -----------------------------------------------------------------

function Write-Log {
    param([ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level, [string] $Message)
    $line = '{0} {1,-5} {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red' }[$Level]
    Write-Host $line -ForegroundColor $color
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
        Move-Item $LogFile "$LogFile.1" -Force
    }
    Add-Content -Path $LogFile -Value $line -Encoding utf8
}

# --- Settings (.env) ---------------------------------------------------------

function Read-EnvFile {
    if (-not (Test-Path $EnvFile)) {
        Copy-Item (Join-Path $Root '.env.example') $EnvFile
        throw "Created $EnvFile from the template: set QBIT_API_PORT in it, then run -NewCertificate (see README)."
    }
    $settings = @{}
    foreach ($line in Get-Content $EnvFile -Encoding utf8) {
        if ($line -match '^\s*(#|$)') { continue }
        if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$') { $settings[$Matches[1]] = $Matches[2].Trim('"') }
    }
    return $settings
}

function Get-Setting {
    param([hashtable] $Settings, [string] $Name)
    if (-not $Settings.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace($Settings[$Name])) {
        throw "Setting $Name is missing or empty in $EnvFile."
    }
    return $Settings[$Name]
}

function Set-EnvValue {
    param([string] $Name, [string] $Value)
    if (-not (Test-Path $EnvFile)) { Copy-Item (Join-Path $Root '.env.example') $EnvFile }
    $lines = @(Get-Content $EnvFile -Encoding utf8)
    $found = $false
    $lines = foreach ($line in $lines) {
        if ($line -match "^\s*$Name\s*=") { $found = $true; "$Name=$Value" } else { $line }
    }
    if (-not $found) { $lines += "$Name=$Value" }
    Set-Content -Path $EnvFile -Value $lines -Encoding utf8NoBOM
}

# --- API key (DPAPI) ---------------------------------------------------------

function Save-ApiKey {
    $secure = Read-Host -Prompt 'qBittorrent WebUI API key' -AsSecureString
    if ($secure.Length -eq 0) { throw 'Empty API key, nothing saved.' }
    # Export-Clixml encrypts a SecureString with DPAPI: only this user on this machine can read it.
    $secure | Export-Clixml -Path $SecretFile
    Write-Log INFO "API key saved (DPAPI-encrypted) to $SecretFile."
}

function Get-ApiKey {
    param([bool] $CanPrompt)
    if (-not (Test-Path $SecretFile)) {
        if (-not $CanPrompt) { throw "API key not stored yet ($SecretFile). Run the script once interactively to store it." }
        Save-ApiKey
    }
    try {
        return (Import-Clixml -Path $SecretFile) | ConvertFrom-SecureString -AsPlainText
    } catch {
        throw "Cannot decrypt $SecretFile (other user or machine?). Run with -ResetCredential."
    }
}

# --- Proton VPN forwarded port -----------------------------------------------

function Read-SharedFile {
    param([string] $Path)
    if (-not (Test-Path $Path)) { return '' }
    # The client keeps the log open: read it with full sharing. Its reported size is often stale.
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
    try { return ([IO.StreamReader]::new($stream)).ReadToEnd() } finally { $stream.Dispose() }
}

function Get-LogTime {
    param([string] $Line)
    return [datetime]::Parse($Line.Substring(0, $Line.IndexOf(' ')), $null, 'RoundtripKind').ToUniversalTime()
}

function Get-ProtonForwardedPort {
    param([string] $Interface)

    if (-not (Get-Process -Name 'ProtonVPN.Client' -ErrorAction SilentlyContinue)) {
        throw 'Proton VPN is not running.'
    }
    $adapter = Get-NetAdapter -Name $Interface -ErrorAction SilentlyContinue
    if (-not $adapter -or $adapter.Status -ne 'Up') {
        throw "Proton VPN is not connected (adapter '$Interface' is not up)."
    }

    # The log rotates to client-logs.1.txt: read the previous file first, then the current one.
    $text  = (Read-SharedFile (Join-Path $ProtonLogs 'client-logs.1.txt')) + "`n" +
             (Read-SharedFile (Join-Path $ProtonLogs 'client-logs.txt'))
    $lines = $text -split "`r?`n" | Where-Object { $_ -match '^\d{4}-\d\d-\d\dT' }

    $portLine = $lines | Where-Object { $_ -match 'Port pair \d+->\d+' } | Select-Object -Last 1
    if (-not $portLine) { throw 'Proton VPN exposes no forwarded port (is port forwarding enabled in its settings?).' }

    $portTime = Get-LogTime $portLine
    $age = [datetime]::UtcNow - $portTime
    if ($age -gt $MaxPortAge) {
        throw ('Proton VPN exposes no forwarded port: last port report is {0:N0} s old.' -f $age.TotalSeconds)
    }
    $stopLine = $lines | Where-Object {
        $_ -match "Status updated to Disconnected|Port forwarding status changed from '[^']+' to 'Stopped'"
    } | Select-Object -Last 1
    if ($stopLine -and (Get-LogTime $stopLine) -gt $portTime) {
        throw 'Proton VPN exposes no forwarded port: the connection or port forwarding stopped.'
    }

    $null = $portLine -match 'Port pair (\d+)->(\d+)'
    $public, $private = [int]$Matches[1], [int]$Matches[2]
    if ($public -lt 1024 -or $public -gt 65535) { throw "Proton VPN log reports an invalid port ($public)." }
    if ($public -ne $private) { Write-Log WARN "Proton reports different ports ($public->$private); using $public." }
    return $public
}

# --- WebUI API over pinned HTTPS ---------------------------------------------

if (-not ('QbitPinnedHttp' -as [type])) {
    # Compiled in C#: a PowerShell script block used as a TLS callback has no runspace on network threads.
    Add-Type -TypeDefinition @'
using System;
using System.Net.Http;
using System.Security.Cryptography;

public static class QbitPinnedHttp
{
    public static string LastSeenSha256;
    public static DateTime LastNotAfter;

    public static HttpClient Create(string pinnedSha256)
    {
        string pin = pinnedSha256.Replace(":", "").Trim();
        var handler = new HttpClientHandler { UseCookies = false, UseProxy = false };
        handler.ServerCertificateCustomValidationCallback = (message, cert, chain, errors) =>
        {
            if (cert == null) return false;
            LastSeenSha256 = Convert.ToHexString(SHA256.HashData(cert.RawData));
            LastNotAfter = cert.NotAfter;
            // Only the pinned certificate is trusted; chain and name errors are expected for a self-signed one.
            return string.Equals(LastSeenSha256, pin, StringComparison.OrdinalIgnoreCase);
        };
        return new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(10) };
    }
}
'@
}

$script:Api = $null

function Initialize-QbitApi {
    param([int] $Port, [string] $PinnedSha256, [string] $ApiKey)
    $script:Api = [pscustomobject]@{
        Base   = "https://127.0.0.1:$Port/api/v2"
        Port   = $Port
        Pin    = $PinnedSha256
        Key    = $ApiKey
        Client = [QbitPinnedHttp]::Create($PinnedSha256)
    }
}

function Test-ExceptionChain {
    param([Exception] $Exception, [type] $Type)
    for ($e = $Exception; $e; $e = $e.InnerException) { if ($e -is $Type) { return $true } }
    return $false
}

function Get-WebUiDiagnostic {
    $ini = if (Test-Path $QbitIni) { Get-Content $QbitIni -Encoding utf8 } else { @() }
    $enabled = ($ini | Where-Object { $_ -match '^WebUI\\Enabled=' }) -replace '^.*=', ''
    $port    = ($ini | Where-Object { $_ -match '^WebUI\\Port=' }) -replace '^.*=', ''
    if ($enabled -ne 'true') { return 'the WebUI is disabled in qBittorrent (Options > Web UI).' }
    if ($port -and [int]$port -ne $script:Api.Port) {
        return "qBittorrent's WebUI port is $port but QBIT_API_PORT is $($script:Api.Port)."
    }
    return "nothing listens on 127.0.0.1:$($script:Api.Port) (qBittorrent still starting, or WebUI address not 127.0.0.1)."
}

function Invoke-QbitApi {
    param([string] $Path, [hashtable] $Form)

    $method = if ($Form) { [Net.Http.HttpMethod]::Post } else { [Net.Http.HttpMethod]::Get }
    $request = [Net.Http.HttpRequestMessage]::new($method, "$($script:Api.Base)$Path")
    $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $script:Api.Key)
    if ($Form) {
        $pairs = [Collections.Generic.List[Collections.Generic.KeyValuePair[string, string]]]::new()
        foreach ($k in $Form.Keys) { $pairs.Add([Collections.Generic.KeyValuePair[string, string]]::new($k, $Form[$k])) }
        $request.Content = [Net.Http.FormUrlEncodedContent]::new($pairs)
    }

    [QbitPinnedHttp]::LastSeenSha256 = $null
    try {
        $response = $script:Api.Client.SendAsync($request).GetAwaiter().GetResult()
    } catch {
        $ex = $_.Exception
        $seen = [QbitPinnedHttp]::LastSeenSha256
        if ($seen -and $seen -ne ($script:Api.Pin -replace ':', '')) {
            throw "qBittorrent's certificate ($seen) doesn't match QBIT_CERT_SHA256. The API key was not sent."
        }
        if (Test-ExceptionChain $ex ([Net.Sockets.SocketException])) {
            throw "qBittorrent WebUI API unreachable: $(Get-WebUiDiagnostic)"
        }
        if ((Test-ExceptionChain $ex ([Security.Authentication.AuthenticationException])) -or
            (Test-ExceptionChain $ex ([IO.IOException]))) {
            throw 'TLS handshake failed: HTTPS is probably not enabled in qBittorrent (Options > Web UI > Use HTTPS). See README.'
        }
        if ((Test-ExceptionChain $ex ([TimeoutException])) -or $ex -is [Threading.Tasks.TaskCanceledException]) {
            throw 'qBittorrent WebUI API timed out.'
        }
        throw
    } finally {
        $request.Dispose()
    }

    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $status = [int]$response.StatusCode
    if ($status -in 401, 403) { throw 'qBittorrent rejected the API key. Run with -ResetCredential.' }
    if ($status -ge 400) { throw "qBittorrent API $Path returned HTTP $status." }

    $remaining = [QbitPinnedHttp]::LastNotAfter.ToUniversalTime() - [datetime]::UtcNow
    if ([QbitPinnedHttp]::LastSeenSha256 -and $remaining -lt $CertWarnAge) {
        Write-Log WARN ('WebUI certificate expires in {0:N0} days. Run with -NewCertificate.' -f $remaining.TotalDays)
    }
    if ($body -match '^\s*[\[{]') { return $body | ConvertFrom-Json }
    return $body
}

function Wait-QbitApi {
    param([int] $TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        try { return Invoke-QbitApi '/app/version' }
        catch {
            if ((Get-Date) -gt $deadline -or $_.Exception.Message -notmatch 'unreachable') { throw }
            Start-Sleep -Milliseconds 500
        }
    }
}

# --- qBittorrent ---------------------------------------------------------------

function Set-IniListenPort {
    param([int] $Port)
    if (-not (Test-Path $QbitIni)) { throw "qBittorrent settings not found: $QbitIni" }
    $backup = "$QbitIni.bak"
    if (-not (Test-Path $backup)) { Copy-Item $QbitIni $backup }

    $raw = [IO.File]::ReadAllText($QbitIni)
    $eol = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [Collections.Generic.List[string]]($raw -split "`r?`n")

    $section = ''; $sectionEnd = -1; $done = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\[(.+)\]$') { $section = $Matches[1]; continue }
        if ($section -ne 'BitTorrent') { continue }
        if ($lines[$i] -match '^Session\\Port=') { $lines[$i] = "Session\Port=$Port"; $done = $true; break }
        if ($lines[$i] -ne '') { $sectionEnd = $i }
    }
    if (-not $done) {
        if ($sectionEnd -lt 0) { $lines.Add('[BitTorrent]'); $lines.Add("Session\Port=$Port") }
        else { $lines.Insert($sectionEnd + 1, "Session\Port=$Port") }
    }
    [IO.File]::WriteAllText($QbitIni, ($lines -join $eol), [Text.UTF8Encoding]::new($false))
    Write-Log INFO "qBittorrent.ini: listening port set to $Port."
    if (-not ($lines | Where-Object { $_ -match '^Session\\Interface=.+' })) {
        # The binding is applied through the API right after launch, then persisted by qBittorrent.
        Write-Log WARN 'qBittorrent is not bound to the VPN interface yet: it may use all interfaces for a few seconds.'
    }
}

function Sync-QbitSettings {
    param([int] $Port, [string] $Interface)

    $prefs = Invoke-QbitApi '/app/preferences'
    $changes = [ordered]@{}

    if ([int]$prefs.listen_port -ne $Port) {
        Write-Log INFO "Listening port is $($prefs.listen_port), expected $Port."
        $changes.listen_port = $Port
    }

    $iface = Invoke-QbitApi '/app/networkInterfaceList' | Where-Object name -EQ $Interface | Select-Object -First 1
    if (-not $iface) { throw "qBittorrent doesn't see a network interface named '$Interface'." }
    if ($prefs.current_network_interface -ne $iface.value) {
        Write-Log INFO "Network interface is '$($prefs.current_interface_name)', expected '$Interface'."
        $changes.current_network_interface = $iface.value
        $changes.current_interface_address = ''   # all addresses of the VPN interface
    }

    if ($changes.Count -eq 0) {
        Write-Log INFO "qBittorrent already in sync: port $Port on '$Interface'."
        return
    }

    $null = Invoke-QbitApi '/app/setPreferences' @{ json = ($changes | ConvertTo-Json -Compress) }
    $after = Invoke-QbitApi '/app/preferences'
    if ([int]$after.listen_port -ne $Port -or $after.current_network_interface -ne $iface.value) {
        throw "qBittorrent did not apply the settings (port $($after.listen_port), interface '$($after.current_interface_name)')."
    }
    Write-Log INFO "qBittorrent updated: port $Port on '$Interface'."
}

# --- Certificate ---------------------------------------------------------------

function New-WebUiCertificate {
    $cert = New-SelfSignedCertificate -Subject 'CN=qBittorrent WebUI (127.0.0.1)' `
        -TextExtension @('2.5.29.17={text}IPAddress=127.0.0.1&DNS=localhost', '2.5.29.37={text}1.3.6.1.5.5.7.3.1') `
        -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeyExportPolicy Exportable `
        -KeyUsage DigitalSignature, KeyEncipherment -NotAfter (Get-Date).AddYears(2) `
        -CertStoreLocation 'Cert:\CurrentUser\My'
    try {
        $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
        try {
            $keyPem = $rsa.ExportRSAPrivateKeyPem()
        } catch {
            # CNG may only allow encrypted export: round-trip through an encrypted PKCS#8 blob.
            $pw = [Guid]::NewGuid().ToString()
            $pbe = [Security.Cryptography.PbeParameters]::new('Aes256Cbc', 'SHA256', 100000)
            $blob = $rsa.ExportEncryptedPkcs8PrivateKey($pw, $pbe)
            $plain = [Security.Cryptography.RSA]::Create()
            $read = 0
            $plain.ImportEncryptedPkcs8PrivateKey($pw, $blob, [ref]$read)
            $keyPem = $plain.ExportRSAPrivateKeyPem()
        }

        if (-not (Test-Path $SslDir)) { New-Item -ItemType Directory -Path $SslDir | Out-Null }
        $user = "$env:USERDOMAIN\$env:USERNAME"
        # Only this user (and SYSTEM) may read the private key; SID *S-1-5-18 avoids localized names.
        $null = icacls $SslDir /inheritance:r /grant:r "${user}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F'
        if ($LASTEXITCODE -ne 0) { throw "Cannot restrict permissions on $SslDir; private key not written." }
        $certPath = Join-Path $SslDir 'webui.crt'
        $keyPath  = Join-Path $SslDir 'webui.key'
        Set-Content -Path $certPath -Value $cert.ExportCertificatePem() -Encoding ascii
        Set-Content -Path $keyPath -Value $keyPem -Encoding ascii
        $sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($cert.RawData))
        Set-EnvValue 'QBIT_CERT_SHA256' $sha256
    } finally {
        Remove-Item -Path "Cert:\CurrentUser\My\$($cert.Thumbprint)" -DeleteKey -ErrorAction SilentlyContinue
    }

    Write-Log INFO "Certificate valid until $($cert.NotAfter.ToString('yyyy-MM-dd')), SHA-256 $sha256 (saved to .env)."
    Write-Host @"

Now in qBittorrent: Options > Web UI > check "Use HTTPS instead of HTTP", then set
  Certificate: $certPath
  Key:         $keyPath
and click Apply. The change is live; this script then talks HTTPS only.
"@
}

# --- Scheduled task --------------------------------------------------------------

function Register-SyncTask {
    $pwsh = (Get-Process -Id $PID).Path
    $script = Join-Path $Root 'Sync-QbitProtonPort.ps1'
    # No -ExecutionPolicy Bypass: the task honours the machine policy (RemoteSigned by default).
    $arguments = "--headless `"$pwsh`" -NoProfile -File `"$script`" -SyncOnly"
    $action = New-ScheduledTaskAction -Execute 'conhost.exe' -Argument $arguments -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Keeps qBittorrent listening port equal to the Proton VPN forwarded port.' -Force | Out-Null
    Write-Log INFO "Scheduled task '$TaskName' registered (every 5 min while logged on)."
}

# --- Main --------------------------------------------------------------------------

try {
    if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
    switch ($PSCmdlet.ParameterSetName) {
        'ShowConfig' {
            [pscustomobject]@{
                Settings    = $EnvFile
                ApiKey      = "$SecretFile$(if (-not (Test-Path $SecretFile)) { ' (not stored yet)' })"
                Log         = $LogFile
                Certificate = $SslDir
                Task        = if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) { 'registered' } else { 'not registered' }
            } | Format-List | Out-Host
            exit 0
        }
        'NewCertificate'  { New-WebUiCertificate; exit 0 }
        'ResetCredential' { Save-ApiKey; exit 0 }
        'RegisterTask'    { Register-SyncTask; exit 0 }
        'UnregisterTask'  {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            Write-Log INFO "Scheduled task '$TaskName' removed."
            exit 0
        }
    }

    $settings  = Read-EnvFile
    $apiPort   = Get-Setting $settings 'QBIT_API_PORT'
    $pin       = Get-Setting $settings 'QBIT_CERT_SHA256'
    if ($apiPort -notmatch '^\d{1,5}$' -or [int]$apiPort -lt 1 -or [int]$apiPort -gt 65535) {
        throw "QBIT_API_PORT must be a port number between 1 and 65535, not '$apiPort'."
    }
    # Checked here, or a typo would only surface later as a misleading certificate mismatch.
    if (($pin -replace ':', '') -notmatch '^[0-9A-Fa-f]{64}$') {
        throw 'QBIT_CERT_SHA256 must be a SHA-256 fingerprint of 64 hexadecimal characters.'
    }
    $qbitPath  = Get-Setting $settings 'QBIT_PATH'
    $interface = Get-Setting $settings 'VPN_INTERFACE'

    $running = [bool](Get-Process -Name 'qbittorrent' -ErrorAction SilentlyContinue)
    if ($SyncOnly -and -not $running) { exit 0 }   # nothing to sync; stay quiet for the scheduled task

    $port = Get-ProtonForwardedPort -Interface $interface
    Write-Log INFO "Proton VPN forwarded port: $port."

    Initialize-QbitApi -Port $apiPort -PinnedSha256 $pin -ApiKey (Get-ApiKey -CanPrompt (-not $SyncOnly))

    if (-not $running) {
        if (-not (Test-Path $qbitPath)) { throw "qBittorrent not found: $qbitPath" }
        Set-IniListenPort -Port $port
        Start-Process -FilePath $qbitPath -WindowStyle Minimized
        Write-Log INFO 'qBittorrent launched.'
        $null = Wait-QbitApi
    }
    Sync-QbitSettings -Port $port -Interface $interface
    exit 0
} catch {
    Write-Log ERROR $_.Exception.Message
    if ($PauseOnError) { Read-Host 'Press Enter to close' | Out-Null }
    exit 1
}
