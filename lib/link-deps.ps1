<#
.SYNOPSIS
    为本地自检准备 peer 依赖（建 junction），或清理它们。

.DESCRIPTION
    插件本身**不需要**这个脚本：装进 profile 后，peer 依赖
    （@deepseek-ai/dsh-tools 等）由 DSH 在运行时提供。

    但 `selftest.mjs` / `selftest-harness.mjs` 想要**脱离 DSH** 单独跑，
    就得能解析到那几个包。这个脚本在插件目录下建 `node_modules\@deepseek-ai\*`
    的 junction 指过去，仅供自检使用；跑完可以 -Clean 删掉，
    避免它和 profile 的解析混在一起造成误解。

.EXAMPLE
    .\link-deps.ps1
    建好依赖链接，然后就能跑 node lib/selftest.mjs。

.EXAMPLE
    .\link-deps.ps1 -Clean
    删掉链接。
#>
[CmdletBinding()]
param([switch]$Clean)

$ErrorActionPreference = 'Stop'

$pluginDir = Split-Path $PSScriptRoot -Parent          # 插件根目录
$nm = Join-Path $pluginDir 'node_modules'
$target = Join-Path $nm '@deepseek-ai'

if ($Clean) {
    if (Test-Path $nm) { Remove-Item $nm -Recurse -Force; Write-Host "已删除 $nm" -ForegroundColor Yellow }
    else { Write-Host "没有需要清理的 $nm" }
    return
}

# peer 依赖的来源：优先 profile，其次 DSH 安装目录
$profileDir = Join-Path $env:APPDATA 'dsh-desktop\harness\profiles\web\node_modules\@deepseek-ai'
$appDir = 'D:\Programs\DSH\DSH Desktop\resources\app\node_modules\@deepseek-ai'

$roots = @($profileDir, $appDir) | Where-Object { Test-Path $_ }
if ($roots.Count -eq 0) {
    throw "找不到任何 @deepseek-ai 包目录。自检需要它们；插件在 DSH 里运行时不需要。"
}

New-Item -ItemType Directory -Force -Path $target | Out-Null

foreach ($pkg in @('schemastery', 'dsh-tools', 'cordis')) {
    $src = $null
    foreach ($r in $roots) {
        $cand = Join-Path $r $pkg
        if (Test-Path $cand) { $src = $cand; break }
    }
    if (-not $src) { Write-Host "  跳过 $pkg（未找到）" -ForegroundColor Yellow; continue }

    $link = Join-Path $target $pkg
    if (Test-Path $link) { Remove-Item $link -Force -Recurse }
    New-Item -ItemType Junction -Path $link -Target $src | Out-Null
    Write-Host "  链接 $pkg -> $src" -ForegroundColor Green
}

Write-Host "`n就绪。跑自检：" -ForegroundColor Cyan
Write-Host "  node `"$PSScriptRoot\selftest.mjs`""
Write-Host "  node `"$PSScriptRoot\selftest-harness.mjs`""
Write-Host "跑完可用 .\link-deps.ps1 -Clean 清理。" -ForegroundColor DarkGray
