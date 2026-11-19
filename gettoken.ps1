# 取 token 给 GF2-Gacha-Tracker 用：输出 gachaUrl 与 Authorization，并复制到剪贴板。
# 不导出记录，只负责登录拿凭证。token 未过期会直接复用，无需再输验证码。
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSCommandPath) 'gf2lib.ps1')
try {
    $auth = Get-Gf2Auth
    Write-Host ""
    Write-Host "gachaUrl      : $($auth.gachaUrl)" -ForegroundColor Cyan
    Write-Host "Authorization : $($auth.Authorization)" -ForegroundColor Cyan
    Set-Clipboard -Value ("$($auth.gachaUrl)`r`n$($auth.Authorization)")
    Write-Host "`n（两项已复制到剪贴板，直接粘进 GF2-Gacha-Tracker 的同步设置）" -ForegroundColor Green
} catch {
    Write-Host "`n出错：$($_.Exception.Message)" -ForegroundColor Red
} finally { Read-Host "`n按回车退出" }
