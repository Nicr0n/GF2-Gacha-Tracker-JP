# 抓包版（给 GF2-Gacha-Tracker 用）：从真实游戏流量截取 gachaUrl + Authorization，
# 打印并复制到剪贴板。需管理员 + 游戏运行中。用作自动登录失效时的兜底。
param([switch]$Elevated)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'gf2lib.ps1')
try {
    if (-not (Test-Admin)) {
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated"
        return
    }
    $auth = Invoke-GachaCapture
    Write-Host ""
    Write-Host "gachaUrl      : $($auth.gachaUrl)" -ForegroundColor Cyan
    Write-Host "Authorization : $($auth.Authorization)" -ForegroundColor Cyan
    Set-Clipboard -Value ("$($auth.gachaUrl)`r`n$($auth.Authorization)")
    Write-Host "`n（两项已复制到剪贴板，直接粘进 GF2-Gacha-Tracker）" -ForegroundColor Green
} catch {
    Write-Host "`n出错：$($_.Exception.Message)" -ForegroundColor Red
} finally { Read-Host "`n按回车退出" }
