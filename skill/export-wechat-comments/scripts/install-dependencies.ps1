[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Destination,
    [string]$WxdownVersion = 'v0.27.1',
    [string]$ExporterVersion = 'v2.3.21',
    [switch]$SkipExporter
)

$ErrorActionPreference = 'Stop'
$destinationPath = [System.IO.Path]::GetFullPath($Destination)
$wxdownPath = Join-Path $destinationPath 'wxdown-service'
$exporterPath = Join-Path $destinationPath 'wechat-article-exporter'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'git is required.'
}
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    throw 'Python 3.12 is required.'
}

[System.IO.Directory]::CreateDirectory($destinationPath) | Out-Null

if (-not (Test-Path -LiteralPath $wxdownPath)) {
    & git clone --depth 1 --branch $WxdownVersion 'https://github.com/wechat-article/wxdown-service.git' $wxdownPath
    if ($LASTEXITCODE -ne 0) { throw 'Failed to clone wxdown-service.' }
}

$venvPython = Join-Path $wxdownPath '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $venvPython)) {
    & python -m venv (Join-Path $wxdownPath '.venv')
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create the Python virtual environment.' }
}
$env:PIP_DISABLE_PIP_VERSION_CHECK = '1'
& $venvPython -m pip install -r (Join-Path $wxdownPath 'requirements.txt')
if ($LASTEXITCODE -ne 0) { throw 'Failed to install wxdown-service dependencies.' }

if (-not $SkipExporter) {
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
        throw 'Node.js 22 or newer is required for wechat-article-exporter.'
    }
    if (-not (Test-Path -LiteralPath $exporterPath)) {
        & git clone --depth 1 --branch $ExporterVersion 'https://github.com/wechat-article/wechat-article-exporter.git' $exporterPath
        if ($LASTEXITCODE -ne 0) { throw 'Failed to clone wechat-article-exporter.' }
    }
    Push-Location $exporterPath
    try {
        if (Get-Command yarn -ErrorAction SilentlyContinue) {
            & yarn install --frozen-lockfile
            if ($LASTEXITCODE -ne 0) { throw 'yarn install failed.' }
            & yarn build
            if ($LASTEXITCODE -ne 0) { throw 'yarn build failed.' }
        } elseif (Get-Command corepack -ErrorAction SilentlyContinue) {
            & corepack yarn install --frozen-lockfile
            if ($LASTEXITCODE -ne 0) { throw 'corepack yarn install failed.' }
            & corepack yarn build
            if ($LASTEXITCODE -ne 0) { throw 'corepack yarn build failed.' }
        } else {
            throw 'yarn or corepack is required to build wechat-article-exporter.'
        }
    } finally {
        Pop-Location
    }
}

[pscustomobject]@{
    wxdownPath = $wxdownPath
    exporterPath = if ($SkipExporter) { $null } else { $exporterPath }
    wxdownVersion = $WxdownVersion
    exporterVersion = if ($SkipExporter) { $null } else { $ExporterVersion }
} | ConvertTo-Json -Compress
