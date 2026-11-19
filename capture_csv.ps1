# 抓包版（直接导出 CSV）：从真实游戏流量截取 token，然后拉取全部卡池导出 CSV。
# 需管理员 + 游戏运行中。用作自动登录失效时的兜底。
param([switch]$Elevated)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'gf2lib.ps1')
try {
    if (-not (Test-Admin)) {
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated"
        return
    }
    $auth = Invoke-GachaCapture
    Write-Host "`n抓到 token，开始导出...`n" -ForegroundColor Green
    Export-Records $auth | Out-Null
} catch {
    Write-Host "`n出错：$($_.Exception.Message)" -ForegroundColor Red
} finally { Read-Host "`n按回车退出" }
