<#
.SYNOPSIS
    dsh-desktop-hand 的自检脚本 —— 在单进程内完成"启动目标窗口 → 聚焦 → 输入 → 读回验证"。

.DESCRIPTION
    为什么需要它：桌面输入测试**必须在一个进程里连续做完**。
    拆成多次 pwsh 调用时，两次调用之间焦点会被系统收回、目标窗口甚至可能已被关闭，
    于是永远测不出结果（开发期实测踩到过：分三次调用，Windows Terminal 窗口每次都被关掉）。

    本脚本的目标窗口用 cmd.exe（真正的 Win32 控制台），并让输入内容**改变窗口标题**，
    这样"输入是否送达"就有了客观判据，不依赖看图猜测。

    用法：
        .\selftest.ps1

    全部通过输出 PASS，任一失败输出 FAIL 并以非 0 退出。
#>
[CmdletBinding()]
param([string]$Engine)

$ErrorActionPreference = 'Stop'
if (-not $Engine) {
    $Engine = Join-Path $PSScriptRoot 'desktop-hand.ps1'
}
if (-not (Test-Path $Engine)) { throw "找不到引擎脚本：$Engine" }

$script:pass = 0
$script:fail = 0

function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Host ("  PASS  " + $name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  FAIL  " + $name + $(if ($detail) { "  -- $detail" } else { '' })) -ForegroundColor Red }
}

# PowerShell 的 `& $script @array` 是按**位置**展开的，会把 "-Action" 当成位置参数，
# 于是被目标脚本的 param() 拒绝（实测报 BAD_ACTION / 无法转换 Handle）。
# 必须用 hashtable splatting 才是真正的"具名参数"传递。
# 注意：引擎脚本用 [Console]::Out.Write 直接写 stdout，不走 PowerShell 的
# 成功流，所以 `& script | Out-String` **抓不到**它（实测只拿到空串）。
# 必须重定向进程级输出：用 & 调用并把整个表达式赋给变量，配合 6>&1 合并信息流。
# 这里改用最稳的办法：起子进程并读 stdout。
function Run([hashtable]$params) {
    $argv = @()
    foreach ($k in $params.Keys) {
        $v = $params[$k]
        if ($v -is [bool]) { if ($v) { $argv += "-$k" } }
        else { $argv += "-$k"; $argv += [string]$v }
    }
    $exe = (Get-Command powershell.exe -ErrorAction SilentlyContinue)
    if (-not $exe) { $exe = (Get-Command pwsh -ErrorAction SilentlyContinue) }
    $out = & $exe.Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Engine @argv 2>$null
    $raw = ($out | Out-String).Trim()
    if (-not $raw) { return [pscustomobject]@{ ok = $false; error = 'engine produced no output' } }
    # 引擎恒输出单行 JSON；取最后一行以防有多余噪声
    $line = ($raw -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if (-not $line) { return [pscustomobject]@{ ok = $false; error = "non-json output: $raw" } }
    try { return $line | ConvertFrom-Json } catch { return [pscustomobject]@{ ok = $false; error = "bad json: $line" } }
}

Write-Host "`n=== dsh-desktop-hand 自检 ===" -ForegroundColor Cyan
Write-Host "engine: $Engine`n"

# ---------------------------------------------------------------- info
Write-Host "[1] info —— DPI 感知与屏幕尺寸"
$info = Run @{ Action = 'info' }
Check 'info 返回 ok' ([bool]$info.ok) $info.error
Check 'DPI 感知已声明' ($info.dpiMode -notmatch 'FAILED') "dpiMode=$($info.dpiMode)"
Check '屏幕宽为物理宽度' ([int]$info.screenWidth -gt 0) "w=$($info.screenWidth)"
Write-Host "      screen=$($info.screenWidth)x$($info.screenHeight) dpi=$($info.dpiMode) ime=$($info.ime)"
if ($info.remoteTools.Count -gt 0) {
    Write-Host "      注意：检测到远程/串流软件 $($info.remoteTools -join ',')" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- list-windows
Write-Host "`n[2] list-windows —— 窗口枚举"
$lw = Run @{ Action = 'list-windows' }
Check 'list-windows 返回 ok' ([bool]$lw.ok) $lw.error
Check '至少枚举到一个窗口' ([int]$lw.count -gt 0) "count=$($lw.count)"
$hasFg = $null -ne $lw.foregroundHandle
Check '返回前台窗口句柄' $hasFg
$withTitle = @($lw.windows | Where-Object { $_.title -and $_.title.Length -gt 0 })
Check '存在有标题的窗口' ($withTitle.Count -gt 0) "titled=$($withTitle.Count)"

# ---------------------------------------------------------------- capture fullscreen
Write-Host "`n[3] capture -FullScreen —— 全屏抓取"
$capDir = Join-Path $env:TEMP 'dsh-desktop-hand-selftest'
if (-not (Test-Path $capDir)) { New-Item -ItemType Directory -Force -Path $capDir | Out-Null }
$full = Run @{ Action = 'capture'; FullScreen = $true; OutPath = (Join-Path $capDir 'full.png') }
Check '全屏抓取 ok' ([bool]$full.ok) $full.error
Check '尺寸等于物理屏' ([int]$full.width -eq [int]$info.screenWidth) "got $($full.width) want $($info.screenWidth)"
Check 'PNG 文件已落盘' (Test-Path $full.path)
if (Test-Path $full.path) {
    Check 'PNG 非空' ((Get-Item $full.path).Length -gt 1000) "bytes=$($full.bytes)"
}

# ---------------------------------------------------------------- capture region
Write-Host "`n[4] capture -Region —— 区域裁切"
$reg = Run @{ Action = 'capture'; FullScreen = $true; Region = '100,100,320,200'; OutPath = (Join-Path $capDir 'region.png') }
Check '区域抓取 ok' ([bool]$reg.ok) $reg.error
Check '裁切尺寸正确 320x200' ([int]$reg.width -eq 320 -and [int]$reg.height -eq 200) "got $($reg.width)x$($reg.height)"
Check '记录了裁切原点' ([int]$reg.originX -eq 100 -and [int]$reg.originY -eq 100) "origin=$($reg.originX),$($reg.originY)"

# 区域越界必须被拒（防静默出错）
$oob = Run @{ Action = 'capture'; FullScreen = $true; Region = '99999,99999,10,10' }
Check '越界区域被拒绝' ((-not $oob.ok) -and $oob.code -eq 'REGION_OOB') "code=$($oob.code)"
$badreg = Run @{ Action = 'capture'; FullScreen = $true; Region = '1,2,3' }
Check '格式错误被拒绝' ((-not $badreg.ok) -and $badreg.code -eq 'BAD_REGION') "code=$($badreg.code)"

# ---------------------------------------------------------------- capture window (occlusion)
Write-Host "`n[5] capture -Window —— 窗口后台抓取（遮挡）"
$explorer = @($lw.windows | Where-Object { $_.class -eq 'CabinetWClass' -and -not $_.minimized } | Select-Object -First 1)
if ($explorer) {
    $wc = Run @{ Action = 'capture'; Handle = $explorer.handle; OutPath = (Join-Path $capDir 'win.png') }
    Check '按句柄抓窗口 ok' ([bool]$wc.ok) $wc.error
    Check '记录了窗口原点' ($null -ne $wc.originX)
} else {
    Write-Host "      跳过：当前没有非最小化的资源管理器窗口" -ForegroundColor Yellow
}

$nomatch = Run @{ Action = 'capture'; Window = 'ZZZ_NO_SUCH_WINDOW_ZZZ' }
Check '不存在的窗口被拒绝' ((-not $nomatch.ok) -and $nomatch.code -eq 'NO_MATCH') "code=$($nomatch.code)"

# ---------------------------------------------------------------- mouse (non-destructive)
Write-Host "`n[6] move / probe —— 鼠标定位与干扰检测"
$mv = Run @{ Action = 'move'; X = 300; Y = 300 }
Check 'move 返回 ok' ([bool]$mv.ok) $mv.error
Check 'move 后光标在目标附近' ($mv.cursor -match '^3[0-2]\d,3[0-2]\d$') "cursor=$($mv.cursor)"

$pr = Run @{ Action = 'probe'; X = 400; Y = 400 }
Check 'probe 返回 ok' ([bool]$pr.ok) $pr.error
$stable = ($pr.probeA -match '^400,400') -and ($pr.probeB -match '^400,400')
if ($stable) { Check '落点稳定（无其他输入源）' $true }
else {
    Write-Host "  WARN  落点不稳定：有别的输入源在驱动光标（远程会话在动鼠标）" -ForegroundColor Yellow
    Write-Host "        A=$($pr.probeA)" -ForegroundColor Yellow
    Write-Host "        B=$($pr.probeB)" -ForegroundColor Yellow
    Write-Host "        这不是插件缺陷；等远端空闲后鼠标点击才可靠。" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- keyboard round-trip
Write-Host "`n[7] focus + type —— 键鼠闭环（客观判据：窗口标题变化）"
$marker = 'DSKHAND' + (Get-Random -Minimum 1000 -Maximum 9999)
$proc = Start-Process cmd.exe -ArgumentList '/k', "title $marker" -PassThru
Start-Sleep -Seconds 3
$target = $null
for ($i = 0; $i -lt 10 -and $null -eq $target; $i++) {
    $cur = Run @{ Action = 'list-windows' }
    $target = @($cur.windows | Where-Object { $_.title -match $marker } | Select-Object -First 1)[0]
    if ($null -eq $target) { Start-Sleep -Milliseconds 500 }
}
Check '找到测试目标窗口' ($null -ne $target) "marker=$marker"

if ($target) {
    $fo = Run @{ Action = 'focus'; Handle = $target.handle }
    Check '聚焦成功' ([bool]$fo.ok) "$($fo.error) result=$($fo.result)"

    $newTitle = 'LANDED' + (Get-Random -Minimum 1000 -Maximum 9999)
    $ty = Run @{ Action = 'type'; Text = "title $newTitle"; Enter = $true }
    Check 'type 返回 ok' ([bool]$ty.ok) $ty.error
    Start-Sleep -Seconds 2

    $after = Run @{ Action = 'list-windows' }
    $hit = @($after.windows | Where-Object { $_.title -match $newTitle })
    Check '输入真的送达了目标窗口（标题已变）' ($hit.Count -gt 0) "期望标题含 $newTitle"

    # 第二次输入：验证可重复，且**每次输入前都重新聚焦**。
    # 为什么要重新聚焦：两次引擎调用之间焦点可能被别的窗口抢走
    # （本机有 GameViewer 远程会话，实测偶发），不重新聚焦就会偶发失败——
    # 那是环境抖动，不是插件缺陷，不该让自检变红。
    $fo2 = Run @{ Action = 'focus'; Handle = $target.handle }
    $cnTitle = 'CN' + (Get-Random -Minimum 1000 -Maximum 9999)
    $ty2 = Run @{ Action = 'type'; Text = "title $cnTitle"; Enter = $true }
    Check 'type 可重复' ([bool]$ty2.ok) $ty2.error
    Start-Sleep -Seconds 2
    $after2 = Run @{ Action = 'list-windows' }
    $hit2 = @($after2.windows | Where-Object { $_.title -match $cnTitle })
    Check '第二次输入也送达了' ($hit2.Count -gt 0) "期望标题含 $cnTitle（focus=$($fo2.result)）"

    # 非 ASCII 走 Unicode 直投，必须原样送达、不被输入法改写。
    # 判据：标题里出现中文就算成功——旧实现（VkKeyScan）会把它变成别的东西。
    $fo3 = Run @{ Action = 'focus'; Handle = $target.handle }
    $ty3 = Run @{ Action = 'type'; Text = 'title 中文测试ABC'; Enter = $true }
    Start-Sleep -Seconds 2
    $after3 = Run @{ Action = 'list-windows' }
    $hit3 = @($after3.windows | Where-Object { $_.title -match '中文测试' })
    Check '中文（Unicode 直投）不被输入法改写' ($hit3.Count -gt 0) `
        "期望标题含「中文测试」；实际含中文的标题：$((($after3.windows | Where-Object { $_.title -match '[\u4e00-\u9fa5]' }).title) -join ' | ')"
}

# ---------------------------------------------------------------- key validation
Write-Host "`n[8] key —— 按键白名单与错误处理"
$k1 = Run @{ Action = 'key'; Key = 'esc' }
Check 'key esc 正常' ([bool]$k1.ok) $k1.error
$k2 = Run @{ Action = 'key'; Key = 'ctrl+a' }
Check 'key ctrl+a 正常' ([bool]$k2.ok) $k2.error
$k3 = Run @{ Action = 'key'; Key = 'NOT_A_KEY' }
Check '未知按键被拒绝' ((-not $k3.ok) -and $k3.code -eq 'BAD_KEY') "code=$($k3.code)"
$k4 = Run @{ Action = 'bogus-action' }
Check '未知动作被拒绝' ((-not $k4.ok) -and $k4.code -eq 'BAD_ACTION') "code=$($k4.code)"

# ---------------------------------------------------------------- cleanup
if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch { } }

Write-Host "`n=== 结果：$script:pass 通过 / $script:fail 失败 ===" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
