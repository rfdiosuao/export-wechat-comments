[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [switch]$Watchdog,
    [int]$TimeoutSeconds = 900,
    [switch]$KeepSessionDirectory
)

$ErrorActionPreference = 'Stop'
$resolvedStatePath = [System.IO.Path]::GetFullPath($StatePath)

if ($Watchdog) {
    $deadline = [DateTimeOffset]::Now.AddSeconds($TimeoutSeconds)
    while ((Test-Path -LiteralPath $resolvedStatePath) -and [DateTimeOffset]::Now -lt $deadline) {
        Start-Sleep -Seconds 5
    }
    if (-not (Test-Path -LiteralPath $resolvedStatePath)) {
        exit 0
    }
}

if (-not (Test-Path -LiteralPath $resolvedStatePath -PathType Leaf)) {
    [pscustomobject]@{ complete = $true; message = 'State file is already gone.' } | ConvertTo-Json -Compress
    exit 0
}

$state = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedStatePath | ConvertFrom-Json
$internetSettings = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

function Refresh-WinInet {
    if (-not ('WinInetCleanupRefresh' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WinInetCleanupRefresh {
    [DllImport("wininet.dll", SetLastError=true)]
    public static extern bool InternetSetOption(IntPtr h, int option, IntPtr buffer, int length);
}
'@
    }
    [void][WinInetCleanupRefresh]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
    [void][WinInetCleanupRefresh]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
}

function Stop-ProcessTree([int]$RootProcessId) {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    $children = @{}
    foreach ($process in $all) {
        $parent = [int]$process.ParentProcessId
        if (-not $children.ContainsKey($parent)) { $children[$parent] = @() }
        $children[$parent] += [int]$process.ProcessId
    }
    $ordered = [System.Collections.Generic.List[int]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $queue.Enqueue($RootProcessId)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $ordered.Add($current)
        if ($children.ContainsKey($current)) {
            foreach ($child in @($children[$current])) { $queue.Enqueue($child) }
        }
    }
    for ($index = $ordered.Count - 1; $index -ge 0; $index--) {
        Stop-Process -Id $ordered[$index] -Force -ErrorAction SilentlyContinue
    }
}

Set-ItemProperty -LiteralPath $internetSettings -Name ProxyEnable -Type DWord -Value ([int]$state.originalProxyEnable)
Set-ItemProperty -LiteralPath $internetSettings -Name ProxyServer -Type String -Value ([string]$state.originalProxyServer)
if ([bool]$state.originalAutoConfigPresent) {
    Set-ItemProperty -LiteralPath $internetSettings -Name AutoConfigURL -Type String -Value ([string]$state.originalAutoConfigUrl)
} else {
    Remove-ItemProperty -LiteralPath $internetSettings -Name AutoConfigURL -ErrorAction SilentlyContinue
}
Refresh-WinInet

if ($null -ne $state.watchdogPid -and [int]$state.watchdogPid -ne $PID) {
    Stop-Process -Id ([int]$state.watchdogPid) -Force -ErrorAction SilentlyContinue
}
Stop-ProcessTree ([int]$state.processId)
Start-Sleep -Milliseconds 500

if (Test-Path -LiteralPath ([string]$state.credentialsPath)) {
    [System.IO.File]::Delete([string]$state.credentialsPath)
}
foreach ($path in @([string]$state.stdoutPath, [string]$state.stderrPath)) {
    if (Test-Path -LiteralPath $path) { [System.IO.File]::Delete($path) }
}
if ([bool]$state.wssCertCreatedBySession -and (Test-Path -LiteralPath ([string]$state.wssCertPath))) {
    [System.IO.File]::Delete([string]$state.wssCertPath)
}
if ([bool]$state.wssKeyCreatedBySession -and (Test-Path -LiteralPath ([string]$state.wssKeyPath))) {
    [System.IO.File]::Delete([string]$state.wssKeyPath)
}

$certificateNeedsUserAction = $false
if ([bool]$state.certificateInstalledBySession) {
    $certificatePath = "Cert:\CurrentUser\Root\$($state.certificateThumbprint)"
    if (Test-Path -LiteralPath $certificatePath) {
        $certProcess = Start-Process -FilePath 'certutil.exe' `
            -ArgumentList @('-user', '-delstore', 'root', [string]$state.certificateThumbprint) `
            -WindowStyle Hidden `
            -PassThru
        if (-not $certProcess.WaitForExit(15000)) {
            $certificateNeedsUserAction = $true
        }
    }
}

$certificateRemoved = -not (Test-Path -LiteralPath "Cert:\CurrentUser\Root\$($state.certificateThumbprint)")
if ($certificateRemoved -and [bool]$state.caDirectoryCreatedBySession) {
    $caFiles = @(
        'mitmproxy-ca-cert.cer', 'mitmproxy-ca-cert.p12', 'mitmproxy-ca-cert.pem',
        'mitmproxy-ca.p12', 'mitmproxy-ca.pem', 'mitmproxy-dhparam.pem'
    )
    foreach ($name in $caFiles) {
        $path = Join-Path ([string]$state.caDirectory) $name
        if (Test-Path -LiteralPath $path) { [System.IO.File]::Delete($path) }
    }
    if ((Test-Path -LiteralPath ([string]$state.caDirectory)) -and
        -not (Get-ChildItem -LiteralPath ([string]$state.caDirectory) -Force)) {
        [System.IO.Directory]::Delete([string]$state.caDirectory)
    }
}

$complete = $certificateRemoved -or -not [bool]$state.certificateInstalledBySession
if ($complete) {
    [System.IO.File]::Delete($resolvedStatePath)
    if (-not $KeepSessionDirectory -and
        (Test-Path -LiteralPath ([string]$state.sessionDirectory)) -and
        -not (Get-ChildItem -LiteralPath ([string]$state.sessionDirectory) -Force)) {
        [System.IO.Directory]::Delete([string]$state.sessionDirectory)
    }
}

[pscustomobject]@{
    complete = $complete
    proxyRestored = $true
    credentialRemoved = -not (Test-Path -LiteralPath ([string]$state.credentialsPath))
    certificateRemoved = $certificateRemoved
    certificateNeedsUserAction = $certificateNeedsUserAction
    statePath = if ($complete) { $null } else { $resolvedStatePath }
} | ConvertTo-Json -Compress
