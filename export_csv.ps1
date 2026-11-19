# 直接导出抽卡记录为 CSV：登录（token 未过期则复用）-> 拉取全部卡池 -> 保存 CSV + 统计。
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'gf2lib.ps1')
try {
    $auth = Get-Gf2Auth
    Export-Records $auth | Out-Null
} catch {
    Write-Host "`n出错：$($_.Exception.Message)" -ForegroundColor Red
} finally { Read-Host "`n按回车退出" }
