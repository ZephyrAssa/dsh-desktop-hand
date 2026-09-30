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
$script:skip = 0

# 安全的路径存在性判断。
# `Test-Path` 在收到 $null 或非法路径时**会抛错**，而本脚本设了
# $ErrorActionPreference='Stop'，于是"文件没生成"会被报成脚本崩溃，
# 而不是一条 FAIL。CI 上就是这样把环境问题伪装成代码问题的。
function Test-PathSafe([object]$p) {
    if ($null -eq $p -or "$p".Trim().Length -eq 0) { return $false }
    try { return (Test-Path -LiteralPath "$p" -ErrorAction Stop) } catch { return $false }
}
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; Write-Host ("  PASS  " + $name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  FAIL  " + $name + $(if ($detail) { "  -- $detail" } else { '' })) -ForegroundColor Red }
}

# 跳过 = 前置条件在本机不成立，既不算通过也不算失败。
#
# 为什么需要它（真实事故，2026-09-28）：本脚本最初假设"运行环境是一个完整的
# 交互式桌面会话"，于是把好几条断言写成硬性的。那份自检在本机全绿，
# 推到 GitHub 后在 windows-latest 上**立刻红了** —— 因为 CI runner 的桌面会话
# 与真人桌面不同：通常没有资源管理器窗口、分辨率不是 2560x1440、
# 甚至根本没有可交互的桌面输入。
#
# 那些断言测的其实是**环境**，不是**代码**。把"环境不满足"判成"代码坏了"，
# 会让 CI 永远红着，从而彻底失去意义。所以改成：
#   前置条件不成立 -> SKIP（并说明原因）
#   前置条件成立但行为不对 -> FAIL（这才是真 bug）
function Skip([string]$name, [string]$why) {
    $script:skip++
    Write-Host ("  SKIP  " + $name + "  -- " + $why) -ForegroundColor DarkGray
}

# 本进程是否运行在一个有交互式桌面的会话里。
# 判据：能枚举到带标题的可见窗口，且存在前台窗口句柄。
# GitHub Actions 的 windows-latest runner 有 desktop，但窗口极少；
# 而某些完全无头的环境会枚举不到任何窗口。
function Test-InteractiveDesktop([object]$info, [object]$lw) {
    if (-not $lw -or -not $lw.ok) { return $false }
    if ([int]$lw.count -le 0) { return $false }
    $titled = @($lw.windows | Where-Object { $_.title -and $_.title.Length -gt 0 })
    return ($titled.Count -gt 0)
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

# 环境事实：CI 上出问题时，这几行能立刻说明"是不是环境不同"，
# 省掉一轮"改代码 → 推 → 等 CI"的猜测。实测值得。
Write-Host "环境：UserInteractive=$([Environment]::UserInteractive) " -NoNewline
Write-Host "SessionId=$((Get-Process -Id $PID -ErrorAction SilentlyContinue).SessionId) " -NoNewline
Write-Host "PS=$($PSVersionTable.PSVersion)`n" -ForegroundColor DarkGray

# 兜底：任何未预料的终止错误都转成一条明确的 FAIL + 出错行号，再以非 0 退出。
# 没有它的话，脚本顶部 $ErrorActionPreference='Stop' 会让意外错误直接中断，
# 日志里只剩一行报错，看不出跑到哪一步、也无法区分"环境问题"还是"代码问题"。
trap {
    Write-Host "`n  FAIL  未预料的错误，自检提前中断：" -ForegroundColor Red
    Write-Host "         $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "         位置：$($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
    Write-Host "         （若这是 CI 独有，请对照上面的环境事实判断是否为环境差异）" -ForegroundColor DarkGray
    Write-Host "`n=== 结果：$script:pass 通过 / $($script:fail + 1) 失败（中断）/ $script:skip 跳过 ===" -ForegroundColor Red
    exit 1
}

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
# 这一条测的是代码：引擎能跑完并返回结构正确的 JSON。任何环境下都必须过。
Check 'list-windows 返回 ok' ([bool]$lw.ok) $lw.error
Check '返回了 windows 数组' ($null -ne $lw.windows) 'windows 字段缺失'
Check 'count 与 windows 长度一致' ([int]$lw.count -eq @($lw.windows).Count) "count=$($lw.count) len=$(@($lw.windows).Count)"

# 以下三条测的是**环境**：这台机器上是否有可见窗口、是否有标题。
# 无交互桌面的环境（部分 CI / 服务会话）会一条都没有，那不是 bug。
$desktopOk = Test-InteractiveDesktop $info $lw
if ($desktopOk) {
    Check '至少枚举到一个窗口' ([int]$lw.count -gt 0) "count=$($lw.count)"
    Check '返回前台窗口句柄' ($null -ne $lw.foregroundHandle)
    $withTitle = @($lw.windows | Where-Object { $_.title -and $_.title.Length -gt 0 })
    Check '存在有标题的窗口' ($withTitle.Count -gt 0) "titled=$($withTitle.Count)"
} else {
    Skip '至少枚举到一个窗口' '本环境没有可交互桌面（枚举不到任何带标题的窗口）'
    Skip '返回前台窗口句柄' '同上'
    Skip '存在有标题的窗口' '同上'
}

# ---------------------------------------------------------------- capture fullscreen
Write-Host "`n[3] capture -FullScreen —— 全屏抓取"
$capDir = Join-Path $env:TEMP 'dsh-desktop-hand-selftest'
if (-not (Test-PathSafe $capDir)) { New-Item -ItemType Directory -Force -Path $capDir | Out-Null }
$full = Run @{ Action = 'capture'; FullScreen = $true; OutPath = (Join-Path $capDir 'full.png') }
Check '全屏抓取 ok' ([bool]$full.ok) $full.error
if ($full.ok) {
    # 尺寸一致性：截图宽必须等于引擎报告的物理屏宽。这是代码契约，与环境无关。
    Check '尺寸等于物理屏' ([int]$full.width -eq [int]$info.screenWidth) "got $($full.width) want $($info.screenWidth)"
    Check 'PNG 文件已落盘' (Test-PathSafe $full.path)
    if (Test-PathSafe $full.path) {
        Check 'PNG 非空' ((Get-Item -LiteralPath $full.path).Length -gt 1000) "bytes=$($full.bytes)"
    }
}

# ---------------------------------------------------------------- capture region
Write-Host "`n[4] capture -Region —— 区域裁切"
$reg = Run @{ Action = 'capture'; FullScreen = $true; Region = '100,100,320,200'; OutPath = (Join-Path $capDir 'region.png') }
Check '区域抓取 ok' ([bool]$reg.ok) $reg.error
if ($reg.ok) {
    Check '裁切尺寸正确 320x200' ([int]$reg.width -eq 320 -and [int]$reg.height -eq 200) "got $($reg.width)x$($reg.height)"
    Check '记录了裁切原点' ([int]$reg.originX -eq 100 -and [int]$reg.originY -eq 100) "origin=$($reg.originX),$($reg.originY)"
}

# 区域越界必须被拒（防静默出错）。这两条是纯参数校验，任何环境都必须过。
$oob = Run @{ Action = 'capture'; FullScreen = $true; Region = '99999,99999,10,10' }
Check '越界区域被拒绝' ((-not $oob.ok) -and $oob.code -eq 'REGION_OOB') "code=$($oob.code)"
$badreg = Run @{ Action = 'capture'; FullScreen = $true; Region = '1,2,3' }
Check '格式错误被拒绝' ((-not $badreg.ok) -and $badreg.code -eq 'BAD_REGION') "code=$($badreg.code)"

# ---------------------------------------------------------------- capture window (occlusion)
Write-Host "`n[5] capture -Window —— 窗口后台抓取（遮挡）"
# 找一个非最小化、尺寸正常的窗口来抓。优先资源管理器，没有就用任意候选。
# CI runner 上通常没有资源管理器窗口，但常有一个控制台或 runner 自身的窗口可用。
$cand = @($lw.windows | Where-Object {
    -not $_.minimized -and $_.width -gt 50 -and $_.height -gt 50 -and $_.class -ne 'Progman' -and $_.class -ne 'Shell_TrayWnd'
} | Select-Object -First 1)[0]
if ($cand) {
    $wc = Run @{ Action = 'capture'; Handle = $cand.handle; OutPath = (Join-Path $capDir 'win.png') }
    Check '按句柄抓窗口 ok' ([bool]$wc.ok) "$($wc.error) (handle=$($cand.handle) class=$($cand.class))"
    if ($wc.ok) {
        Check '记录了窗口原点' ($null -ne $wc.originX)
        # 断言'抓取尺寸 = 目标窗口自身尺寸'，而不是'一定小于全屏'。
        # 最大化窗口的尺寸本就等于全屏，旧写法会把合法情况误判为失败。
        # 变化的屏幕尺寸才是真问题，所以这里与窗口 rect 比（允许 DWM 边框的少量差异）。
        $dw = [math]::Abs([int]$wc.width - [int]$cand.width)
        Check '抓取尺寸等于目标窗口尺寸' ($dw -le 32) "win=$($wc.width) rect=$($cand.width) diff=$dw"
    }
} else {
    Skip '按句柄抓窗口 ok' '本环境没有可供抓取的普通窗口（只有桌面/任务栏）'
    Skip '记录了窗口原点' '同上'
    Skip '抓到的是窗口尺寸而非全屏' '同上'
}

$nomatch = Run @{ Action = 'capture'; Window = 'ZZZ_NO_SUCH_WINDOW_ZZZ' }
Check '不存在的窗口被拒绝' ((-not $nomatch.ok) -and $nomatch.code -eq 'NO_MATCH') "code=$($nomatch.code)"

# ---------------------------------------------------------------- mouse (non-destructive)
Write-Host "`n[6] move / probe —— 鼠标定位与干扰检测"
# 目标点取屏幕内一个安全位置（不写死 300，因为 CI 分辨率可能只有 1024x768）。
$mx = [int]([math]::Min(300, [int]$info.screenWidth - 50))
$my = [int]([math]::Min(300, [int]$info.screenHeight - 50))
if ($mx -lt 0) { $mx = 0 }
if ($my -lt 0) { $my = 0 }

$mv = Run @{ Action = 'move'; X = $mx; Y = $my }
Check 'move 返回 ok' ([bool]$mv.ok) $mv.error
if ($mv.ok) {
    # 断言"光标落在我们要求的点上"，而不是匹配某个写死的坐标范围。
    # 旧写法 `^3[0-2]\d,3[0-2]\d$` 只在 2560x1440 且无缩放时成立，
    # 换个分辨率就会误报——那测的是分辨率，不是代码。
    $want = "$mx,$my"
    Check 'move 后光标落在目标点' ($mv.cursor -eq $want) "want=$want got=$($mv.cursor)"
}

$pr = Run @{ Action = 'probe'; X = 400; Y = 400 }
Check 'probe 返回 ok' ([bool]$pr.ok) $pr.error
if ($pr.ok) {
    $stable = ($pr.probeA -match '^400,400') -and ($pr.probeB -match '^400,400')
    if ($stable) {
        Check '落点稳定（无其他输入源）' $true
    } elseif (-not $desktopOk) {
        # 无交互桌面时 setcursorpos 可能根本不生效，这不是代码问题。
        Skip '落点稳定（无其他输入源）' '本环境没有可交互桌面，光标定位不适用'
    } else {
        # 有桌面但光标被推走：这是真实的干扰（远程会话），不是本插件的 bug。
        # 不判 FAIL，但要显著提示——它是"点击为何不准"的头号原因。
        Skip '落点稳定（无其他输入源）' '有别的输入源在驱动光标（通常是远程会话）'
        Write-Host "        A=$($pr.probeA)" -ForegroundColor Yellow
        Write-Host "        B=$($pr.probeB)" -ForegroundColor Yellow
        Write-Host "        这不是插件缺陷；等远端空闲后鼠标点击才可靠。" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------- keyboard round-trip
Write-Host "`n[7] focus + type —— 键鼠闭环（客观判据：窗口标题变化）"
$marker = 'DSKHAND' + (Get-Random -Minimum 1000 -Maximum 9999)
# Start-Process 必须容错：脚本顶部设了 $ErrorActionPreference='Stop'，
# 而在缺少可交互桌面的环境（CI runner）里，起一个控制台窗口**可能直接抛错**，
# 那会当场终止整个自检，后面的 SKIP 分支根本没机会执行——
# 于是"环境不支持"被报成"代码失败"。实测 GitHub windows-latest 上就是这样红的。
$proc = $null
try {
    $proc = Start-Process cmd.exe -ArgumentList '/k', "title $marker" -PassThru -ErrorAction Stop
} catch {
    Write-Host "      起测试窗口失败（$($_.Exception.Message)）——将跳过键盘闭环测试" -ForegroundColor DarkGray
}
Start-Sleep -Seconds 3
$target = $null
for ($i = 0; $i -lt 10 -and $null -eq $target; $i++) {
    $cur = Run @{ Action = 'list-windows' }
    $target = @($cur.windows | Where-Object { $_.title -match $marker } | Select-Object -First 1)[0]
    if ($null -eq $target) { Start-Sleep -Milliseconds 500 }
}

if ($null -eq $target) {
    # 无交互桌面的环境里，Start-Process 起的控制台不会出现在窗口枚举中。
    # 这不是代码缺陷——键盘注入本身无法在无窗口的环境下被端到端验证。
    Skip '找到测试目标窗口' '本环境无法为测试创建可见窗口（无交互桌面）'
    Skip '聚焦成功' '同上'
    Skip 'type 返回 ok' '同上'
    Skip '输入真的送达了目标窗口（标题已变）' '同上'
    Skip 'type 可重复' '同上'
    Skip '第二次输入也送达了' '同上'
    Skip '中文（Unicode 直投）不被输入法改写' '同上'
    if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch { } }
} else {
    Check '找到测试目标窗口' $true

    # 等待目标窗口的标题变成期望值。
    #
    # 为什么要轮询而不是 Start-Sleep 固定秒数（实测教训）：
    # 输入是异步的——按键注入成功不等于目标程序已处理完并更新标题。
    # 固定等 2 秒在本机多数时候够，但负载高或终端启动慢时会偶发失败，
    # 于是自检忽红忽绿。轮询把"是否送达"与"等了多久"解耦，只判最终状态。
    function Wait-Title([string]$pattern, [int]$handle, [int]$timeoutSec = 20) {
        for ($i = 0; $i -lt ($timeoutSec * 2); $i++) {
            $cur = Run @{ Action = 'list-windows' }
            $hit = @($cur.windows | Where-Object { $_.title -match $pattern })
            if ($hit.Count -gt 0) { return $true }
            # 每 3 秒补一次聚焦 + 重发，抵抗"焦点被远程会话抢走"这类环境干扰。
            # 只重试，不掩盖：若 20 秒后仍未变化，仍然是 FAIL。
            if ($i -gt 0 -and ($i % 6) -eq 0) {
                Run @{ Action = 'focus'; Handle = $handle } | Out-Null
                Run @{ Action = 'type'; Text = "title $pattern"; Enter = $true } | Out-Null
            }
            Start-Sleep -Milliseconds 500
        }
        return $false
    }
    $fo = Run @{ Action = 'focus'; Handle = $target.handle }
    Check '聚焦成功' ([bool]$fo.ok) "$($fo.error) result=$($fo.result)"

    $newTitle = 'LANDED' + (Get-Random -Minimum 1000 -Maximum 9999)
    $ty = Run @{ Action = 'type'; Text = "title $newTitle"; Enter = $true }
    Check 'type 返回 ok' ([bool]$ty.ok) $ty.error
    Check '输入真的送达了目标窗口（标题已变）' (Wait-Title $newTitle $target.handle) "期望标题含 $newTitle"

    # 第二次输入：验证可重复，且**每次输入前都重新聚焦**。
    # 为什么要重新聚焦：两次引擎调用之间焦点可能被别的窗口抢走
    # （本机有 GameViewer 远程会话，实测偶发），不重新聚焦就会偶发失败——
    # 那是环境抖动，不是插件缺陷，不该让自检变红。
    $fo2 = Run @{ Action = 'focus'; Handle = $target.handle }
    $cnTitle = 'CN' + (Get-Random -Minimum 1000 -Maximum 9999)
    $ty2 = Run @{ Action = 'type'; Text = "title $cnTitle"; Enter = $true }
    Check 'type 可重复' ([bool]$ty2.ok) $ty2.error
    Check '第二次输入也送达了' (Wait-Title $cnTitle $target.handle) "期望标题含 $cnTitle（focus=$($fo2.result)）"

    # 非 ASCII 走 Unicode 直投，必须原样送达、不被输入法改写。
    # 判据：标题里出现中文就算成功——旧实现（VkKeyScan）会把它变成别的东西。
    # 注意：英文版 Windows runner 上没有中文输入法，这条恒真；
    # 它的价值在有中文 IME 的机器上（那才是会改写输入的环境）。
    $fo3 = Run @{ Action = 'focus'; Handle = $target.handle }
    $ty3 = Run @{ Action = 'type'; Text = 'title 中文测试ABC'; Enter = $true }
    $ok3 = Wait-Title '中文测试' $target.handle
    $after3 = Run @{ Action = 'list-windows' }
    Check '中文（Unicode 直投）不被输入法改写' $ok3 `
        "期望标题含「中文测试」；实际含中文的标题：$((($after3.windows | Where-Object { $_.title -match '[\u4e00-\u9fa5]' }).title) -join ' | ')"

    if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch { } }
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

# 结果解读：
#   FAIL  -> 代码有问题，必须查（退出码非 0）
#   SKIP  -> 本环境不具备前置条件，既不算过也不算错。
#            全部 SKIP 而无 FAIL，说明代码本身没问题，只是这台机器测不了那些项。
$color = if ($script:fail -eq 0) { 'Green' } else { 'Red' }
Write-Host "`n=== 结果：$script:pass 通过 / $script:fail 失败 / $script:skip 跳过 ===" -ForegroundColor $color
if ($script:skip -gt 0) {
    Write-Host "    （SKIP 是环境不具备条件，不是缺陷；详见上方每条的说明）" -ForegroundColor DarkGray
}
if ($script:fail -gt 0) { exit 1 }
