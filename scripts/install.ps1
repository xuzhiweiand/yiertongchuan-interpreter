param(
  [string]$BundleName = 'com.yiertongchuan.interpreter'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$hdc = 'C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe'
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
