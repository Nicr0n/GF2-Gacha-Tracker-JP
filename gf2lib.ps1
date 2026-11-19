# gf2lib.ps1 —— 少女前线2(日服/HaoPlay) 抽卡记录共享库
# 被 取token给工具.ps1 / 导出CSV.ps1 点源调用。详见 登录流程.md。
# 登录签名： sig = Base64(HMAC-SHA1(参数串, md5(md5("")))) ，appkey/privatekey 为空（已实测）。

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:Root     = Split-Path -Parent $PSCommandPath
$script:AuthFile = Join-Path $script:Root 'auth.json'
$script:DevFile  = Join-Path $script:Root 'device.json'

$script:API      = 'https://p4.17996api.net'
$script:GACHAURL = 'https://gf2-gacha-record-jp.haoplay.com/list'
$script:XINDONG  = 'https://gf2-zoneinfo-jp.haoplay.com/passport/xindong_login'
$script:ITEMMAP  = 'https://raw.githubusercontent.com/shrsheng/GF2-Gacha-Tracker/main/itemMap.json'
$script:UA       = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36 Edg/157.0.0.0'
$script:TOP      = 'https://platform.17996cdn.net/assets/html/pages/pn_unity_sdk_bridge.html'
$script:PoolNames = @{ 1='常规采购'; 2='类型2'; 3='定向采购'; 4='军备提升'; 5='新手采购'; 6='自选人形'; 7='自选武器'; 8='神秘箱'; 9='新装采购' }
$script:ToolsDir = Join-Path $script:Root 'tools'
$script:MitmVer  = '12.1.2'
$script:GameExe  = 'GF2_Exilium.exe'

# ---------- 工具函数 ----------
function UriComp([string]$s) {       # 等价 JS encodeURIComponent
    if ($null -eq $s) { return '' }
    $keep = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    $sb = [Text.StringBuilder]::new()
    foreach ($b in [Text.Encoding]::UTF8.GetBytes($s)) {
        $c = [char]$b
        if ($keep.IndexOf($c) -ge 0) { [void]$sb.Append($c) } else { [void]$sb.AppendFormat('%{0:X2}', $b) }
    }
    $sb.ToString()
}
function Md5Hex([string]$s) {
    $m = [Security.Cryptography.MD5]::Create()
    ($m.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)) | ForEach-Object { $_.ToString('x2') }) -join ''
}
$script:SigKey = Md5Hex((Md5Hex '') + '')

function Build-Body([string[]]$pairs) {   # pairs: @("k=encodedV") ，不含 time/sys/tz/sig
    $arr = [Collections.Generic.List[string]]::new()
    foreach ($p in $pairs) { $arr.Add($p) }
    $arr.Add('time=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $arr.Add('sys=web'); $arr.Add('tz=-540')
    $hmac = [Security.Cryptography.HMACSHA1]::new([Text.Encoding]::UTF8.GetBytes($script:SigKey))
    $sig = [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes(($arr -join '&'))))
    $arr.Add('sig=' + (UriComp $sig))
    ($arr -join '&')
}
function Post-Form([string]$path, [string]$body) {
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$script:API/$path" -Headers @{ 'User-Agent' = $script:UA } `
        -ContentType 'application/x-www-form-urlencoded' -Body $body
    [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
}
function Get-Json($resp) { [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json }
function Jwt-Field($jwt, $name) {
    $p = ($jwt -split '\.')[1].Replace('-', '+').Replace('_', '/'); while ($p.Length % 4) { $p += '=' }
    ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json).$name
}
function Token-ExpiresAt([string]$token) {
    try {
        $p = ($token -split '\.')[0].Replace('-', '+').Replace('_', '/'); while ($p.Length % 4) { $p += '=' }
        $exp = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json).expires
        [DateTimeOffset]::FromUnixTimeSeconds([long]$exp).LocalDateTime
    } catch { $null }
}

# ---------- 设备标识 ----------
# 首次运行随机生成一个 guid 并存入 device.json，之后固定复用（固定 guid 可降低被当新设备、
# 触发验证码的概率）。若想沿用游戏本机的 guid，可手动把 device.json 的 guid 改成抓包得到的值。
function Get-DeviceGuid {
    if (Test-Path $script:DevFile) {
        $g = (Get-Content $script:DevFile -Raw | ConvertFrom-Json).guid
        if ($g) { return $g }
    }
    $g = [guid]::NewGuid().ToString()
    @{ guid = $g } | ConvertTo-Json | Set-Content $script:DevFile -Encoding UTF8
    $g
}

# ---------- 邮箱+验证码登录 -> access_token ----------
function Invoke-EmailLogin {
    $guid = Get-DeviceGuid
    $common = @(
        "guid=$guid", "deviceid=$guid", "dev=$(UriComp $script:UA)",
        'bundleid=platform.17996cdn.net', 'appid=2088100', 'l=cn', 'sdkver=881',
        "top=$(UriComp $script:TOP)"
    )
    $init = Post-Form 'api/init' (Build-Body $common)
    if ($init.code -ne 0 -or -not $init.term) { throw "init 失败: $($init.msg) (code $($init.code))。多半是 SDK 更新导致签名失效。" }
    $term = $init.term

    $email = Read-Host "邮箱"
    $send = Post-Form 'api/send' (Build-Body ($common + @("term=$term", 'provider=email', "email=$(UriComp $email)", 'validate=null')))
    if ("$($send.ret)" -ne '0' -and $send.code -ne 0) { throw "发送验证码失败: $($send.msg)。可能触发了网易易盾验证码。" }
    Write-Host "验证码已发送到 $email" -ForegroundColor Green

    $code = Read-Host "验证码"
    $login = Post-Form 'api/login' (Build-Body ($common + @("term=$term", "code=$code", "openid=$(UriComp $email)", "email=$(UriComp $email)", 'provider=email')))
    if ($login.code -ne 0 -or -not $login.jwt) { throw "登录失败: $($login.msg) (code $($login.code))" }
    $jwt = $login.jwt

    $xbody = @{ os = 3; game_channel_id = 10001; uid = "$(Jwt-Field $jwt 'uid')"; game_name = 'EXILIUM'; jwt = $jwt } | ConvertTo-Json -Compress
    $xj = Get-Json (Invoke-WebRequest -UseBasicParsing -Method Post -Uri $script:XINDONG -ContentType 'application/json' -Body $xbody)
    if ($xj.code -ne 0 -or -not $xj.data.access_token) { throw "换 access_token 失败: $($xj.msg)" }

    @{ guid = $guid } | ConvertTo-Json | Set-Content $script:DevFile -Encoding UTF8
    $xj.data.access_token
}

# ---------- 取得可用的 {gachaUrl, Authorization}：优先复用未过期的 auth.json ----------
function Get-Gf2Auth {
    param([switch]$ForceLogin)
    if (-not $ForceLogin -and (Test-Path $script:AuthFile)) {
        try {
            $a = Get-Content $script:AuthFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $exp = Token-ExpiresAt $a.Authorization
            if ($a.Authorization -and $exp -and $exp -gt (Get-Date).AddMinutes(5)) {
                Write-Host ("复用已保存的 token（有效期至 {0:yyyy-MM-dd HH:mm}）" -f $exp) -ForegroundColor DarkGray
                return $a
            }
        } catch {}
        Write-Host "已保存的 token 不存在或已过期，需要重新登录。" -ForegroundColor Yellow
    }
    $token = Invoke-EmailLogin
    $auth = [pscustomobject]@{ gachaUrl = $script:GACHAURL; Authorization = $token }
    $auth | ConvertTo-Json | Set-Content $script:AuthFile -Encoding UTF8
    $exp = Token-ExpiresAt $token
    if ($exp) { Write-Host ("登录成功，token 有效期至 {0:yyyy-MM-dd HH:mm}" -f $exp) -ForegroundColor Green }
    $auth
}

# ---------- 抓取全部卡池记录 ----------
function Invoke-GachaPage($auth, [int]$type, [string]$next) {
    $body = @{ type_id = "$type"; limit = '20' }
    if ($next) { $body.next = $next }
    Get-Json (Invoke-WebRequest -UseBasicParsing -Method Post -Uri $auth.gachaUrl `
        -Headers @{ Authorization = $auth.Authorization } -ContentType 'application/x-www-form-urlencoded' -Body $body)
}
function Get-AllRecords($auth) {
    $all = [Collections.Generic.List[object]]::new()
    foreach ($type in 1..9) {
        $next = ''; $n = 0; $page = 0
        do {
            try { $j = Invoke-GachaPage $auth $type $next } catch { Write-Host "  [$($script:PoolNames[$type])] 请求失败：$($_.Exception.Message)" -ForegroundColor DarkYellow; break }
            if ($j.code -ne 0) { break }
            $list = @($j.data.list) + @($j.data.record_list) + @($j.data.RecordList) | Where-Object { $_ }
            foreach ($rec in $list) {
                $id = if ($null -ne $rec.item_id) { $rec.item_id } else { $rec.item }
                $ts = if ($null -ne $rec.gacha_timestamp) { $rec.gacha_timestamp } else { $rec.time }
                $all.Add([pscustomobject]@{ type = $type; pool_id = $rec.pool_id; item_id = "$id"; ts = [long]$ts; num = $rec.item_num; seq = $n }); $n++
            }
            $next = if ($j.data.next) { $j.data.next } elseif ($j.data.Next) { $j.data.Next } else { '' }
            $page++
            Write-Progress -Activity '拉取抽卡记录（每页 20 条）' -Status "$($script:PoolNames[$type])：第 $page 页，共 $n 条"
            Start-Sleep -Milliseconds 100
        } while ($next)
        Write-Progress -Activity '拉取' -Completed
        if ($n -gt 0) { Write-Host "  [$($script:PoolNames[$type])] $n 条" }
    }
    , $all
}

# ---------- 导出 CSV + 统计 ----------
function Export-Records($auth) {
    Write-Host "下载物品名称表..." -ForegroundColor DarkGray
    $map = $null; try { $map = Get-Json (Invoke-WebRequest -UseBasicParsing $script:ITEMMAP) } catch { Write-Host "  获取失败，只输出物品 ID" -ForegroundColor DarkYellow }
    Write-Host "拉取抽卡记录..."
    $raw = Get-AllRecords $auth
    if ($raw.Count -eq 0) { throw '没有拉到任何记录' }
    $rows = foreach ($r in $raw) {
        $info = if ($map) { $map.($r.item_id) } else { $null }
        [pscustomobject]@{
            卡池类型 = $script:PoolNames[$r.type]; 卡池ID = $r.pool_id
            时间 = [DateTimeOffset]::FromUnixTimeSeconds($r.ts).LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')
            物品ID = $r.item_id; 名称 = if ($info) { $info.name } else { '' }; 稀有度 = if ($info) { $info.rarity } else { '' }
            _type = $r.type; _seq = $r.seq
        }
    }
    $rows = $rows | Sort-Object _type, @{ e = '_seq'; Descending = $true }   # 转为抽取正序
    $csv = Join-Path $script:Root ("gf2_gacha_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $rows | Select-Object 卡池类型, 卡池ID, 时间, 物品ID, 名称, 稀有度 | Export-Csv $csv -NoTypeInformation -Encoding UTF8
    Write-Host "`n===== 统计 =====" -ForegroundColor Green
    foreach ($g in ($rows | Group-Object _type)) {
        $pity = 0
        foreach ($r in $g.Group) { $pity++; if ($r.稀有度 -eq '橙色') { $pity = 0 } }
        Write-Host ("{0}：共 {1} 抽，当前已垫 {2} 抽" -f $g.Group[0].卡池类型, $g.Count, $pity) -ForegroundColor Cyan
    }
    Write-Host "`n明细已保存：$csv" -ForegroundColor Green
    $csv
}

# ---------- 抓包兜底：从真实游戏流量截取 gachaUrl + Authorization ----------
function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-Mitmdump {
    $exe = Get-ChildItem $script:ToolsDir -Recurse -Filter mitmdump.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) { return $exe.FullName }
    New-Item -ItemType Directory -Force $script:ToolsDir | Out-Null
    $zip = Join-Path $script:ToolsDir "mitmproxy-$($script:MitmVer).zip"
    Write-Host "下载 mitmproxy $($script:MitmVer)（约 30MB，仅首次）..."
    Invoke-WebRequest -UseBasicParsing "https://downloads.mitmproxy.org/$($script:MitmVer)/mitmproxy-$($script:MitmVer)-windows-x86_64.zip" -OutFile $zip
    Expand-Archive $zip -DestinationPath (Join-Path $script:ToolsDir "mitmproxy-$($script:MitmVer)") -Force
    Remove-Item $zip
    (Get-ChildItem $script:ToolsDir -Recurse -Filter mitmdump.exe | Select-Object -First 1).FullName
}
function Read-Shared([string]$path) {
    if (-not (Test-Path $path)) { return '' }
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try { (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Close() }
}
# 抓包取得 {gachaUrl, Authorization}，并写入 auth.json。需管理员 + 游戏运行中。
function Invoke-GachaCapture {
    if (-not (Test-Admin)) { throw '抓包需要管理员权限，请用对应的 .bat（会自动提权）运行。' }
    $mitm = Get-Mitmdump
    $log = Join-Path $script:Root 'mitm.log'; $err = Join-Path $script:Root 'mitm.err.log'
    Remove-Item $log, $err -ErrorAction SilentlyContinue
    $certPath = Join-Path $env:USERPROFILE '.mitmproxy\mitmproxy-ca-cert.cer'
    $store = $null; $cert = $null; $proc = $null
    try {
        $mArgs = @('--mode', "local:$($script:GameExe)", '--set', 'showhost=true', '--flow-detail', '2', '"~m POST & ~b type_id"')
        $proc = Start-Process -FilePath $mitm -ArgumentList $mArgs -NoNewWindow -PassThru -RedirectStandardOutput $log -RedirectStandardError $err
        for ($i = 0; $i -lt 30 -and -not (Test-Path $certPath); $i++) { Start-Sleep 1 }
        if ($proc.HasExited) { throw "mitmdump 启动失败：`n$(Read-Shared $err)" }
        if (-not (Test-Path $certPath)) { throw "mitmproxy 未生成证书，请查看 $err" }
        $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $certPath
        $store = New-Object Security.Cryptography.X509Certificates.X509Store 'Root', 'LocalMachine'
        $store.Open('ReadWrite'); $store.Add($cert)
        Write-Host "已临时信任 mitmproxy 证书（结束后自动删除）" -ForegroundColor DarkGray
        Write-Host "`n>>> 现在进游戏，打开 采购 -> 记录（翻一下页） <<<" -ForegroundColor Cyan
        Write-Host "    超过 1 分钟没反应：保持本窗口开着，重启游戏后再打开记录" -ForegroundColor DarkGray
        $deadline = (Get-Date).AddMinutes(10)
        while ((Get-Date) -lt $deadline) {
            if ($proc.HasExited) { throw "mitmdump 意外退出：`n$(Read-Shared $err)" }
            $text = (Read-Shared $log) -replace "$([char]27)\[[0-9;]*m", ''
            $url = $null
            foreach ($line in $text -split "`r?`n") {
                if ($line -match ':\s+POST\s+(https?://\S+)') { $url = $Matches[1] }
                elseif ($url -and $line -match '^\s+Authorization:\s*(.+?)\s*$') {
                    $auth = [pscustomobject]@{ gachaUrl = $url; Authorization = $Matches[1] }
                    $auth | ConvertTo-Json | Set-Content $script:AuthFile -Encoding UTF8
                    return $auth
                }
            }
            Start-Sleep 1
        }
        throw '10 分钟内未抓到抽卡记录请求'
    } finally {
        if ($proc) { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null; Start-Sleep 1 }
        Get-CimInstance Win32_Process -Filter "Name='mitmdump.exe'" | Where-Object { $_.ExecutablePath -like "$($script:ToolsDir)*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        if ($store) { if ($cert) { $store.Remove($cert) }; $store.Close() }
        Remove-Item $log -ErrorAction SilentlyContinue   # 含 token，必须删除
    }
}
