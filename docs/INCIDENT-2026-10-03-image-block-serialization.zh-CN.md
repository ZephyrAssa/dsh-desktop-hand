# 故障报告：`desktop_capture` 图片块无法通过 JSON 物化

> **English summary (read this first).** On 2026-10-03 every `desktop_capture` call
> failed with `tool result must be losslessly JSON-serializable`, even though the PNG
> was written correctly. The cause was `finalizeContent` being written as `async`,
> while the contract requires a synchronous `ContentBlock[] | undefined` and the
> caller (`dsh-tools/lib/index.js:3402`) does not `await` it — so a Promise reached
> the strict JSON validator. Fixed by making the hook synchronous and moving the
> async image work into `execute()`. See
> [COMPATIBILITY.md §7.5](./COMPATIBILITY.md#75-bug-three--an-async-finalizecontent-and-why-review-misses-it)
> for the general lesson, and `docs/evidence/` for the supporting screenshots.
>
> This document is the **original investigation, preserved as written** — including
> the first-pass conclusions it later overturns. The "⚠️ 阅读本文档前必读" block below
> is the author's own correction notice. Kept because §2.2 identifies an **upstream**
> reporting gap that is still unfixed (verified 2026-10-09: `snapshotProjection` is
> applied to `render` at `:3552` and `presentationMeta` at `:3561`, but still **not**
> to `finalizeContent`).
>
> 报告日期：2026-10-03
> 插件：`dsh-desktop-hand`（源：`<repo root>`）
> 状态：**已定位根因并修复，已实测验证通过**
>
> ## ⚠️ 阅读本文档前必读
>
> ### 真正根因（已确认，与初版结论无关）
>
> **`finalizeContent` 被写成了 `async`，而官方契约要求它同步返回数组。**
>
> `applyFinalContent`（`dsh-tools/lib/index.js:3399-3407`）**不 await** 这个调用：
>
> ```js
> const content = finalizeContent(exec, result);   // 同步取值，没有 await
> return { ...result, content: snapshotProjection(exec.name, "finalizeContent", content) };
> ```
>
> 于是 `content` 是一个 **Promise**。Promise 不是 plain object，`snapshotJsonValue`
> 对它返回 `undefined`，`materializePresentation` 在 `:2608` 抛出
> `TypeError: tool result must be losslessly JSON-serializable`，
> 而 `finishScheduledExecution`（`:3392-3394`）把**整个成功的返回值连同渲染好的截图文本
> 一起替换成这个错误**——症状正是「PNG 落盘正确但工具报错」。
>
> 权威契约（`dsh-tool-cordis/lib/types/api-catalog.js:7416`）写得很明确：
> `finalizeContent?(exec, result): ContentBlock[] | undefined`——**没有 Promise**。
>
> **为什么初版复核会误判「block 是干净的」**：任何先把返回值 `await` 一遍的实验
> 都会通过。只有走真实的、未 await 的 `:3402` 那条路径才暴露得出来。
> 决定性实验见 `probe/decisive-test.mjs`（修复前 `content` 是 Promise、
> `snapshotJsonValue === undefined`、抛错；修复后是 Array、`snapshotJsonValue === ok`）。
>
> **修复**：把 `lib/index.js` 的 `finalizeContent` 改成**同步函数**，异步的图片附加工作
> 提前到 `execute()` 里做，结果存进模块级 `lastImagePath` / `lastImageBlock`。
>
> ### 因此初版第三节的方案 A / B 确实不能修好这个 bug
>
> 它们针对一个不存在的非法值。**请勿照做**——那会加入死代码并造成「已修复」的错觉。
> （该判断是对的，只是当时给出的理由不对：不是「block 干净」，而是「问题根本不在 block 上」。）
>
> ### 仍然成立的部分
>
> - 第一节症状、第二节的**调用链**（逐跳已核实）
> - 第二节 2.2 的**上游不对称缺口**——**已实施**（见下）
> - 第五节的 **UWP 两条文档修正**——**已实施并实测复核**（见下）
> - 第六节的排除清单（已把「不是什么」大幅收窄）
>
> ### 本次一并完成的两项
>
> 1. **上游加固（2.2 缺口）**：`dsh-tools` 的 `applyFinalContent` 现在把内容过一遍
>    `snapshotProjection(exec.name, "finalizeContent", content)`，
>    以后同类问题会直接报 `output.finalizeContent failed: ...` 并点名违规的 hook，
>    而不是丢一句无主的 `TypeError`。
> 2. **UWP 文档与判据修正（第五节）**：实测推翻「UWP 是 PrintWindow 盲区」的旧说法，
>    `uwpWarning` 改为**按实测像素空白度**触发。实测证据：
>
>    | 窗口 | 类名 | PNG 字节 | dominant‰ | distinctColors | 结果 |
>    | --- | --- | --- | --- | --- | --- |
>    | handle=3870456 | `ApplicationFrameWindow` | 31,176 | 977 | **17** | 空白壳，正确告警 |
>    | handle=8982094 | `Windows.UI.Core.CoreWindow` | 418,069 | 944 | **173** | **完整设置界面**，无告警 |
>
>    两者标题都是「设置」。旧逻辑按 `IsUwp` 告警，导致**两个都告警**——警告完全失去区分力；
>    新逻辑按像素判据，只对真正的空白壳告警。
>    另注：**黑像素比例是反的**（空白壳 16‰、真内容 617‰），本就不能当判据。

---

## 一、症状

`desktop_capture` 的**每一次**调用都失败，返回：

```
Error: tool result must be losslessly JSON-serializable
```

触发条件矩阵（全部实测）：

| 模式 | 参数 | 结果 |
| --- | --- | --- |
| 全屏 | 无 | ❌ 报错 |
| 全屏 | `outPath` | ❌ 报错 |
| 按 handle | `outPath` | ❌ 报错 |
| 按 handle | `region` + `outPath` | ❌ 报错 |
| 按标题 | 无 | ❌ 报错 |

**截图本身完全正常**：PNG 按预期落盘，尺寸/内容都正确（全屏 100KB、窗口 74KB、
`region "0,0,900,300"` 恰好 900x300）。`read_image` 读回来图也完全正常。
所以坏的只有**返回值通道**，不是抓取。

对照实验：`read_image` 走的是**同一套** `attachments.saveImage` 机制，工作正常。
共享管道没问题。

> **2026-10-03 修复后复测**：以上五种模式**全部通过**，返回值里
> `content` 依次为 `text, image`，图片块正常物化。见 `probe/verify-fix.mjs`
> （`OVERALL: ALL PASS`）。

---

## 二、调用链与上游缺口

### 2.1 调用链（**已逐跳核实，成立**）

1. `lib/index.js:546` `finalizeContent` → `imageBlock()`
2. `lib/index.js:554` `return [...result.content, image];`
3. `dsh-tools/lib/index.js:3391`
   `materializeFinalResult(this.applyFinalContent(exec, materializedResult))`（在 `finishScheduledExecution` `:3382` 内）
4. `applyFinalContent` `:3399-3407` → `return content === void 0 ? result : { ...result, content };`
5. `materializeFinalResult` `:3591-3610` → `materializePresentation` `:2606-2609`
6. `snapshotJsonValue` → `walkJsonValue`（`dsh-util-values/lib/index.js:159-161`）
7. `dsh-util-values/lib/index.js:109` `if (typeof current !== "object") return void 0;`
   —— 抛错点实为 **`dsh-tools/lib/index.js:2608`**

`walkJsonValue` 只接受 `null` / `boolean` / `string` / 有限 `number` / 纯数组 / 纯对象
（`dsh-util-values/lib/index.js:111,114,130`，原型检查在 `:112` `hasPlainArrayPrototype`、
`:130` `hasPlainObjectPrototype`）。**任何其它类型都会让整份结果作废**——不是跳过该字段，是整份拒绝。

> **但复核证明：插件构造的 block 并不含这样的值**（见第六节）。
> 所以这条链虽然真实，**却不是本次要被触发的那条**——或者触发它的值来自插件之外。

### 2.2 上游设计缺口（**已独立确认，真实缺陷**）

这条解释了**为什么错误信息如此无用**，值得报给 DSH 上游。

三个「内容产出钩子」的校验待遇**不一致**：

| 钩子 | 校验方式 | 失败时的报错 |
| --- | --- | --- |
| `output.render` | `snapshotProjection(tool.name, "render", …)`（`dsh-tools/lib/index.js:3552`） | `ToolOutputError: output.render returned non-lossless JSON`（`:2567`） |
| `output.presentationMeta` | `snapshotProjection(…, "presentationMeta", …)`（`:3561`） | `ToolOutputError: output.presentationMeta …` |
| `value` | `snapshotToolValue`（`:3542`）+ schema 校验（`:3543`） | 友好 `ToolOutputError` |
| **`finalizeContent`** | **无包装**——`applyFinalContent`（`:3399-3407`）的返回值直接进 `:3391` | **裸 `TypeError`**（`:2608`），不含工具名、不含钩子名、不含字段 |

**后果加倍**：`:3392-3394` 捕获该异常后
`materializeFinalResult(toolErrorResult(error))` —— **把整次成功的结果替换成错误**，
连已经渲染好的截图文字一起丢掉。这正是为什么模型看到的是一句裸错误，
而不是「截图成功 + 图片附加失败」的降级信息。

### 2.3 附：插件注释里的行号已失效

`lib/index.js:539-541` 写的「返回新的 content 数组即整体替换（index.js:3270-3278）」
—— 实测该区间是 `callerCancelled` 的 try/catch 尾部，**与 finalizeContent 契约无关**。
真正的契约注释在 **`dsh-tools/lib/types/index.js:803-812`**
（"Capture the finalizer BEFORE argument materialization…"）。
替换语义的实现是 `applyFinalContent`（`dsh-tools/lib/index.js:3399-3407`）。
修复时建议顺手更正。

### 2.4 为什么 2026-10-01 那次修复没有覆盖到

`lib/index.js:568-598` 的注释记录了上次**同样报错**的故障：`execute()` 少给字段产生
`undefined`，被物化判非法。那次修复把 `execute()` 每个字段都用 `??` 兜底、可选字段展开跳过
（`:583-598`）。**经核实，`execute()` 现在确实是干净的**——但它只加固了 `execute()` 的返回值，
而 `finalizeContent` 追加的 block **不经过**这段兜底，却被 `:3391` 一起送进物化。

> 注意：初版据此推断「本次是同一 bug 的另一个入口」。**该推断未获证实**——
> 复核证明该 block 本身合法（第六节），所以这条只是**路径事实**，不是根因。

---

## 三、修复方案

> ### ⚠️ 初版的方案 A、B 已被推翻，不要采用
>
> | 初版方案 | 复核裁决 |
> | --- | --- |
> | **A**：净化 `imageBlock` 字段 | ❌ **修不了任何东西**。它针对一个不存在的值；现行 `imageBlock` 输出（原始 `ref` 与净化版）**都通过** `isJsonValue`。属无害但错靶的防御性代码。另有隐患：把坏值映射成 `''`/`0` 会**静默损坏**图片引用，而不是暴露问题。 |
> | **B**：追加前用 `isJsonValue` 自检 | ❌ **同样修不了**。该检查**今天就已经通过**。更糟的是：若非法值在 block 之外，只检查 `image` 仍会漏掉。 |
> | **C**：try/catch 包 `finalizeContent` | ✅ 初版判断正确：物化发生在插件之外，插件抓不到，此路不通。 |
>
> 另：初版第四节验证步骤 4（断言 `imageBlock` 过 `isJsonValue`）**不是本 bug 的回归测试**，
> 它在修复前就是绿的，会造成假阳性。

### 方案 1（正道）：先查明真正的非法值——必须插桩**运行时**，而不是插件

**关键约束**：`patchReload: live` **不会**让改过的 ESM 模块被重新 import。
复核者实测确认：改了插件源码后，模块级副作用**从未在活进程里执行**，
而工具照旧运行（用的还是旧模块）。所以「改插件源码看日志」这条常规路子**在本部署下无效**。

可行做法：

1. 让 `finalizeContent` 无条件把自己的返回值做 `JSON.stringify` + `structuredClone`，
   写到固定路径的日志文件；
2. 通过**受支持的插件重载路径**真正重新加载模块
   —— `dsh-plugin-manager` 的 `change()` / `reload()`
   （`dsh-plugin-manager/lib/index.js:2089-2092`），**光改文件不行**；
3. 触发一次 `desktop_capture`，读出日志。

也可以走更省事的路子：把「非法值」的搜索范围从插件 block 扩大到**整份 content**
（含 `result.content` 里原有的文字块、以及 `meta` / `additionalContexts`），
因为物化作用的是**整份 result**，不只插件追加的那一块。

### 方案 2（独立价值，建议照做）：上游补上友好报错

把 `applyFinalContent`（`dsh-tools/lib/index.js:3399-3407`）的产物
改为经过 `snapshotProjection(tool.name, "finalizeContent", content)`，
与 `:3552` / `:3561` 对齐。这样非法 block 会得到
`output.finalizeContent returned non-lossless JSON`，
**而不是一句不含任何线索的裸 `TypeError`**，且不再吞掉整次成功结果。

> 这条把「两天的排查」变成「一行报错」。是本报告最有确定价值的产出。

### 方案 3（独立的健壮性改进，与本次 bug 无关）

`lib/index.js:54` 的 `export const inject = ['tools'];` 未声明 `attachments`，
而 `imageBlock`（`:311`）用 `ctx.get('attachments')` 取服务。
经核实这在**当前**部署下能取到值（`dsh-attachment-local` 已挂载，
`ctx.get` 的 strict 只检查 provider fiber 是否 ACTIVE，见 `cordis/lib/index.js:770`，
state 2 = ACTIVE 见 `:1291`），**故不是本次报错原因**。

但它是**真实的健壮性缺口**：一旦 `attachments` 不可用，图片会**静默**降级为纯文本
（`lib/index.js:312` → `:547-553`），「图片直返」这个核心卖点悄悄失效而不报错。
与官方 `dsh-tool-fs` 的做法（`inject` 声明 `attachments` +
在 `ctx.inject(['attachments'], …)` 回调内注册，见 `dsh-tool-fs/lib/index.js:1176-1206`）不一致。
**建议对齐**。

---

## 四、验证方法

### 4.1 验证「真的修好了」

1. 直接跑 `desktop_capture`（带 `outPath`），确认返回**不再是**序列化错误，而是文字 + 图片块；
2. 确认这次调用**不出现**降级文案「图片未能附加到本消息」——出现就说明走了降级，没真修好；
3. 覆盖 `region` / `window` / `handle` / 全屏四种模式。

### 4.2 ⚠️ 不要用「断言 `imageBlock` 过 `isJsonValue`」当回归测试

初版把这条列为验证步骤，**是错的**：该断言**在修复前就是绿的**（复核已实测），
所以它既不能复现 bug，也不能证明修好了——只会给出假阳性。

**正确的回归测试**应当先能复现当前失败，例如：
- 在活进程中捕获 `finalizeContent` 的真实返回值并断言可物化；
- 或在获得上游友好报错（方案 2）后，断言错误信息里出现 `finalizeContent` 字样
  ——即「错误被定位到正确的钩子」，这才能证明插桩到位。

---

## 五、两条文档错误（**已独立复核确认，可直接照改**）

> 复核方式：独立子智能体在本机重新抓取并逐项比对，未修改任何源文件。
> 环境：Windows 11 专业版 25H2，Build 26200。字节数与原测**逐字节吻合**。

### 5.1 UWP 并非「抓不到」，真正的盲区只是 `ApplicationFrameWindow`

`lib/index.js:355-359` 与 `skills/desktop-hand/SKILL.md` 声称「UWP 应用是 PrintWindow 的盲区」。
**该表述错误，且会把一个本来能抓的应用误判为不可抓。**

实测对照（`GetClassNameW` 直接确认类名）：

| handle | 进程 | 窗口类名 | PNG 字节 | 实测可见内容 |
| --- | --- | --- | --- | --- |
| 8982094 | SystemSettings | **`Windows.UI.Core.CoreWindow`** | **418,069** | 完整真实内容 |
| 3870456 | ApplicationFrameHost | **`ApplicationFrameWindow`** | **31,176** | 空白框架 + 齿轮 logo |

- `Windows.UI.Core.CoreWindow`（UWP 真实的 XAML 窗口）**完全可以被 PrintWindow 抓到**。
  8982094 逐项可读：顶栏、左侧导航 11 项、账户名与邮箱、设备名、「以太网 已连接」、
  推荐设置 3 项、个性化设备 6 张预览图、蓝牙开关与「MOONDROP EDGE 已配对」、
  底部「色彩模式 = 深色」。
- `ApplicationFrameWindow`（AFH 宿主壳）才是盲区：全幅纯深灰，仅标题栏占位 + 三个按钮 + 齿轮 logo，
  **零可操作信息**。

**结论**：真正的判据是**类名**，不是「是不是 UWP」，也不是「是不是应用自己的进程」
（这两件事在本例中恰好重合，容易被误当成因果）。归类标准应改为**只针对 `ApplicationFrameWindow`**。

### 5.2 `uwpWarning` 的触发条件本身是错位的

`lib/desktop-hand.ps1:237`（`:269` 的 `ByHandle` 分支逻辑相同）：

```csharp
IsUwp = cls == "Windows.UI.Core.CoreWindow" || cls == "ApplicationFrameWindow",
```

→ `:561` `$uwpWarn = $w.IsUwp` → `:630` `uwpWarning = $uwpWarn`

**矛盾**：该 OR 把两个类名都判为 UWP，于是上表两个窗口 `IsUwp` **都为 true**、
`uwpWarning` **都该为 true**，警告**都应打印**。但实测**两个都没打印**。

**根因**：触发条件按「是不是 UWP」判定，而真正该按「抓出来是不是空白」判定。
只要 `targetClass` 正确填充，**连那张 418KB 的完整图也会带 warning**，而 31KB 的空白框架
反而同样只是「带 warning」——warning 完全失去区分力。

> 复核者的诚实边界：本会话中 `desktop_capture` 仍命中第一节的序列化 bug，
> 返回体从未送达，`targetClass` **无法直接观测**。故「两处都没 warning」是**间接证据**。
> 但类名矛盾是**源码层面确定**的，不依赖该观察。

**建议**：`uwpWarning` 触发条件从 `IsUwp` 改为**基于实测空白度**（如 `blackPermille` 高且边缘无内容）。

### 5.3 `desktop_list_windows` 应区分标注宿主窗口

该工具给两个 Settings 窗口**都打 `[UWP]`、不区分宿主**（复核时行为依旧），
agent 无法据此判断该抓哪个，只能盲选。

**建议**：区分标注，如 `[UWP-宿主/可能空白]`。

### 5.4 给未来 agent 的修正后规则

> 抓 UWP 应用时：
> 1. 先 `desktop_list_windows`；**若同一标题出现多个句柄**（典型：真实应用进程 + `ApplicationFrameHost`），
>    **优先抓非 `ApplicationFrameHost` 的那个**。
> 2. **必须显式传 `handle` + `outPath`**，再 `read_image` 看图确认。本机 `desktop_capture`
>    返回体不可信（见第一节），**唯一判据是图像本身**。
> 3. **判据是「图里有没有 UI 内容」**，不是进程名、也不是「是不是 UWP」。
>    抓到空白框架就换另一个句柄再抓。
> 4. **不要**因为文档说「UWP 是盲区」就放弃——`Windows.UI.Core.CoreWindow` 实测完全可抓。
> 5. 抓不到就退回**全屏抓取**（要求窗口可见置顶），而不是判定该应用不可抓。
> 6. `uwpWarning` **目前不可依赖**（触发逻辑错位，且本机返回体送不达），**不要等它提示**。

### 5.5 附：Calculator 无法复现（INCONCLUSIVE）

`Start-Process calc.exe` 无效；改用
`shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App`（已装 v11.2607.0.0）后
`CalculatorApp` 进程**确实启动且 Responding=True**，但**从未创建任何可见顶层窗口**——
Win32 层只能枚举到两个不可见的 IME 窗口，轮询 12 秒无变化，进程随后自行退出。

**值得记录**：UWP 应用可能起进程但不挂窗口（本机 Calculator 即如此），此时抓取无从谈起。

---

## 六、真正的非法值在哪：**仍未定位**（但排除清单已大幅收窄）

> 复核者用**真实插件 + 真实 `dsh-attachment-local` + 真实 `snapshotJsonValue`**
> 做了可执行验证（非仅读码）：插件构造的 block、以及整个 `finalizeContent` 返回值
> **都通过** `isJsonValue === true`。故**插件这一侧已洗清**。

### 6.1 已由实验**排除**的候选

| 候选 | 结论 | 依据 |
| --- | --- | --- |
| `attachment` 里有 `undefined` 字段 | ❌ 不会被产生 | 真实 `ref`（`dsh-attachment-local/lib/index.js:335-349`）是纯原型对象，自有可枚举字符串键，全为 string/number |
| `result.value` 参与物化 | ❌ 不参与 | `materializeFinalResult`（`:3591-3610`）只物化 `content`/`meta`/`additionalContexts`/`error`，`value` 在 `:3608` 原样透传 |
| 类实例**作为** `attachment` | ❌ 会被拒，但不会发生 | 插件是**逐字段拷贝**，原型为 `Object.prototype` |
| `Uint8Array` 进入 block | ❌ 会被拒，但不会发生 | 实测 `isJsonValue=false`；`readFile` Buffer 在 `lib/index.js:314` 即被消费 |
| 不可枚举键 / symbol 键 | ❌ 会被拒，但不会发生 | 实测 |
| Proxy-of-plain | ❌ 会被接受 | 原型仍是 `Object.prototype` |
| 冻结（`deepFreeze`）block 被重走 | ❌ 会被接受 | 实测 |
| `AttachmentId` 是怪异类型 | ❌ 恒等函数返回纯字符串 | `dsh-attachment/lib/index.js:126-128` |
| `displayName` 返回 `undefined` | ❌ 已被展开语法跳过 | `dsh-attachment-local/lib/index.js:343` |
| `imageLimits`/`mediaTypes` 非纯对象 | ❌ 都是 `Object.freeze` 的纯对象/数组 | `:998-1010` |
| `inject` 缺 `attachments` 导致取不到服务 | ❌ 取得到 | `dsh-attachment-local` 已在 `dsh-base/cordis.patch.yml:138-139` 挂载，且早于插件层；`ctx.get` 的 strict 只看 provider fiber 是否 ACTIVE（`cordis/lib/index.js:770`，state 2 = ACTIVE 见 `:1291`）。**另**：若真取不到，`imageBlock` 返回 `null`（`:312`）会走降级纯文本路径（`:547-553`），**不会**产生这个错 |
| 插件 block 的**形状**错 | ❌ 形状正确 | `dsh-llm/lib/typert.host.js:329` 定义 `ImageBlock { type:'image'; attachment: ImageAttachmentRef; offloaded?: true }`；官方 `imageRefFromValue`（`dsh-tool-fs/lib/index.js:917-927`）与本插件**逐字段同构**；下游 `dsh-client-ui-tool/lib/client.js:2499` 确实解构 `attachment` |

### 6.2 关键方法论警告

**`patchReload: live` 不会重新 import 改过的 ESM 模块。**
复核者实测：改了插件源码后，模块级副作用**从未在活进程里执行**，而工具照旧能跑
（用的仍是旧模块）。**所以「改插件源码打日志再看输出」这条常规路子在本部署下无效**——
必须走受支持的插件重载（`dsh-plugin-manager/lib/index.js:2089-2092` 的 `change()`/`reload()`）。

### 6.3 仍未排除的方向

1. **非法值来自插件之外**：物化作用的是**整份 result**，不只插件追加的那块。
   应把搜索范围扩大到 `result.content` 里原有的文字块、`meta`、`additionalContexts`。
   复核者的标注推测（**明确标记为推测，无证据**）：可能来自**其它已挂载层**引入的值，
   或来自测试时**已存在但未被察觉的代码路径**。
2. **`saveImage` 在 `link:` 挂载下是否解析到另一份实现**。
3. **活进程内的真实值**——以上实验都是**独立跑**真实代码，不是在活进程内取到的实际值；
   两者可能因挂载/版本差异而不同。

### 6.4 给接手者的第一动作

**不要**先改插件。先按第 3 节「方案 1」插桩**运行时**（配合真正的 profile reload），
把 `finalizeContent` 的实际返回值序列化出来看一眼。
在拿到这个值之前，任何针对插件的修补都是猜测。

---

## 七、环境信息

- 插件源：`<repo root>`（`link:` 方式挂载，
  改完无需重装，但需重载 profile）
- profile：`%APPDATA%\dsh-desktop\harness\profiles\web\package.json`（`patchReload: live`）
- DSH 版本目录：`D:\Programs\DSH\DSH Desktop\resources\app.asar.unpacked`
- 屏幕 2560x1440，DPI `shcore:2`；GameViewer 远程串流在跑但远端空闲，
  `desktop_diagnose` 判定落点稳定
- 除 `desktop_capture` 外，`desktop_diagnose` / `desktop_list_windows` / `desktop_focus` /
  `desktop_click` / `desktop_type` **全部实测通过**，点击精确命中

### 实测通过的工具（2026-10-03）

| 工具 | 结果 | 证据 |
| --- | --- | --- |
| `desktop_diagnose` | ✅ | 2560x1440，DPI `shcore:2`，两次采样各 5 点稳定在 400,400 |
| `desktop_list_windows` | ✅ | 列出 10 窗口，handle/进程/尺寸/UWP 标记齐全 |
| `desktop_focus` | ✅ | 聚焦 Explorer，回报真实前台窗口类 `CabinetWClass` |
| `desktop_click` | ✅ | 点 (1300,640)/shotWidth 2032 → 物理 (1638,806)，选中目标文件 |
| `desktop_type` | ✅ | 文本与 `esc` 均送达，且回报前台窗口 |
| `desktop_capture` | ⚠️ | 能抓、能落盘、`read_image` 可读；**仅返回值通道失败** |
