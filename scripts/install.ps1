param(
  [string]$BundleName = 'com.yiertongchuan.interpreter'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$candidates = @(
  $env:DEVECO_HOME,
  'D:\Program Files\Huawei\DevEco Studio',
  'C:\Program Files\Huawei\DevEco Studio'
) | Where-Object { $_ }
$deveco = $candidates | Where-Object { Test-Path (Join-Path $_ 'sdk\default\openharmony\toolchains\hdc.exe') } | Select-Object -First 1
if (-not $deveco) { throw '未找到 DevEco Studio 的 hdc.exe，请设置 DEVECO_HOME。' }
$hdc = Join-Path $deveco 'sdk\default\openharmony\toolchains\hdc.exe'
$hap = Join-Path $root 'entry\build\default\outputs\default\entry-default-signed.hap'

if (-not (Test-Path $hap)) {
  throw "未找到已签名 HAP：$hap`n请先在 DevEco Studio 打开项目，Project Structure → Signing Configs 勾选自动签名，再 Run 一次；或运行 scripts/build.ps1 后手动签名。"
}

& $hdc list targets
& $hdc install -r $hap
if ($LASTEXITCODE -ne 0) {
  throw "安装失败。请确认签名 Profile 已包含当前设备 UDID，且 bundlename 为 $BundleName。"
}
& $hdc shell "aa start -a EntryAbility -b $BundleName"
Write-Host "Started $BundleName" -ForegroundColor Green
