/**
 * dsh-desktop-hand — 给 DSH agent 装上操作 Windows 桌面的手和眼睛。
 *
 * ## 为什么要有这个插件
 *
 * 本机（以及任何 Windows 机器）上，"截屏 + 点鼠标 + 敲键盘"这套能力原先靠三份散落的
 * PowerShell 脚本（capture.ps1 / mouse.ps1 / type.ps1）加一段 skill 引导来用。
 * 那套东西**能用且已验证**，但有三个问题：
 *
 *   1. 脚本在某个工作区的目录里，**别的会话/工作区用不到**（需求原文：供其他工作区使用）。
 *   2. agent 每次要自己拼命令行，容易拼错；`-ShotWidth` 之类的参数漏了就点偏。
 *   3. 截图只能落盘，模型还得再调一次 read_image 才看得到。
 *
 * 本插件把这三件事收成一个真正的 DSH 插件：
 *   - 工具全局注册，**任意工作区、任意会话**都能用；
 *   - agent 只描述意图（`capture_window`、`click`），坐标换算/DPI/编码全在内部做对；
 *   - 截图**直接把图作为内容块交给当前模型**，不需要二次 read_image。
 *
 * ## 与市场插件的关系（2026-09-27 调研结论）
 *
 * 调研了 8 个能碰桌面的 DSH 插件，**没有一个同时具备以下四项**：
 *   窗口按标题抓取（含遮挡）+ 坐标点击 + 键盘注入 + 窗口聚焦。
 * 市场清晰地分成两半：
 *   - 用了 PrintWindow（能抓遮挡）的（dsh-screen-reader、@paicat1/dsh-screenshot）
 *     **完全不碰输入**；
 *   - 能注入输入的（Altairpaca/dsh-computer-use-windows，四项俱全）
 *     抓窗口用的是 `CopyFromScreen` 裁窗口矩形，**抓不到被遮挡的内容**。
 * 所以本插件不是重复造轮子，而是补上那个空缺的组合。
 *
 * ## 设计约束（改动前必读，每条都有实测依据）
 *
 * 1. **抓窗口用 PrintWindow + flag=2**，不是 CopyFromScreen。只有前者能抓到遮挡窗口。
 * 2. **文本注入用 SendInput + KEYEVENTF_UNICODE**，不是 VkKeyScan/keybd_event。
 *    中文输入法会把后者注入的按键转换掉（实测 "third batch" 变「第三批」）。
 * 3. **坐标一律按物理像素**，脚本内声明 DPI 感知
 *    （本机 2560x1440 + 150% 缩放，不声明会点偏）。
 * 4. **截图只传路径不传图是错的**——本插件把图交给模型；但**也要落盘**，
 *    因为人需要复核，而"黑像素比例"不能当成功判据。
 * 5. **批量一次性返回时会超限**：截图可能 2MB+，一张一张来。
 *
 * @module dsh-desktop-hand
 */

import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, isAbsolute, resolve } from 'node:path';
import z from '@deepseek-ai/schemastery';
import { defineTool } from '@deepseek-ai/dsh-tools';

export const name = 'desktop-hand';

export const inject = ['tools'];
const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_ENGINE = join(HERE, 'desktop-hand.ps1');

/**
 * 运行时配置。注意：schemastery 只用于**插件自己的 Config**，
 * 工具参数用的是 dsh-tools 那套扁平 JSON-Schema 子集（见下面各 defineTool）。
 */
export const Config = z.object({
  /** 引擎脚本路径；默认用包内自带的 lib/desktop-hand.ps1。 */
  enginePath: z.string().default(DEFAULT_ENGINE),
  /** 单次调用超时（毫秒）。冷启动要编译 Add-Type，第一次约 1.2s，给足余量。 */
  timeoutMs: z.number().default(60000),
  /** 截图默认落盘目录；留空则用系统临时目录下的 dsh-desktop-hand。 */
  outputDir: z.string().default(''),
});

/** 引擎返回 ok:false 时，把结构和提示一起抛出去，让模型能自我纠正。 */
class EngineError extends Error {
  constructor(payload) {
    const hints = {
      NO_MATCH: '用 desktop_list_windows 查看当前有哪些窗口，再用完整标题或 handle 重试。',
      AMBIGUOUS: '该标题匹配到多个窗口，请改用 handle 精确指定。',
      NO_SUCH_WINDOW: '句柄可能已失效，重新 list_windows 取新句柄。',
      REGION_OOB: '裁切区域超出了被抓对象，先不裁切抓一次看实际尺寸。',
      BAD_REGION: 'region 必须形如 "x,y,w,h" 且宽高为正。',
      BAD_KEY: '该按键不在白名单内，改用支持的键名。',
      BAD_ACTION: '内部动作名错误（插件 bug）。',
      CAPTURE_FAILED: '抓取失败，可能是窗口已最小化或尺寸异常。',
    };
    const hint = hints[payload.code];
    super(`${payload.error}${hint ? `\n提示：${hint}` : ''}`);
    this.name = 'EngineError';
    this.code = payload.code;
  }
}

/** 把 JS 值转成 PowerShell 具名参数需要的字符串形式。 */
function toArgv(params) {
  const argv = [];
  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === null) continue;
    if (typeof value === 'boolean') {
      if (value) argv.push(`-${key}`);
      continue;
    }
    argv.push(`-${key}`, String(value));
  }
  return argv;
}

/**
 * 跑一次引擎并解析其 JSON。
 *
 * ## 为什么优先走 `ctx.subprocess` 而不是裸 `node:child_process`
 *
 * 官方插件（dsh-pwsh-local、dsh-tool-bash）都通过 harness 自己的
 * `ctx.subprocess.spawn` 起子进程，而不是直接 import `node:child_process`。
 * 这不只是风格问题：**DSH 的文件沙箱会拒绝 node 以管道 stdio 起子进程**
 * （实测在本会话的 workspace-write 沙箱下，裸 spawn 直接 `EPERM`；
 *  换成 `stdio:'inherit'` 就能跑，可见拦的就是"捕获输出"这个动作）。
 * 走 harness 的 seam 由 harness 自己决定如何落盘/收集输出，不受该限制。
 *
 * 因此这里：有 `ctx.subprocess` 就用它（正式路径），没有才退回裸 spawn
 * （便于脱离 DSH 单独测试）。两条路都返回同一形状。
 */
function makeRunner(ctx, enginePath, timeoutMs) {
  const subprocess = ctx.get('subprocess');

  /** 正式路径：harness 的子进程 seam。 */
  async function runViaHarness(params, signal) {
    // ⚠️ `graceMs` 是**必填**的：validateSubprocessSpec 会拒绝缺失/非正数
    //    （runner-launch-*.js:883）。它不是超时，而是"发终止信号后宽限多久"。
    // ⚠️ 这个 seam **没有** timeoutMs 字段——超时由调用方自己管
    //    （官方 dsh-pwsh-local 用 deadline(...) 造 signal 再传进来）。
    //    所以这里用 AbortController + 定时器自己实现超时。
    const controller = new AbortController();
    const onOuterAbort = () => controller.abort(signal?.reason);
    if (signal !== undefined) {
      if (signal.aborted) controller.abort(signal.reason);
      else signal.addEventListener('abort', onOuterAbort, { once: true });
    }
    const timer = setTimeout(
      () => controller.abort(new Error(`engine timeout after ${timeoutMs}ms`)),
      timeoutMs,
    );

    let handle;
    try {
      handle = subprocess.spawn({
        argv: ['powershell.exe', '-NoProfile', '-NonInteractive',
          '-ExecutionPolicy', 'Bypass', '-File', enginePath, ...toArgv(params)],
        stdio: {
          stdin: 'ignore',
          stdout: { maxBytes: 4 * 1024 * 1024 },
          stderr: { maxBytes: 256 * 1024 },
        },
        graceMs: 3000,
        signal: controller.signal,
      });
    } catch (error) {
      clearTimeout(timer);
      if (signal !== undefined) signal.removeEventListener?.('abort', onOuterAbort);
      throw new Error(`无法启动桌面引擎：${error.message}`);
    }

    // ⚠️ `handle.collected.stdout` 是一个**收集器对象**，不是 {text} 字面量：
    // 必须调它的 finalize() 才拿到 { text, truncated, spillPath }
    // （见 dsh-subprocess-local/lib/runner-launch-*.js 的 finalize()）。
    // 直接读 .text 会静默拿到 undefined —— 那会让所有工具都报"引擎无输出"。
    //
    // 引擎侧已把 [Console]::OutputEncoding 设成 UTF-8，所以 finalize() 拿到的
    // 就是正确的中文。若某个实现返回 Buffer，也按 utf8 解一次兜底。
    const drain = (collector) => {
      if (collector === undefined || collector === null) return '';
      let raw;
      if (typeof collector.finalize === 'function') {
        try { raw = collector.finalize()?.text; } catch { return ''; }
      } else {
        raw = collector.text;
      }
      if (raw === undefined || raw === null) return '';
      return Buffer.isBuffer(raw) ? raw.toString('utf8') : String(raw);
    };

    try {
      const outcome = await handle.done;
      if (controller.signal.aborted && controller.signal.reason?.message?.includes('engine timeout')) {
        throw new Error(`引擎超时（${timeoutMs}ms）。若目标窗口无响应或系统繁忙，可调大 timeoutMs。`);
      }
      return {
        stdout: drain(handle.collected?.stdout),
        stderr: drain(handle.collected?.stderr),
        exitCode: outcome?.exitCode,
      };
    } finally {
      clearTimeout(timer);
      if (signal !== undefined) signal.removeEventListener?.('abort', onOuterAbort);
    }
  }

  /** 退路：裸 spawn。仅在没有 subprocess seam 时使用（例如独立跑自检）。 */
  function runViaChildProcess(params) {
    return new Promise((resolvePromise, rejectPromise) => {
      let child;
      try {
        child = spawn('powershell.exe', [
          '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
          '-File', enginePath, ...toArgv(params),
        ], { windowsHide: true });
      } catch (error) {
        rejectPromise(new Error(`无法启动 PowerShell：${error.message}`));
        return;
      }
      let stdout = '';
      let stderr = '';
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        try { child.kill(); } catch { /* 已退出 */ }
        rejectPromise(new Error(`引擎超时（${timeoutMs}ms）。若目标窗口无响应或系统繁忙，可调大 timeoutMs。`));
      }, timeoutMs);
      // 显式按 utf8 解码：引擎侧已设 OutputEncoding=UTF8，这里对齐
      child.stdout.setEncoding('utf8');
      child.stderr.setEncoding('utf8');
      child.stdout.on('data', (chunk) => { stdout += chunk; });
      child.stderr.on('data', (chunk) => { stderr += chunk; });
      child.on('error', (error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        rejectPromise(new Error(`引擎进程错误：${error.message}`));
      });
      child.on('close', (code) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolvePromise({ stdout, stderr, exitCode: code });
      });
    });
  }

  return async function call(params, signal) {
    const result = subprocess !== undefined
      ? await runViaHarness(params, signal)
      : await runViaChildProcess(params);

    const line = String(result.stdout ?? '')
      .split(/\r?\n/)
      .map((s) => s.trim())
      .filter((s) => s.startsWith('{'))
      .pop();

    if (!line) {
      const detail = String(result.stderr ?? '').trim()
        || String(result.stdout ?? '').trim()
        || '(无输出)';
      throw new Error(`桌面引擎未返回 JSON（exit=${result.exitCode}）。原始输出：\n${detail}`);
    }

    let payload;
    try {
      payload = JSON.parse(line);
    } catch {
      throw new Error(`桌面引擎返回的不是合法 JSON：${line.slice(0, 400)}`);
    }
    if (payload.ok !== true) throw new EngineError(payload);
    return payload;
  };
}

export function apply(ctx, config) {
  const enginePath = config.enginePath?.trim() || DEFAULT_ENGINE;
  const timeoutMs = config.timeoutMs > 0 ? config.timeoutMs : 60000;
  const outputDir = config.outputDir?.trim() || '';

  if (!existsSync(enginePath)) {
    throw new Error(
      `dsh-desktop-hand: 找不到引擎脚本 ${enginePath}。`
      + '请检查插件安装是否完整，或在 profile 的插件配置里改正 enginePath。',
    );
  }

  const call = makeRunner(ctx, enginePath, timeoutMs);

  /**
   * 把落盘的 PNG 变成可交给模型的 image 内容块。
   *
   * 走的是 dsh 的附件服务：attachment 引用**只带元数据不带 base64**
   * （dsh-tool-fs 的 read_image 用的是同一套机制）。
   * 没有附件服务或模型不支持图片输入时，降级为纯文本返回路径，
   * 而不是硬失败——路径对人仍然有用。
   */
  async function imageBlock(exec, filePath, mediaType = 'image/png') {
    const attachments = ctx.get('attachments');
    if (attachments === undefined) return null;
    try {
      const data = await readFile(filePath);
      if (data.byteLength > attachments.imageLimits.maxImageBytes) return null;
      if (!attachments.imageLimits.mediaTypes.includes(mediaType)) return null;
      const ref = await attachments.saveImage({ data, mediaType, name: filePath.split(/[\\/]/).pop() });
      return {
        type: 'image',
        attachment: {
          attachmentId: ref.attachmentId,
          mediaType: ref.mediaType,
          bytes: ref.bytes,
          width: ref.width,
          height: ref.height,
          ...(ref.name === undefined ? {} : { name: ref.name }),
        },
      };
    } catch {
      // 附件服务拒绝（超限/不支持/解码失败）不该让"已经抓到图"这次调用失败
      return null;
    }
  }

  /**
   * 截图结果的文字部分。图片块由上方 `finalizeContent` 追加——见那里的注释：
   * `output.schema` 是 additionalProperties:false，图片不能搭返回值的车。
   */
  function shotRender(value) {
    const lines = [
      `<path>${value.path}</path>`,
      `<type>image</type>`,
      `<content>`,
      `${value.width}x${value.height} px, ${value.bytes} bytes, 目标: ${value.target}`,
    ];
    if (value.targetClass) lines.push(`窗口类名: ${value.targetClass}`);
    if (value.crop) {
      lines.push(`裁切区域: ${value.crop}，该区域在屏幕上的左上角为 (${value.originX},${value.originY})`);
    } else if (value.coordScale !== undefined && value.coordScale !== 1) {
      lines.push(`注意：这张图宽 ${value.width} 与物理屏宽 ${value.screenWidth} 不一致，`
        + `点击坐标需乘 ${value.coordScale}。`);
    } else {
      lines.push('图与物理屏 1:1，可直接用图中像素坐标传给 desktop_click。');
    }
    if (value.uwpWarning) {
      lines.push(`⚠️ 这是 UWP 应用（类名 ${value.targetClass}），PrintWindow 抓不到其内容，`
        + '抓到的可能是空白框架——不要根据这张图判断界面状态。'
        + '需要看它的内容只能改为全屏抓取（要求该窗口可见）。');
    }
    if (value.minimized) lines.push('⚠️ 该窗口当前是最小化的，抓到的内容无意义。');
    lines.push('</content>');
    lines.push('黑像素比例仅供参考，不是成功判据（UWP 宿主 2.9% 黑也可能是空白框架）——请看图。');
    return [{ type: 'text', text: lines.join('\n') }];
  }

  // ===================================================================
  //  工具 1：列出窗口
  // ===================================================================
  ctx.tools.register(defineTool({
    name: 'desktop_list_windows',
    description: 'List visible desktop windows on Windows with their handle, process, '
      + 'title, position and size. Use this first to discover the exact title or handle '
      + 'to pass to desktop_capture / desktop_focus, and to check which window is in the '
      + 'foreground. Also reports whether remote-control/streaming tools (GameViewer, '
      + 'ToDesk, Sunlogin, ...) are running, because an active remote session drives the '
      + 'cursor and makes synthetic clicks land unpredictably.',
    parameters: {
      filter: {
        type: 'string',
        description: 'Optional case-insensitive substring; only windows whose title or process name contains it are returned.',
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          count: { type: 'integer', required: true },
          foregroundHandle: { type: 'integer' },
          foregroundTitle: { type: 'string' },
          remoteTools: { type: 'array', required: true, items: { type: 'string' } },
          windows: {
            type: 'array',
            required: true,
            items: {
              type: 'object',
              additionalProperties: false,
              properties: {
                handle: { type: 'integer', required: true },
                pid: { type: 'integer', required: true },
                title: { type: 'string', required: true },
                process: { type: 'string', required: true },
                class: { type: 'string', required: true },
                x: { type: 'integer', required: true },
                y: { type: 'integer', required: true },
                width: { type: 'integer', required: true },
                height: { type: 'integer', required: true },
                uwp: { type: 'boolean', required: true },
                minimized: { type: 'boolean', required: true },
              },
            },
          },
        },
      },
      render: (_args, value) => {
        const rows = value.windows.map((w) => {
          const flags = [w.uwp ? 'UWP' : '', w.minimized ? 'MINIMIZED' : ''].filter(Boolean).join(',');
          return `${w.title || '(无标题)'} | handle=${w.handle} pid=${w.pid} `
            + `process=${w.process} ${w.width}x${w.height} at (${w.x},${w.y})`
            + (flags ? ` [${flags}]` : '');
        });
        const parts = [`${value.count} 个可见窗口：`, ...rows.map((r) => `- ${r}`)];
        if (value.foregroundHandle !== undefined) {
          parts.push(`\n当前前台窗口：${value.foregroundTitle ?? '(无标题)'} (handle=${value.foregroundHandle})`);
        }
        if (value.remoteTools.length > 0) {
          parts.push(`\n⚠️ 检测到远程/串流软件：${value.remoteTools.join(', ')}。`
            + '若远端正在操作鼠标，合成点击的落点会被实时覆盖而不可靠'
            + '（先用 desktop_diagnose 确认）。');
        }
        return [{ type: 'text', text: parts.join('\n') }];
      },
    },
    isConcurrencySafe: () => true,
    async execute(args) {
      const payload = await call({ Action: 'list-windows' });
      const all = payload.windows ?? [];
      const filter = args.filter?.trim().toLowerCase();
      const windows = filter
        ? all.filter((w) => (w.title ?? '').toLowerCase().includes(filter)
          || (w.process ?? '').toLowerCase().includes(filter))
        : all;

      // 复用引擎的 info 拿到前台标题与远程软件清单
      let foregroundTitle;
      let remoteTools = [];
      try {
        const info = await call({ Action: 'info' });
        foregroundTitle = info.foreground;
        remoteTools = info.remoteTools ?? [];
      } catch { /* info 失败不影响窗口列表 */ }

      return {
        count: windows.length,
        ...(payload.foregroundHandle === undefined ? {} : { foregroundHandle: payload.foregroundHandle }),
        ...(foregroundTitle === undefined ? {} : { foregroundTitle }),
        remoteTools,
        windows: windows.map((w) => ({
          handle: w.handle, pid: w.pid,
          title: w.title ?? '', process: w.process ?? '', class: w.class ?? '',
          x: w.x, y: w.y, width: w.width, height: w.height,
          uwp: Boolean(w.uwp), minimized: Boolean(w.minimized),
        })),
      };
    },
  }));

  // ===================================================================
  //  工具 2：截屏
  // ===================================================================
  ctx.tools.register(defineTool({
    name: 'desktop_capture',
    description: 'Capture the Windows desktop and return the image itself to the current '
      + 'model (no second read_image call needed). Three modes: '
      + '(1) whole virtual screen by default — this is what CopyFromScreen sees, so an '
      + 'occluded window shows whatever covers it; '
      + '(2) a specific window via `window` (title substring) or `handle` — this uses '
      + 'PrintWindow, so it captures the window\'s OWN content even when fully occluded; '
      + '(3) `region` crops the result. '
      + 'Always look at the returned image: the black-pixel ratio is NOT a success test, '
      + 'because a UWP window can look fine by that metric while actually being a blank frame. '
      + 'UWP apps (Settings, Calculator, ...) cannot be captured by PrintWindow — the result '
      + 'warns when that is the case.',
    parameters: {
      window: {
        type: 'string',
        description: 'Case-insensitive substring of the target window title. Errors listing all candidates if ambiguous — prefer `handle` then.',
      },
      handle: {
        type: 'integer',
        description: 'Exact window handle from desktop_list_windows. Takes precedence over `window`.',
      },
      region: {
        type: 'string',
        description: 'Crop "x,y,w,h". Coordinates are relative to the captured target (window or screen). Rejected if out of bounds.',
      },
      outPath: {
        type: 'string',
        description: 'Where to save the PNG. Defaults to a timestamped file under the system temp directory.',
      },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          path: { type: 'string', required: true },
          width: { type: 'integer', required: true },
          height: { type: 'integer', required: true },
          bytes: { type: 'integer', required: true },
          target: { type: 'string', required: true },
          targetClass: { type: 'string' },
          originX: { type: 'integer' },
          originY: { type: 'integer' },
          screenWidth: { type: 'integer' },
          screenHeight: { type: 'integer' },
          coordScale: { type: 'number' },
          crop: { type: 'string' },
          uwpWarning: { type: 'boolean' },
          minimized: { type: 'boolean' },
        },
      },
      render: (_args, value) => shotRender(value),
    },

    /**
     * 图片必须在 render 之外附加：`output.schema` 是 additionalProperties:false，
     * 返回值里塞 `__image` 之类的额外键会被 validateJsonSchemaValue 直接判违规
     * （dsh-tools index.js:3413 抛 ToolOutputError）。
     * `finalizeContent(exec, result)` 是官方给的钩子：它拿到**已渲染好的 result**，
     * 返回新的 content 数组即整体替换（index.js:3270-3278），且允许异步，
     * 所以正好在这里把 PNG 交给附件服务并追加图片块。
     */
    async finalizeContent(exec, result) {
      const path = result.value?.path;
      if (typeof path !== 'string' || path === '') return undefined;
      const image = await imageBlock(exec, path);
      if (image === null) {
        return [...result.content, {
          type: 'text',
          text: '（图片未能附加到本消息：无附件服务、模型不支持图片输入，或超出图片限额。'
            + '可用 read_image 读取上面的 path。）',
        }];
      }
      return [...result.content, image];
    },

    async execute(args) {
      const params = { Action: 'capture' };
      if (args.handle !== undefined) params.Handle = args.handle;
      else if (args.window !== undefined) params.Window = args.window;
      else params.FullScreen = true;
      if (args.region !== undefined) params.Region = args.region;
      if (args.outPath !== undefined && args.outPath.trim() !== '') params.OutPath = args.outPath;
      else if (outputDir !== '') params.OutPath = join(outputDir, `shot_${Date.now()}.png`);

      const payload = await call(params);

      return {
        path: payload.path,
        width: payload.width,
        height: payload.height,
        bytes: payload.bytes,
        target: String(payload.target ?? ''),
        ...(payload.targetClass ? { targetClass: payload.targetClass } : {}),
        ...(payload.originX === undefined ? {} : { originX: payload.originX }),
        ...(payload.originY === undefined ? {} : { originY: payload.originY }),
        ...(payload.screenWidth === undefined ? {} : { screenWidth: payload.screenWidth }),
        ...(payload.screenHeight === undefined ? {} : { screenHeight: payload.screenHeight }),
        ...(payload.coordScale === undefined || payload.coordScale === null ? {} : { coordScale: payload.coordScale }),
        ...(args.region ? { crop: args.region } : {}),
        ...(payload.uwpWarning ? { uwpWarning: true } : {}),
        ...(payload.minimized ? { minimized: true } : {}),
      };
    },
  }));

  // ===================================================================
  //  工具 3：聚焦窗口
  // ===================================================================
  ctx.tools.register(defineTool({
    name: 'desktop_focus',
    description: 'Bring a window to the foreground so that keyboard input reaches it. '
      + 'Uses SetForegroundWindow with an AttachThreadInput + ALT-nudge fallback, and '
      + 'reports whether the window really became foreground (SetForegroundWindow can '
      + 'return success while the foreground lock blocks it). If this reports failure, '
      + 'click on the window body with desktop_click first — a real click obtains '
      + 'activation when the API cannot.',
    parameters: {
      window: { type: 'string', description: 'Case-insensitive substring of the window title.' },
      handle: { type: 'integer', description: 'Exact window handle; takes precedence over `window`.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          focused: { type: 'boolean', required: true },
          result: { type: 'string', required: true },
          target: { type: 'string' },
          foregroundTitle: { type: 'string' },
        },
      },
      render: (_args, value) => [{
        type: 'text',
        text: value.focused
          ? `已聚焦：${value.target}（当前前台：${value.foregroundTitle}）`
          : `聚焦失败（${value.result}）。改用 desktop_click 在目标窗口体上点一下拿到激活，再输入。`
            + `当前前台：${value.foregroundTitle}`,
      }],
    },
    async execute(args) {
      const params = { Action: 'focus' };
      if (args.handle !== undefined) params.Handle = args.handle;
      else if (args.window !== undefined) params.Window = args.window;
      else throw new Error('desktop_focus 需要 window 或 handle 之一。');

      const payload = await call(params);
      const focused = payload.result === 'ok' || payload.result === 'already-foreground';
      return {
        focused,
        result: String(payload.result ?? 'unknown'),
        ...(payload.target ? { target: payload.target } : {}),
        ...(payload.foreground ? { foregroundTitle: payload.foreground } : {}),
      };
    },
  }));

  // ===================================================================
  //  工具 4：鼠标点击 / 拖动
  // ===================================================================
  ctx.tools.register(defineTool({
    name: 'desktop_click',
    description: 'Click, double-click, right-click or drag on the Windows desktop at the '
      + 'given coordinates. Coordinates are pixels in the image returned by '
      + 'desktop_capture; pass that image\'s width as `shotWidth` when it does not match '
      + 'the physical screen width (the capture result tells you). '
      + 'IMPORTANT: synthetic clicks fail silently-but-visibly when a remote-control '
      + 'session is driving the real cursor — run desktop_diagnose if clicks land wrong. '
      + 'Prefer clicking the window body first to give it focus, then desktop_type.',
    parameters: {
      x: { type: 'integer', required: true, description: 'X in screenshot pixels.' },
      y: { type: 'integer', required: true, description: 'Y in screenshot pixels.' },
      shotWidth: {
        type: 'integer',
        description: 'Width of the screenshot these coordinates were read from. Omit when the screenshot is 1:1 with the physical screen.',
      },
      double: { type: 'boolean', description: 'Double-click.' },
      right: { type: 'boolean', description: 'Right-click.' },
      toX: { type: 'integer', description: 'Drag: destination X. Requires toY.' },
      toY: { type: 'integer', description: 'Drag: destination Y. Requires toX.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          action: { type: 'string', required: true },
          screenX: { type: 'integer', required: true },
          screenY: { type: 'integer', required: true },
          cursor: { type: 'string', required: true },
          cursorMatched: { type: 'boolean', required: true },
        },
      },
      render: (_args, value) => [{
        type: 'text',
        text: `${value.action} 落在屏幕物理坐标 (${value.screenX},${value.screenY})，`
          + `光标现为 (${value.cursor})。`
          + (value.cursorMatched
            ? '落点与目标一致，点击应已生效——用 desktop_capture 看图确认。'
            : '⚠️ 光标未停在目标位置：有别的输入源在驱动鼠标（通常是远程会话）。'
              + '这次点击的落点不可信，请等远端空闲后重试。'),
      }],
    },
    async execute(args) {
      const params = { Action: 'click', X: args.x, Y: args.y };
      if (args.shotWidth !== undefined) params.ShotWidth = args.shotWidth;
      if (args.double) params.Double = true;
      if (args.right) params.Right = true;
      if (args.toX !== undefined && args.toY !== undefined) {
        params.ToX = args.toX;
        params.ToY = args.toY;
      }

      const payload = await call(params);
      const target = args.toX !== undefined && args.toY !== undefined
        ? (payload.toPhys ?? '')
        : (payload.phys ?? '');
      const [cx, cy] = target.split(',').map((s) => Number.parseInt(s, 10));
      const [ax, ay] = String(payload.cursor ?? '').split(',').map((s) => Number.parseInt(s, 10));
      // 落点校验：容差 3px，覆盖 Windows 的指针吸附/取整
      const matched = Number.isFinite(ax) && Number.isFinite(cx)
        && Math.abs(ax - cx) <= 3 && Math.abs(ay - cy) <= 3;

      return {
        action: String(payload.action ?? 'click'),
        screenX: Number.isFinite(cx) ? cx : 0,
        screenY: Number.isFinite(cy) ? cy : 0,
        cursor: String(payload.cursor ?? ''),
        cursorMatched: matched,
      };
    },
  }));

  // ===================================================================
  //  工具 5：键盘输入
  // ===================================================================
  ctx.tools.register(defineTool({
    name: 'desktop_type',
    description: 'Type text into the foreground window, or send a single key / key combo. '
      + 'Text is injected with SendInput + KEYEVENTF_UNICODE, which BYPASSES the active '
      + 'IME — this matters: the older VkKeyScan/keybd_event route gets mangled by a '
      + 'Chinese IME (typing "third batch" once arrived as the characters for "第三批"). '
      + 'Make sure the target window is focused first (desktop_focus, or desktop_click on '
      + 'its body). Reports which window was actually in the foreground when the input '
      + 'was delivered, so a misfire is visible instead of silent.',
    parameters: {
      text: {
        type: 'string',
        description: 'Text to type. Unicode, so Chinese and format specifiers work. Requires `key` to be omitted.',
      },
      key: {
        type: 'string',
        description: 'One key or combo instead of text: enter, esc, tab, space, backspace, delete, up, down, left, right, home, end, pageup, pagedown, f1-f12, ctrl+a, ctrl+c, ctrl+v, ctrl+s, ctrl+w, ctrl+x, ctrl+z, alt+f4.',
      },
      enter: { type: 'boolean', description: 'With `text`: press Enter after typing.' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          mode: { type: 'string', required: true },
          chars: { type: 'integer' },
          key: { type: 'string' },
          enter: { type: 'boolean' },
          foregroundTitle: { type: 'string', required: true },
        },
      },
      render: (_args, value) => [{
        type: 'text',
        text: value.key !== undefined
          ? `已发送按键 ${value.key}。输入送达时的前台窗口：${value.foregroundTitle || '(无标题)'}`
          : `已输入 ${value.chars} 个字符${value.enter ? ' 并回车' : ''}（${value.mode}）。`
            + `输入送达时的前台窗口：${value.foregroundTitle || '(无标题)'}`
            + `\n如果这不是你预期的目标，说明焦点不对：先用 desktop_focus 或 desktop_click 聚焦。`,
      }],
    },
    async execute(args, exec) {
      exec.signal?.throwIfAborted?.();
      if (args.key !== undefined && args.text !== undefined) {
        throw new Error('desktop_type 的 text 和 key 只能给一个。');
      }
      if (args.key === undefined && (args.text === undefined || args.text === '')) {
        throw new Error('desktop_type 需要 text 或 key 之一。');
      }

      if (args.key !== undefined) {
        const payload = await call({ Action: 'key', Key: args.key });
        return {
          mode: 'key',
          key: String(payload.key ?? args.key),
          foregroundTitle: String(payload.foreground ?? ''),
        };
      }

      const params = { Action: 'type', Text: args.text };
      if (args.enter) params.Enter = true;
      const payload = await call(params);
      return {
        mode: String(payload.mode ?? 'unicode'),
        chars: Number(payload.chars ?? 0),
        enter: Boolean(payload.enter),
        foregroundTitle: String(payload.foreground ?? ''),
      };
    },
  }));

  // ===================================================================
  //  工具 6：体检
  // ===================================================================
  ctx.tools.register(defineTool({
    name: 'desktop_diagnose',
    description: 'Check whether synthetic mouse/keyboard input can be trusted on this '
      + 'machine right now, and explain any problem. Run this FIRST whenever a click '
      + 'lands in the wrong place or keyboard input disappears. It sets the cursor and '
      + 'then samples its position repeatedly: a smoothly drifting cursor means another '
      + 'input source (typically an active remote-control session such as GameViewer) is '
      + 'overriding synthetic coordinates, in which case no amount of coordinate tweaking '
      + 'will help — wait for the remote session to go idle. It also reports DPI '
      + 'awareness, screen size, the foreground window and the IME state.',
    parameters: {},
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          healthy: { type: 'boolean', required: true },
          verdict: { type: 'string', required: true },
          stable: { type: 'boolean', required: true },
          probeA: { type: 'string' },
          probeB: { type: 'string' },
          screenWidth: { type: 'integer' },
          screenHeight: { type: 'integer' },
          dpiMode: { type: 'string' },
          foregroundTitle: { type: 'string' },
          ime: { type: 'string' },
          remoteTools: { type: 'array', required: true, items: { type: 'string' } },
        },
      },
      render: (_args, value) => [{
        type: 'text',
        text: [
          value.healthy ? '✅ 合成输入可信：光标落点稳定。' : '❌ 合成输入不可信，原因见下。',
          '',
          `判定：${value.verdict}`,
          `屏幕：${value.screenWidth}x${value.screenHeight}（DPI 感知：${value.dpiMode}）`,
          `前台窗口：${value.foregroundTitle || '(无标题)'}`,
          `输入法：${value.ime}`,
          `远程/串流软件：${value.remoteTools.length > 0 ? value.remoteTools.join(', ') : '未检测到'}`,
          '',
          `光标落点采样 A：${value.probeA}`,
          `光标落点采样 B：${value.probeB}`,
        ].join('\n'),
      }],
    },
    async execute() {
      const info = await call({ Action: 'info' });
      const probe = await call({ Action: 'probe', X: 400, Y: 400 });
      const a = String(probe.probeA ?? '');
      const b = String(probe.probeB ?? '');
      // 两次采样都以 "400,400" 开头 → 光标没有被推走
      const stable = /^400,400/.test(a.trim()) && /^400,400/.test(b.trim());

      let verdict;
      if (stable) {
        verdict = '落点稳定，鼠标点击可用。';
      } else if ((info.remoteTools ?? []).length > 0) {
        verdict = '光标被持续推走，且本机装有以下远程/串流软件：'
          + `${(info.remoteTools ?? []).join(', ')}。`
          + '极可能是远端有人正在操作鼠标，合成坐标被实时覆盖。'
          + '这不是插件缺陷：请等远端停止操作后重试。'
          + '也可考虑改用浏览器内自动化（pilot_* 工具走 CDP，不碰光标）。';
      } else {
        verdict = '光标被持续推走，但未检测到常见远程/串流软件。'
          + '请确认是否有物理鼠标被压住/漂移，或其它注入设备。';
      }

      return {
        healthy: stable,
        verdict,
        stable,
        probeA: a,
        probeB: b,
        ...(info.screenWidth === undefined ? {} : { screenWidth: info.screenWidth }),
        ...(info.screenHeight === undefined ? {} : { screenHeight: info.screenHeight }),
        ...(info.dpiMode === undefined ? {} : { dpiMode: info.dpiMode }),
        ...(info.foreground === undefined ? {} : { foregroundTitle: info.foreground }),
        ...(info.ime === undefined ? {} : { ime: info.ime }),
        remoteTools: info.remoteTools ?? [],
      };
    },
  }));

  // 把用法要点挂进系统提示，让 agent 不必猜。
  //
  // ⚠️ 整段包在 try/catch 里，而且**失败只警告、不抛出**。
  // 原因（真实事故，2026-09-28）：本插件在 profile 里是 `required: true`，
  // 所以 apply() 抛异常会**让整个 DSH 启动失败**，而不是仅仅少一段提示词。
  // v1.0.0 就是因为 section() 少传 order，升级到 0.1.7-rc.2 后直接
  // 把 DSH 带崩（启动日志：'dsh: startup failed: 1 required plugin did not activate'），
  // DSH 随后进安全模式并把 profile 里的插件条目删掉了。
  //
  // 系统提示只是**锦上添花**：6 个工具本身不依赖它，文字说明也已写进 skill。
  // 所以这里遵循"工具能注册就行，提示挂不上不算致命"。
  try {
    const systemPrompt = ctx.get('systemPrompt');
    if (systemPrompt !== undefined && typeof systemPrompt.section === 'function') {
      // ⚠️ `order` 是**必填**，且必须是有限数字。
      // DSH 0.1.7-rc.2 起 section() 硬校验：
      //     if (!Number.isFinite(section.order)) throw new TypeError(...)
      //     —— @deepseek-ai/dsh-system-prompt/lib/index.js:241
      //
      // 取值依据：DSH 内部 SECTION_ORDERS 把工具说明段排在 1000~3000
      // （…TOOL_REPORT: 2900, TOOL_COMPUTER_USE: 3000, MCP_SERVERS: 3100）。
      // 桌面控制属于 computer-use 一类，取 **3001**：紧跟官方
      // TOOL_COMPUTER_USE(3000)、在 MCP_SERVERS(3100) 之前。
      // 那些常量没有对外导出，所以这里写死字面量并注明来源。
      systemPrompt.section({
        name: 'tool:desktop-hand',
        order: 3001,
        text: 'Windows desktop control is available through `desktop_*` tools. '
          + 'Workflow: `desktop_diagnose` first if anything seems off, '
          + '`desktop_list_windows` to find the target, `desktop_capture` to see it '
          + '(the image comes back to you directly), `desktop_focus` or `desktop_click` '
          + 'on the window body to give it focus, then `desktop_type`. '
          + 'Capture a WINDOW rather than the full screen when you need a window\'s content '
          + 'even while it is occluded. Never judge a capture by its black-pixel ratio — '
          + 'look at the image. UWP apps (Settings, Calculator) cannot be captured.',
      });
    }
  } catch (error) {
    ctx.logger?.warn?.(
      `dsh-desktop-hand: 系统提示段落未挂上（工具仍可用）：${error?.message ?? error}`,
    );
  }
}
