[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WxdownPath,
    [int]$CapturePort = 65100,
    [int]$WssPort = 65102,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Test-PortBindable([int]$Port) {
    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    } catch {
        return $false
    } finally {
        if ($null -ne $listener) {
            $listener.Stop()
        }
    }
}

$wxdown = [System.IO.Path]::GetFullPath($WxdownPath)
$python = Join-Path $wxdown '.venv\Scripts\python.exe'
$main = Join-Path $wxdown 'main.py'
$addon = Join-Path $wxdown 'resources\credential.py'
$internetSettings = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$proxy = Get-ItemProperty -LiteralPath $internetSettings
$wechatRunning = @(
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -in @('Weixin', 'WeChat', 'WeChatAppEx') }
).Count -gt 0

$checks = [ordered]@{
    windows = $IsWindows -or $env:OS -eq 'Windows_NT'
    wxdownPath = Test-Path -LiteralPath $wxdown -PathType Container
    python = Test-Path -LiteralPath $python -PathType Leaf
    main = Test-Path -LiteralPath $main -PathType Leaf
    credentialAddon = Test-Path -LiteralPath $addon -PathType Leaf
    capturePortBindable = Test-PortBindable $CapturePort
    wssPortBindable = Test-PortBindable $WssPort
    wechatRunning = $wechatRunning
}

$result = [ordered]@{
    ok = -not ($checks.Values -contains $false)
    checks = $checks
    proxy = [ordered]@{
        enabled = [int]$proxy.ProxyEnable
        server = [string]$proxy.ProxyServer
        autoConfigUrl = [string]$proxy.AutoConfigURL
    }
    paths = [ordered]@{
        wxdown = $wxdown
        python = $python
        addon = $addon
    }
}

if ($Json) {
    $result | ConvertTo-Json -Depth 5 -Compress
} else {
    foreach ($entry in $checks.GetEnumerator()) {
        $status = if ($entry.Value) { 'OK' } else { 'FAIL' }
        Write-Output ("[{0}] {1}" -f $status, $entry.Key)
    }
    Write-Output ("Proxy: enabled={0}, server={1}" -f $result.proxy.enabled, $result.proxy.server)
    if (-not $result.ok) {
        throw 'Preflight checks failed. Fix the FAIL entries before capture.'
    }
}
