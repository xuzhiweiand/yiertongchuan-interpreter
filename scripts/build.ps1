param(
  [switch]$Release
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$env:DEVECO_SDK_HOME = 'C:\Program Files\Huawei\DevEco Studio\sdk'
$env:NODE_HOME = 'C:\Program Files\Huawei\DevEco Studio\tools\node'
$hvigor = 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat'
$mode = if ($Release) { 'release' } else { 'debug' }

if (-not (Test-Path $hvigor)) {
  throw "未找到 hvigorw：$hvigor`n请先安装/修复 DevEco Studio 与 HarmonyOS SDK。"
}

Write-Host "Building $mode HAP..." -ForegroundColor Cyan
& $hvigor --mode module -p product=default -p buildMode=$mode assembleHap
if ($LASTEXITCODE -ne 0) {
  throw "hvigor build failed with exit code $LASTEXITCODE"
}

$outDir = Join-Path $root 'entry\build\default\outputs\default'
$signed = Join-Path $outDir 'entry-default-signed.hap'
$unsigned = Join-Path $outDir 'entry-default-unsigned.hap'
if (Test-Path $signed) {
  Write-Host "Signed HAP: $signed" -ForegroundColor Green
  Get-Item $signed | Select-Object Length, LastWriteTime
} elseif (Test-Path $unsigned) {
  Write-Host "Unsigned HAP: $unsigned" -ForegroundColor Yellow
  Write-Host "请在 DevEco Studio 中开启自动签名后 Run，或手动签名后再安装。" -ForegroundColor Yellow
} else {
  throw "构建完成但未找到 HAP，请检查 $outDir"
}
