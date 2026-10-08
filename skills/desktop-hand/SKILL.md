---
name: desktop-hand
description: 操作 Windows 桌面：截屏（含抓被遮挡窗口）、按坐标点击、注入键盘输入、聚焦窗口。当任务需要看屏幕、点界面、往别的程序里打字、或说"帮我操作那个软件/窗口"时使用。触发词：截屏、截图、看屏幕、点一下、鼠标、键盘输入、操作窗口、后台抓窗口、desktop。
---

# 操作 Windows 桌面（dsh-desktop-hand）

用 `desktop_*` 系列工具。**不要现写 PowerShell 截屏/点击代码** —— 那些坑已经在工具里填好了。

> **找不到 `desktop_*` 工具？** 说明插件没加载。DSH **升级会清掉 profile 里的本地插件**，
> 需要重装。排查与重装步骤见插件自带的 `docs/COMPATIBILITY.md`（仓库 README 也指向它）。
> 这是已知会反复发生的事，别花时间怀疑插件本身坏了。

## 工具

| 工具 | 用途 |
| --- | --- |
| `desktop_diagnose` | **体检**：合成输入可不可信。点不准时第一个跑它 |
| `desktop_list_windows` | 列窗口（handle / 进程 / 标题 / 尺寸 / 是否 UWP / 是否宿主壳 / 是否最小化） |
| `desktop_capture` | 截屏。**图片直接返回给你**，不用再 read_image |
| `desktop_focus` | 把窗口拉到前台 |
| `desktop_click` | 按坐标点击 / 双击 / 右键 / 拖动 |
| `desktop_type` | 输入文本（Unicode，绕过输入法）或发按键 |

## 标准流程

1. `desktop_list_windows` 找到目标，拿 `handle` 或完整标题。
2. `desktop_capture` 看图，确认界面状态、量出要点哪里。
3. `desktop_focus`（或直接 `desktop_click` 点窗口体）拿焦点。
4. `desktop_type` 输入；`desktop_click` 点按钮。
5. **再 `desktop_capture` 看图确认结果**。不要凭"工具返回 ok"就断定成功。

## 四条硬规则

**1. 抓窗口用 `window`/`handle`，不要抓全屏 —— 除非你要看屏幕上真实可见的东西。**
`desktop_capture` 抓窗口走 `PrintWindow`，**窗口被完全遮挡也能抓到它自己的内容**；
抓全屏只能抓到遮挡者。实测对比（同一时刻）：
- 全屏 → 只看到盖在上面的那个窗口
- 指定窗口 → 看到目标窗口自己的标题栏和内容

**2. 看图和点图必须用同一张图。** `desktop_capture` 结果里的 `width` 若与屏幕物理宽不一致，
把该图的 `width` 作为 `shotWidth` 传给 `desktop_click`。图中像素坐标直接可用（1:1）。

**3. 别用黑像素比例判断抓取成功。必须看图。**
实测反例（2026-10-03，本机逐项复核）：**黑像素比例与"是不是空白"是反的**——
`ApplicationFrameWindow` 空白壳只有 **16‰**，而 SystemSettings 的**真内容反而 617‰**（深色主题）。
所以永远不能拿它当判据。

**UWP 不是盲区，`ApplicationFrameWindow` 宿主壳才是。** 这是曾经的文档错误，
已实测推翻，不要再照旧说法放弃一个本来能抓的窗口：

| 窗口类名 | 结果 |
| --- | --- |
| `Windows.UI.Core.CoreWindow`（UWP 真实 XAML 窗口） | **完整真实内容**，可抓 |
| `ApplicationFrameWindow`（AFH 宿主壳） | 空白框架，零可操作信息 |

抓 UWP 应用的正确做法：
1. 先 `desktop_list_windows`；**同一标题出现多个句柄**时，
   优先抓**没有 `[UWP-宿主/可能空白]` 标记**的那个。
2. `uwpWarning` 现在**按实测空白度触发**（`distinctColors` 极少 + 主导色占比极高），
   可以信任：实测空白壳 `distinctColors=17`，真内容 `173`。
   看到它就换另一个句柄重抓，别据此判断界面状态。
3. 判据始终是**图里有没有 UI 内容**，不是进程名、也不是"是不是 UWP"。
4. 都抓不到才退回全屏抓取（要求窗口可见），而不是判定该应用不可抓。

**4. 点不准 / 输入丢失 → 先跑 `desktop_diagnose`，不要调代码。**
本机装了 GameViewer 远程串流。**远端有人在动鼠标时，合成坐标会被实时覆盖**，
点哪儿都不对——这是环境问题，改坐标没用，等远端空闲即可。
`desktop_diagnose` 会连采两次光标落点：稳定=可用；持续漂移=有别的输入源。

## 常见的坑

- **输入前必须让目标窗口在前台**，否则输入会丢到别处。
  `desktop_focus` 失败（前台锁）时，改用 `desktop_click` 在窗口体上点一下——
  真实点击能拿到激活，`SetForegroundWindow` 会被前台锁挡掉。
- **文本走 `SendInput + KEYEVENTF_UNICODE`**，绕过输入法。中文、`%.15f` 都能原样送达。
  （旧方式 `VkKeyScan` 会被中文输入法转换：实测想打 `third batch` 变成「第三批」。）
- **`desktop_type` 会报告输入送达时的前台窗口**。如果那不是你预期的目标，说明焦点不对。
- **窗口标题会变**（比如终端改标题），所以优先用 `handle`，且用完即弃、需要时重新 list。
- 标题模糊匹配到多个窗口时工具**会报错并列出候选**，不会擅自选一个——这时改用 `handle`。
- Win11 任务栏图标**居中**，开始按钮不在左下角。不要猜任务栏坐标，裁出来量。

## 与浏览器自动化的分工

网页内的操作用 `pilot_*`（走 CDP，不碰光标和焦点，不受远程串流影响），**优先**。
`desktop_*` 用于：非浏览器程序（MATLAB、Keil、各种桌面软件）、
或需要看整个屏幕 / 浏览器窗口之外的东西。
