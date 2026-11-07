param(
  [switch]$Release
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

# Locate DevEco Studio (installer may place it on any drive).
$candidates = @(
  $env:DEVECO_HOME,
  'D:\Program Files\Huawei\DevEco Studio',
  'C:\Program Files\Huawei\DevEco Studio'
) | Where-Object { $_ }

$deveco = $null
foreach ($c in $candidates) {
  if (Test-Path (Join-Path $c 'tools\hvigor\bin\hvigorw.bat')) { $deveco = $c; break }
}
if (-not $deveco) {
  throw "未找到 DevEco Studio（需要 tools\hvigor\bin\hvigorw.bat）。请安装/修复 DevEco Studio，或设置 DEVECO_HOME。"
}

$env:DEVECO_SDK_HOME = Join-Path $deveco 'sdk'
$nodeHome = Join-Path $deveco 'tools\node'
if (Test-Path $nodeHome) { $env:NODE_HOME = $nodeHome }
$hvigor = Join-Path $deveco 'tools\hvigor\bin\hvigorw.bat'

$mode = if ($Release) { 'release' } else { 'debug' }

Write-Host "DevEco : $deveco" -ForegroundColor DarkGray
Write-Host "Building $mode HAP..." -ForegroundColor Cyan
# hvigor writes warnings to stderr; keep them from tripping $ErrorActionPreference='Stop'.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $hvigor --mode module -p product=default -p buildMode=$mode assembleHap
$code = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($code -ne 0) {
  throw "hvigor build failed with exit code $code"
}

$outDir = Join-Path $root 'entry\build\default\outputs\default'
$signed = Join-Path $outDir 'entry-default-signed.hap'
$unsigned = Join-Path $outDir 'entry-default-unsigned.hap'
if (Test-Path $signed) {
  Write-Host "Signed HAP: $signed" -ForegroundColor Green
  Get-Item $signed | Select-Object Length, LastWriteTime
} elseif (Test-Path $unsigned) {
  Write-Host "Unsigned HAP: $unsigned" -ForegroundColor Yellow
  Write-Host "请在 DevEco Studio 中配置自动签名后再安装。" -ForegroundColor Yellow
} else {
  throw "构建完成但未找到 HAP，请检查 $outDir"
}