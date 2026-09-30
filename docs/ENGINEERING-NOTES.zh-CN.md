# dsh-desktop-hand

> **English readers:** this is the detailed engineering log kept in the language it
> was written in. It records every bug hit during development, the measurement that
> identified each root cause, and the reused recipe. The English
> [`README.md`](../README.md) summarises the same findings.
>
> The machine referenced as "本机" is the author's Windows box:
> 2560x1440 at 150% scaling, PowerShell 5.1, with a remote-control tool running.
> Numbers in this document are from that machine.

---

给 DSH agent 装上**操作 Windows 桌面的手和眼睛**：截屏（含抓被遮挡的窗口）、按坐标点击、
注入键盘输入、聚焦窗口。装一次，**所有工作区、所有会话**都能用。

- 编写日期：2026-09-27；兼容性修复：2026-09-28（v1.0.1，适配 DSH 0.1.7-rc.2）
- 位置：本仓库根目录（原始位置是作者本机的 `DSH环境/dsh-desktop-hand/`）
- 自检：**136 项全过**（引擎 32 / 插件层 79 / seam 契约 18 / 遮挡抓取 7），遮挡抓取已看图确认
- 当前适配：DSH 0.9.2（harness `0.1.7-rc.2`）

---

## 零、升级兼容性（必读）

### 0.1 DSH 升级会删掉本地插件，升级后要重装

DSH 从 `0.1.5-rc.2` 升到 `0.1.7-rc.2`（Desktop 0.9.2）时，
`profiles/web/package.json` 被**重写**：`dependencies` 和 `dsh.profile.bundles` 里
本插件的条目被删掉了，但 `pnpm.overrides` 里的 `link:` 行**留了下来**（残留不一致状态）。

原因见 0.2：v1.0.0 让 DSH **启动失败**，DSH 于是进了安全模式并清理了配置。

**升级 DSH 后请检查这三处是否齐全**，缺就按第二节补回去再 `pnpm install`：

| 位置 | 应有内容 |
| --- | --- |
| `dependencies` | `"dsh-desktop-hand": "link:D:/Record/AIdatabase/09-杂项/DSH环境/dsh-desktop-hand"` |
| `dsh.profile.bundles` | 数组里有 `"dsh-desktop-hand"` |
| `pnpm.overrides` | 同 dependencies 的 `link:` 行 |

> ⚠️ 只有 `overrides` 而没有 `dependencies`/`bundles` 是**无效状态**：不会被加载。

### 0.2 v1.0.0 → v1.0.1 修的是什么（真实事故）

**症状**：升级 DSH 后启动失败，报

```
dsh: startup failed: 1 required plugin did not activate
  desktop-hand (required)
    TypeError: prompt section "tool:desktop-hand" order must be a finite number
```

**根因**：`systemPrompt.section()` 的 `order` 从"可选"变成了"必填且必须是有限数字"。

```js
// @deepseek-ai/dsh-system-prompt/lib/index.js:241  （0.1.7-rc.2）
section(section) {
  if (!Number.isFinite(section.order)) throw new TypeError(`prompt section "${section.name}" order must be a finite number`);
```

v1.0.0 调用时**没给 `order`**（旧版本容忍），升级后直接抛错。
又因为本插件在 profile 里是 `required: true`，**抛错会拖垮整个 DSH 启动**，
而不是仅仅少一段提示词。

**修复**（两处，缺一不可）：

1. 补上 `order: 3001`。取值依据 DSH 内部 `SECTION_ORDERS`：
   工具说明段排在 1000–3000（…`TOOL_REPORT: 2900`, `TOOL_COMPUTER_USE: 3000`,
   `MCP_SERVERS: 3100`），桌面控制属于 computer-use 一类，所以紧跟官方
   `TOOL_COMPUTER_USE` 之后、`MCP_SERVERS` 之前。那些常量未导出，故写死字面量。
2. **把整段 prompt section 包进 try/catch，失败只 warning 不抛出**。
   系统提示是锦上添花，6 个工具本身不依赖它——**绝不能让一段提示词把宿主带崩**。

**已加回归测试**（`selftest.mjs`，之后别删）：
断言 `order` 是有限数字、落在 3000–3100，并且**用一个必定抛错的假 `section()`
验证 `apply()` 仍然成功**。

**已用真实服务复现并验证**：拿 `dsh-system-prompt` 真实现跑一次，
不给 `order` 得到与启动日志**逐字相同**的错误；修好后 `Number.isFinite(3001)` 通过。

### 0.3 升级后如何快速自检

```powershell
$d = "<本仓库根目录>"
& "$d\lib\link-deps.ps1"          # 仅本地自检需要
& "$d\lib\selftest.ps1"           # 32 项
node "$d\lib\selftest.mjs"        # 79 项（含 order 回归）
node "$d\lib\selftest-harness.mjs"# 18 项（harness seam 契约）
& "$d\lib\occlusion-test.ps1"     # 7 项（需看图）
& "$d\lib\link-deps.ps1" -Clean
```

> 这四套都是**脱离 DSH** 跑的，所以升级后不用重启就能先确认插件本身没坏。
> 真正加载成功与否要看 DSH 能否正常启动（见 0.4）。

### 0.4 升级后确认"没把 DSH 带崩"

看启动日志（每次启动一个文件）：

```powershell
Get-ChildItem "$env:APPDATA\dsh-desktop\harness\logs\startup-*.log" |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -TotalCount 40
```

**只要日志里没有 `startup failed` / `required plugin did not activate` 就是好的。**
插件加载失败**必然会**写这个日志并进安全模式，不会静默。

---

## 一、为什么自己写，而不是装市场插件

**调研了 8 个能碰桌面的 DSH 插件，没有一个同时具备下面四项 + 遮挡抓取。**

| 插件 | 按标题抓窗口 | 坐标点击 | 键盘注入 | 窗口聚焦 | **抓被遮挡的窗口** | 后端 |
| --- | :-: | :-: | :-: | :-: | :-: | --- |
| **dsh-desktop-hand（本项目）** | ✅ | ✅ | ✅ | ✅ | ✅ **PrintWindow** | PowerShell |
| Altairpaca/dsh-computer-use-windows | ✅ | ✅ | ✅ | ✅ | ❌ **CopyFromScreen 裁矩形** | PowerShell |
| cbg33695/dsh-screen-reader | ✅ | ❌ | ❌ | ❌ | ✅ | PowerShell |
| @paicat1/dsh-screenshot | 仅悬停吸附 | ❌ | ❌ | ❌ | ✅ | PowerShell |
| 988hj7tczd-oss/dsh-computer-use | ✅ | ✅ | ✅ | ✅ | ⚠️ 未验证 | 外部二进制 |
| ysr666/dsh-vision-router | ❌ 仅虚拟屏 | ❌ | ❌ | ❌ | ❌ | PowerShell |
| ankye/dsh-client-vision | ✅ 按 id | ❌ | ❌ | ❌ | ❌ | PowerShell |
| FuqiangCraft/dsh-desktop | ❌ 仅主屏 | ❌ | ❌ | ❌ | ❌ | Rust/Tauri |

市场清晰地分成两半：

- **用了 PrintWindow（能抓遮挡）的，完全不碰输入**（screen-reader、dsh-screenshot）；
- **能注入输入的，抓窗口用的是 `CopyFromScreen` 裁窗口矩形**
  —— 窗口被盖住时抓到的是**遮挡者**的画面。

唯一"四项俱全"的 Altairpaca 插件，其 `helper/cu.ps1` 里是
`$g.CopyFromScreen($win.left, $win.top, 0, 0, $bmp.Size)`，整个文件**没有 PrintWindow**。
而 `988hj7tczd-oss/dsh-computer-use`（36★，架构最正规）的 README 明写
Windows **⛔ BLOCKED「当前无 Windows 10/11 真机；真实 GUI 未验收」**。

另外两个减分项：

- Altairpaca 插件的 `computer_keyboard type` 对非 ASCII **走剪贴板**——
  正是本机 AGENTS.md 记录的输入法风险点；本插件用 `SendInput + KEYEVENTF_UNICODE`，
  在这一点上严格更好。
- 现有本地脚本（`capture.ps1` / `mouse.ps1` / `type.ps1`）四项能力都覆盖且已实测，
  **但没有一个是插件**，所以别的会话/工作区用不到——这正是要补的缺口。

> **调研的置信度**：本次检索期间 `web_search`/SearXNG 不可用，本机 PowerShell 直连
> GitHub 也 TLS 失败，只能靠 `web_fetch` 走 DSH 通道。因此**不是**穷举注册表扫描，
> 可能仍有遗漏；但上表每一格结论都有 README 或源码原文支撑，未核实的一律标了 ⚠️。

**结论：自己写。** 不是重复造轮子，而是补上"能遮挡抓取"与"能注入输入"之间那个空缺的组合。

---

## 二、安装

插件已装进 `web` profile，**DSH 重启后生效**（bundle 列表在启动时读取）。
> ⚠️ **DSH 升级会清掉这三处配置**——升级后请按第零节检查并重装。

改动的三个地方（profile 目录即 `%APPDATA%\dsh-desktop\harness\profiles\web\`）：

| 文件 | 改动 |
| --- | --- |
| `package.json` → `dependencies` | `"dsh-desktop-hand": "link:D:/Record/AIdatabase/09-杂项/DSH环境/dsh-desktop-hand"` |
| `package.json` → `dsh.profile.bundles` | 追加 `"dsh-desktop-hand"` |
| `package.json` → `pnpm.overrides` | `"dsh-desktop-hand": "link:D:/Record/.../dsh-desktop-hand"` |

然后 `pnpm install --dir <profile>`（已执行）。用 `link:` 而不是拷贝，
**改插件源码后重启即生效，不用重装**。

### 手工安装（换机器时）

```powershell
# 1) 复制插件目录到新机器（路径随意，建议跟本机同构）
# 2) 在 profile 目录里加三处配置（见上表），再：
& "$env:APPDATA\dsh-desktop\harness\.desktop-bin\pnpm.cmd" install --dir "$env:APPDATA\dsh-desktop\harness\profiles\web"
# 3) 重启 DSH
```

> ⚠️ **不要同时用 bundle 通道和 profile 的 `cordis.patch.yml` 手工挂载行**——
> 两者都写会**双重挂载**，工具注册两次会报 "already registered" 而让整个 DSH 起不来。
> 本插件只用 bundle 通道，profile 的 `cordis.patch.yml` **不需要**动。

### 卸载

删掉上表三处配置 → `pnpm install` → 重启。备份在同目录 `package.json.bak-desktop-hand-*`。

---

## 三、工具

装好后 agent 会多出 6 个工具：

| 工具 | 说明 |
| --- | --- |
| `desktop_diagnose` | 体检：合成输入此刻可不可信（DPI / 屏幕 / 前台 / 输入法 / 远程软件 / 光标落点稳定性） |
| `desktop_list_windows` | 列可见窗口：handle、PID、进程、标题、位置尺寸、是否 UWP、是否最小化 |
| `desktop_capture` | 截屏：全屏 / 指定窗口（标题或 handle）/ 区域裁切。**图片直接返回给模型** |
| `desktop_focus` | 聚焦窗口（`SetForegroundWindow` + `AttachThreadInput` 兜底，并**报告是否真的成功**） |
| `desktop_click` | 点击 / 双击 / 右键 / 拖动，并**校验光标最终落点** |
| `desktop_type` | 输入文本（Unicode 直投）或发按键（白名单） |

典型流程：

```
desktop_list_windows            → 找到目标，拿 handle
desktop_capture(handle=...)     → 看图，量坐标
desktop_focus(handle=...)       → 或 desktop_click 点窗口体拿焦点
desktop_type(text="...")        → 输入
desktop_capture(handle=...)     → 再看图确认
```

---

## 四、四个关键设计（改动前必读）

### 1. 抓窗口用 `PrintWindow + PW_RENDERFULLCONTENT(2)`

这是本插件存在的理由。**只有它能抓到被遮挡窗口自己的内容**；全屏 `CopyFromScreen`
抓到的永远是遮挡者。`flag` 必须是 **2**：`flag=0` 对 UWP 是 100% 黑，`flag=2` 降到 71.7%。

实测对比见第六节第三项——同一时刻，全屏图只有遮挡者，窗口图是目标自己。

### 2. 键盘输入用 `SendInput + KEYEVENTF_UNICODE`

**不能用 `VkKeyScan` + `keybd_event`**：那走的是键盘布局/输入法通路，中文输入法会在中间
转换。实测想输入 `third batch`，目标程序收到的是「第三批」。
Unicode 直投绕过输入法，中文和 `%.15f` 都能原样送达。

### 3. 坐标一律物理像素，每层都声明 DPI 感知

本机 2560x1440 + 150% 缩放。不声明 DPI 感知时 `SetCursorPos(42,1046)` 会被系统乘 1.333
落到物理 (56,1395)，而 `GetCursorPos` 又除回去报 (1280,720)——表现是"点的位置和说的不一样"。
声明后 1:1 直达。截图结果里会给出 `coordScale`，不等于 1 时提示调用方换算。

### 4. 输出必须显式设成 UTF-8

PowerShell 5.1 在 stdout 被重定向时按**控制台 ANSI 代码页**（本机 GBK/936）编码输出。
Node 按 UTF-8 解码 → 中文错误信息全变乱码（实测踩到）。
所以引擎第一件事就是 `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`。
**这行删掉不会报错，只会让所有中文提示变乱码，很难查。**

### 附：走 harness 的 `ctx.subprocess` 而不是裸 `spawn`

官方插件都用 `ctx.subprocess.spawn`。这不只是风格：**DSH 沙箱会拒绝 node 以管道 stdio
起子进程**（实测裸 `spawn` 直接 `EPERM`，换 `stdio:'inherit'` 就能跑）。
本插件正式路径走 `ctx.subprocess`，裸 `spawn` 只作脱离 DSH 时的退路。

三个**读源码才定下来、否则会静默出错**的契约（已在 `lib/selftest-harness.mjs` 里断言）：

| 契约 | 踩坑后果 |
| --- | --- |
| `graceMs` 必填（`validateSubprocessSpec` 拒绝缺失） | 每次调用都抛错 |
| `handle.collected.stdout` 是**收集器对象**，要调 `finalize()` 才拿到 `{text}` | 直接读 `.text` 得到 `undefined`，所有工具都报"引擎无输出" |
| spec **没有** `timeoutMs` 字段，超时要自己用 `AbortController` | 超时机制失效 |

---

## 五、已知边界（不是 bug）

- **UWP 应用抓不到内容**（设置、计算器、Realtek Audio Console 等）。
  `PrintWindow` 对走 DirectComposition 渲染的 UWP 是硬盲区，无法绕过
  （WGC 可以，但需要 MSIX 打包身份，PowerShell 拿不到）。
  工具会返回 `uwpWarning`，此时**不要根据该图判断界面状态**。
- **窗口最小化时**尺寸退化，抓到的内容无意义（返回 `minimized: true`）。
- **活跃的远程会话会让鼠标点击不可靠**。本机装了 GameViewer，远端一动鼠标，
  合成坐标就被实时覆盖。这是环境问题，改代码/调坐标都没用——用 `desktop_diagnose`
  确认，等远端空闲即可。**不要杀 GameViewer 进程**，那会断掉远程回连通道。
- **只支持 Windows**（依赖 `user32`/`gdi32`/`shcore`）。

---

## 六、实测记录（2026-09-27 初测；2026-09-28 升级后复测）

### 1. 引擎自检 `lib/selftest.ps1` —— **32 项全过**

```
info（DPI=shcore:2, 2560x1440）、list-windows、全屏抓取、区域裁切、
越界/格式错误拒绝、窗口不存在拒绝、move、probe 落点稳定、
focus + type 闭环（标题真的变了）、输入可重复、中文直投、按键白名单、未知键/未知动作拒绝
```

其中 **focus → type → 读回窗口标题** 那一项是闭环验证：输入内容会改变目标窗口的标题，
所以"输入是否送达"有**客观判据**，不靠猜。

**中文那一项是升级后新加的**：往目标窗口标题里打 `中文测试ABC`，
再断言标题里真的出现「中文测试」。这直接验证了"Unicode 直投绕过输入法"这个设计——
如果退回到 `VkKeyScan`，标题里出现的会是别的东西（实测过 `third batch` → 「第三批」）。

### 2. 插件层自检 `lib/selftest.mjs` —— **79 项全过**

假 `ctx` + 真引擎：6 个工具全部注册、schema 合法（含"每个参数都有 description"）、
每个工具的主路径实跑成功、返回值经 `output.schema` 校验无多余键、
6 条错误路径全部正确抛错。

### 3. 插件 × harness `ctx.subprocess` 契约自检 `lib/selftest-harness.mjs` —— **18 项全过**

用忠实模拟 seam（会像真实现一样**拒绝缺失 `graceMs`**、且 `collected.stdout`
**只提供 `finalize()`**）跑通全部工具，把第四节附表中那三个静默出错的契约钉死。

### 4. 遮挡抓取验证 `lib/occlusion-test.ps1` —— **7 项全过 + 看图确认**

造场景：目标 cmd 窗口（标题 `OCCL_38271`，内容 `OCCL_38271 CONTENT LINE`）
被另一个最大化的 cmd 窗口（`BLOCKER_47478`）**完全盖住**，同一时刻两种抓法对比：

| 抓法 | 结果 |
| --- | --- |
| 全屏 `CopyFromScreen` | 2560x1440，**只有 `BLOCKER_47478`**，目标完全不可见 |
| 指定窗口 `PrintWindow` | 1115x628，**`OCCL_38271` 的标题栏与 `CONTENT LINE` 清晰可见** |

**这是本插件相对市场插件的核心差异，已用图像证据确认。**

### 5. 开发期真实踩到并修掉的 bug

| 现象 | 根因 | 修法 |
| --- | --- | --- |
| PS 语法错误 `Unexpected token '$('` | 双引号字符串里的中文全角引号 `“ ”` 被 PS 当字符串定界符 | 换直引号 |
| `无效的表达式项"uint"` | PS 5.1 的 CodeDom 编译器不支持 C# 7 的 `out uint _` | 提前声明变量 |
| `不安全代码只会在使用 /unsafe` | `Add-Type` 在 PS 5.1 下无法传 `/unsafe` | 改用 `GetPixel` 粗采样 |
| `找不到入口点 ReleaseDC2` | DllImport 名写错（应为 `ReleaseDC`） | 修正 |
| `Cannot find type [DSKHand.RECT]` | 嵌套类型引用写法错（应为 `DSKHand.Api+RECT`） | 修正 |
| 中文错误信息全是乱码 | PS 5.1 重定向 stdout 用 GBK 编码 | 显式设 `OutputEncoding=UTF8` |
| `spawn EPERM` | DSH 沙箱禁止 node 管道 stdio 起子进程 | 走 `ctx.subprocess` seam |
| `graceMs` 缺失抛错 | 读源码发现它是必填 | 补上 |
| 引擎输出读不到 | `collected.stdout` 是收集器，要 `finalize()` | 修正 |
| 分三次调用测不出键盘闭环 | 两次 pwsh 调用之间焦点被收回、目标窗口被关 | 改成单进程内一次做完 |
| **升级后 DSH 起不来** | `section()` 的 `order` 由可选变必填（0.1.7-rc.2），插件没传 | 补 `order: 3001` + 整段 try/catch（见第零节） |
| 自检偶发"输入未送达" | 两次引擎调用之间焦点被抢（远程会话），测试没重新聚焦 | 每次 type 前重新 focus；顺带补了真正的中文输入测试 |

> 方法论沿用 AGENTS.md：**因果推断必须实测验证**。
> 上面每一条都是先有实测现象、再定位根因，没有一条是靠"读代码觉得应该没问题"下结论的。
>
> 最后一条尤其说明问题：**"偶发失败"要先怀疑测试本身，再怀疑被测代码。**
> 当时同时改了测试（每次重新聚焦）和自检项（补真正的中文断言），跑两轮确认稳定。

---

## 七、文件

```
dsh-desktop-hand/
├── package.json              插件清单（dsh.bundle.patch 是加载的关键字段）
├── cordis.patch.yml          bundle 挂载声明
├── README.md                 本文档
├── skills/desktop-hand/
│   └── SKILL.md              给 agent 的用法 skill（已装到 ~/.dsh/skills/）
└── lib/
    ├── index.js              Node 工具层：6 个 defineTool + 附件图片返回
    ├── desktop-hand.ps1      PowerShell 引擎：窗口枚举/抓取/鼠标/键盘
    ├── selftest.ps1          引擎自检（32 项）
    ├── selftest.mjs          插件层自检，假 ctx + 真引擎（79 项，含 order 回归）
    ├── selftest-harness.mjs  × harness subprocess seam 契约自检（18 项）
    ├── occlusion-test.ps1    遮挡抓取专项验证（7 项 + 看图）
    └── link-deps.ps1         为本地自检建/清 peer 依赖 junction
```

跑自检（`selftest.mjs` / `selftest-harness.mjs` 需要先建依赖链接）：

```powershell
$d = "<本仓库根目录>"
& "$d\lib\link-deps.ps1"                                  # 仅本地自检需要
& "$d\lib\selftest.ps1"                                   # 30 项
node "$d\lib\selftest.mjs"                                # 72 项
node "$d\lib\selftest-harness.mjs"                        # 18 项
& "$d\lib\occlusion-test.ps1"                             # 7 项（需肉眼看图确认）
& "$d\lib\link-deps.ps1" -Clean                           # 跑完清理
```

> 遮挡验证脚本会在屏幕上短暂开两个 cmd 窗口并最大化其中一个，跑完自动关闭。

---

## 八、配置项

在 profile 里给 `desktop-hand` 传 config（一般不用改）：

| 键 | 默认 | 说明 |
| --- | --- | --- |
| `enginePath` | 包内 `lib/desktop-hand.ps1` | 引擎脚本路径 |
| `timeoutMs` | `60000` | 单次调用超时（冷启动要编译 Add-Type，首次约 1.2s） |
| `outputDir` | 系统临时目录 | 截图默认落盘目录 |

---

## 九、与 `DSH环境/脚本/` 下旧脚本的关系

旧的 `capture.ps1` / `mouse.ps1` / `type.ps1` **仍然可用**，本插件是它们的插件化封装：

- 逻辑与实测结论**一致**（PrintWindow / Unicode 直投 / DPI 感知 / 黑像素不可作判据）；
- 本插件额外做了：坐标落点校验、错误码与可操作提示、图片直接返回模型、
  全局可用、参数错误提前拒绝。

**新任务优先用 `desktop_*` 工具**；旧脚本保留作为不依赖 DSH 时的命令行工具。
