[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WxdownPath,
    [Parameter(Mandatory = $true)][string]$SessionDirectory,
    [int]$CapturePort = 65100,
    [int]$WssPort = 65102,
    [int]$WatchdogTimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'

function Test-TcpPort([int]$Port) {
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $Port)
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $client) { $client.Dispose() }
    }
}

function Refresh-WinInet {
    if (-not ('WinInetCaptureRefresh' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WinInetCaptureRefresh {
    [DllImport("wininet.dll", SetLastError=true)]
    public static extern bool InternetSetOption(IntPtr h, int option, IntPtr buffer, int length);
}
'@
    }
    [void][WinInetCaptureRefresh]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][WinInetCaptureRefresh]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}

$wxdown = [System.IO.Path]::GetFullPath($WxdownPath)
$session = [System.IO.Path]::GetFullPath($SessionDirectory)
[System.IO.Directory]::CreateDirectory($session) | Out-Null
$statePath = Join-Path $session 'capture-state.json'
if (Test-Path -LiteralPath $statePath) {
    throw "Capture state already exists: $statePath"
}

$python = Join-Path $wxdown '.venv\Scripts\python.exe'
$main = Join-Path $wxdown 'main.py'
$credentialsPath = Join-Path $wxdown 'resources\data\credentials.json'
$wssCertPath = Join-Path $wxdown 'resources\data\wss-cert.pem'
$wssKeyPath = Join-Path $wxdown 'resources\data\wss-key.pem'
foreach ($required in @($python, $main)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required file is missing: $required"
    }
}
if (Test-Path -LiteralPath $credentialsPath) {
    throw "Credential file already exists. Run cleanup or move it first: $credentialsPath"
}

$internetSettings = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$proxy = Get-ItemProperty -LiteralPath $internetSettings
$autoConfigPresent = $proxy.PSObject.Properties.Name -contains 'AutoConfigURL'
$caDirectory = Join-Path $env:USERPROFILE '.mitmproxy'
$caDirectoryExisted = Test-Path -LiteralPath $caDirectory
$caPath = Join-Path $caDirectory 'mitmproxy-ca-cert.cer'
$wssCertExisted = Test-Path -LiteralPath $wssCertPath
$wssKeyExisted = Test-Path -LiteralPath $wssKeyPath
$stdoutPath = Join-Path $session 'wxdown.stdout.log'
$stderrPath = Join-Path $session 'wxdown.stderr.log'
$service = $null
$certificateThumbprint = $null
$certificateInstalledBySession = $false

try {
    $service = Start-Process -FilePath $python `
        -ArgumentList @('main.py', '-p', [string]$CapturePort, '-w', [string]$WssPort) `
        -WorkingDirectory $wxdown `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru

    $ready = $false
    for ($attempt = 0; $attempt -lt 80; $attempt++) {
        Start-Sleep -Milliseconds 250
        if ($service.HasExited) {
            throw "wxdown-service exited early with code $($service.ExitCode)."
        }
        if ((Test-Path -LiteralPath $caPath) -and (Test-TcpPort $CapturePort)) {
            $ready = $true
            break
        }
    }
    if (-not $ready) {
        throw "Capture proxy did not start on port $CapturePort."
    }

    $ca = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($caPath)
    $certificateThumbprint = $ca.Thumbprint
    $certificatePath = "Cert:\CurrentUser\Root\$certificateThumbprint"
    if (-not (Test-Path -LiteralPath $certificatePath)) {
        $certOutput = & certutil.exe -user -f -addstore root $caPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ($certOutput -join [Environment]::NewLine)
        }
        $certificateInstalledBySession = $true
    }

    $state = [ordered]@{
        version = 1
        createdAt = [DateTimeOffset]::Now.ToString('o')
        wxdownPath = $wxdown
        sessionDirectory = $session
        processId = $service.Id
        watchdogPid = $null
        capturePort = $CapturePort
        wssPort = $WssPort
        credentialsPath = $credentialsPath
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
        originalProxyEnable = [int]$proxy.ProxyEnable
        originalProxyServer = [string]$proxy.ProxyServer
        originalAutoConfigPresent = $autoConfigPresent
        originalAutoConfigUrl = [string]$proxy.AutoConfigURL
        certificateThumbprint = $certificateThumbprint
        certificateInstalledBySession = $certificateInstalledBySession
        caDirectory = $caDirectory
        caDirectoryCreatedBySession = -not $caDirectoryExisted
        wssCertPath = $wssCertPath
        wssKeyPath = $wssKeyPath
        wssCertCreatedBySession = -not $wssCertExisted
        wssKeyCreatedBySession = -not $wssKeyExisted
    }
    [System.IO.File]::WriteAllText(
        $statePath,
        ($state | ConvertTo-Json -Depth 6),
        [System.Text.UTF8Encoding]::new($false)
    )

    $cleanupScript = Join-Path $PSScriptRoot 'cleanup-capture.ps1'
    $watchdog = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $cleanupScript,
            '-StatePath', $statePath, '-Watchdog', '-TimeoutSeconds', [string]$WatchdogTimeoutSeconds
        ) `
        -WindowStyle Hidden `
        -PassThru
    $state.watchdogPid = $watchdog.Id
    [System.IO.File]::WriteAllText(
        $statePath,
        ($state | ConvertTo-Json -Depth 6),
        [System.Text.UTF8Encoding]::new($false)
    )

    Set-ItemProperty -LiteralPath $internetSettings -Name ProxyEnable -Type DWord -Value 1
    Set-ItemProperty -LiteralPath $internetSettings -Name ProxyServer -Type String -Value "127.0.0.1:$CapturePort"
    Remove-ItemProperty -LiteralPath $internetSettings -Name AutoConfigURL -ErrorAction SilentlyContinue
    Refresh-WinInet

    [pscustomobject]@{
        statePath = $statePath
        proxy = "127.0.0.1:$CapturePort"
        credentialsPath = $credentialsPath
        watchdogTimeoutSeconds = $WatchdogTimeoutSeconds
    } | ConvertTo-Json -Compress
} catch {
    if ($null -ne $service -and -not $service.HasExited) {
        Stop-Process -Id $service.Id -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $statePath) {
        & (Join-Path $PSScriptRoot 'cleanup-capture.ps1') -StatePath $statePath
    } elseif ($certificateInstalledBySession -and -not [string]::IsNullOrWhiteSpace($certificateThumbprint)) {
        & certutil.exe -user -delstore root $certificateThumbprint | Out-Null
    }
    throw
}
