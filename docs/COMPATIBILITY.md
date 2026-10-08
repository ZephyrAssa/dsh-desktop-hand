# DSH compatibility

How this plugin behaves across DSH versions, and the startup-failure incident that
shaped its hardening.

- **Currently verified against:** DSH Desktop `0.9.2` / harness `0.1.7-rc.2`,
  and DSH NEXT `2.0.17-next` / `@deepseek-ai/dsh 0.2.0-rc.2`
- **Last breaking change absorbed:** `0.1.5-rc.2` → `0.1.7-rc.2`
- **Plugin version that fixed it:** `1.0.1`

---

## 1. A DSH upgrade removes local plugins from the profile

Upgrading DSH (here: `0.1.5-rc.2` → `0.1.7-rc.2`, Desktop `0.9.2`) **rewrites**
`profiles/web/package.json`. The plugin's `dependencies` entry and its
`dsh.profile.bundles` entry were both dropped, while the `pnpm.overrides` `link:`
row **survived** — leaving an inconsistent state that looks half-installed.

**After every DSH upgrade, verify all three entries exist:**

| Location | Expected |
| --- | --- |
| `dependencies` | `"dsh-desktop-hand": "link:/absolute/path/to/dsh-desktop-hand"` |
| `dsh.profile.bundles` | the array contains `"dsh-desktop-hand"` |
| `pnpm.overrides` | the same `link:` row as `dependencies` |

> ⚠️ `overrides` **without** `dependencies` + `bundles` is an inert state —
> the plugin will not load. All three are required.

Then `pnpm install` in the profile directory and restart DSH.

---

## 2. The breaking change: `systemPrompt.section()` requires a finite `order`

```js
// @deepseek-ai/dsh-system-prompt/lib/index.js:241   (0.1.7-rc.2)
section(section) {
  if (!Number.isFinite(section.order)) {
    throw new TypeError(`prompt section "${section.name}" order must be a finite number`);
  }
  return this.layers.effect(/* ... */);
}
```

`context()` carries the same guard (`:267`). These lines did not exist in
`0.1.5-rc.2`, where omitting `order` was tolerated.

> Note that the official `dsh-tool-pwsh` always passed an `order`
> (`dsh-tool-pwsh/lib/index.js:228-232`, via `getSectionOrder("TOOL_PWSH")`).
> The field was always intended to be supplied — the older version simply did not enforce it.

### Valid order values

`SECTION_ORDERS` (`dsh-system-prompt/lib/index.js:10-43`) is **not exported**, so
third-party plugins must hardcode a literal:

| Range | Sections |
| --- | --- |
| `-1000` | `HARNESS_IDENTITY` |
| `0` | `DEPLOYMENT_PERSONA_PREFIX` |
| `500` / `600` / `800` / `900` | `PLAN_POLICY`, `TEAM_POLICY`, `PTC_ONLY`, `FILE_REFERENCE` |
| `1000` … `1700` | `TOOL_BASH`, `TOOL_PWSH`, `TOOL_READ`, `TOOL_WRITE`, `TOOL_EDIT`, `TOOL_GLOB`, `TOOL_GREP`, `TOOL_JOBS`, `TOOL_PTY` |
| `2000` … `2900` | `TOOL_WEB_SEARCH` … `TOOL_REPORT` |
| **`3000`** | **`TOOL_COMPUTER_USE`** |
| `3100` | `MCP_SERVERS` |
| `5000` / `9000` / `9900` | `TOOLS_SDK`, `DELIVERABLE_FILE_REFERENCES`, `STRUCTURED_OUTPUT` |
| `10000` / `10100` / `10200` | `HARNESS_SOURCE`, `WEB_SURFACE`, `DEPLOYMENT_PERSONA_SUFFIX` |

This plugin uses **`3001`** — immediately after the official `TOOL_COMPUTER_USE`
slot, before `MCP_SERVERS`, which is where a desktop-control description belongs.

---

## 3. The incident: a required plugin throwing takes down all of DSH

At the end of boot, `dsh-app-boot` runs `auditStartupEntries`. **If any
`required: true` plugin fails to apply, the whole startup fails** and the app enters
safe mode (`resources/safe-mode.html`). From
`%APPDATA%\dsh-desktop\harness\logs\startup-*.log`:

```
StartupError: dsh: startup failed: 1 required plugin did not activate

Failed plugins (1):
  desktop-hand (required)
    Package: dsh-desktop-hand
    TypeError: prompt section "tool:desktop-hand" order must be a finite number
```

**Secondary damage:** entering safe mode **rewrites the profile's `package.json`**,
removing the failing plugin's `dependencies` and `dsh.profile.bundles` entries —
while leaving `pnpm.overrides` behind (the inconsistent state described in §1).

### Root cause and fix (v1.0.0 → v1.0.1)

`v1.0.0` called `systemPrompt.section({ name, text })` with **no `order`**. Two
changes, both required:

1. **Supply `order: 3001`.**
2. **Wrap the whole prompt-section registration in `try/catch`, warning instead of
   throwing.** A system-prompt section is decorative — the six tools do not depend
   on it — and it must never be able to take down the host.

### Reproduced against the real service

The failure was reproduced using the real `dsh-system-prompt` module: omitting
`order` produces an error **byte-identical** to the startup log. With the fix,
`Number.isFinite(3001)` passes.

Regression tests now assert, in `lib/selftest.mjs`:

- `order` is a finite number, within the `3000–3100` band;
- `apply()` still succeeds when `section()` is made to throw.

---

## 4. Interfaces verified unchanged in 0.1.7-rc.2

Checked individually rather than assumed:

| Interface | Status |
| --- | --- |
| `defineTool({ name, description, parameters, output, execute })` | unchanged (`dsh-tools/lib/types/schema.js:274`) |
| `finalizeContent(exec, result)` hook | unchanged (`schema.js:325`) |
| `applyFinalContent` / `contentFinalizers` | unchanged (`dsh-tools/lib/index.js:3399`) |
| `ctx.tools.register(definition)` | unchanged (`:2878`) |
| `ctx.subprocess.spawn(spec)` requiring a finite positive `graceMs` | unchanged |
| `handle.collected.stdout.finalize()` to read output | unchanged |
| `attachments.saveImage({ data, mediaType, name })` / `imageLimits` | unchanged (`dsh-attachment/lib/index.js:218-232`) |
| Tool-name validation | **newly stricter**: reserved words and `__x__` forms restricted; ordinary lowercase snake_case names are unaffected |

Parameter schemas are a flat property map validated by `defineTool` — not
`schemastery` (which is only for the plugin's own `Config`).

---

## 5. Post-upgrade checklist

**Before restarting** — confirm the plugin itself is healthy, without DSH:

```powershell
.\lib\link-deps.ps1
.\lib\selftest.ps1
node .\lib\selftest.mjs
node .\lib\selftest-harness.mjs
.\lib\occlusion-test.ps1
.\lib\link-deps.ps1 -Clean
```

These run standalone, so a failing one means the plugin needs a fix — not that DSH
is at fault.

**After restarting** — confirm the plugin did not break startup:

```powershell
Get-ChildItem "$env:APPDATA\dsh-desktop\harness\logs\startup-*.log" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1 |
  Get-Content -TotalCount 40
```

**A plugin load failure always writes `startup failed` / `required plugin did not
activate` to this log.** It never fails silently — if those strings are absent, the
plugin loaded.

---

## 6. Migrating to a differently-packaged DSH (DSH NEXT)

Switching from DSH Desktop to **DSH NEXT** (`2.0.17-next`) moves two paths at once.
Both are silent failures if missed:

| What | Old | New |
| --- | --- | --- |
| App modules (for self-tests) | `C:\Program Files\DSH Desktop\resources\app` | `D:\Program\DSH\DSH NEXT\resources\app` |
| Harness home / profile | `%APPDATA%\dsh-desktop\harness\profiles\web` | `%USERPROFILE%\.dsh\profiles\web` |

**1. `link-deps.ps1` must learn the new app path.** It auto-detects, but the
candidate list is finite — if the new install is not in it, the script reports
*"未找到 DSH 安装目录"* and links only what the profile happens to provide. That is
the dangerous outcome, because a **stale** link still resolves: the self-tests then
validate a different `dsh-tools` version than the one that actually runs, and DSH's
`host-module-fallback` never triggers (it only fires on
`ERR_MODULE_NOT_FOUND`). Always confirm the printed line:

```
DSH 安装目录: ...\resources\app\node_modules\@deepseek-ai  (dsh-tools 0.2.0-rc.2)
```

**2. The profile's `node_modules` is not carried over.** `package.json` may still
list the plugin in `dependencies` and `dsh.profile.bundles` while `node_modules`
simply does not exist — the bundle is declared but never installed, so the plugin is
dead config rather than a broken plugin. Check the link resolves:

```powershell
Get-Item "$env:USERPROFILE\.dsh\profiles\web\node_modules\dsh-desktop-hand" |
  Select-Object LinkType, Target
```

Expected: `Junction` → your checkout. Then `pnpm install` in the profile directory.

**3. Use the toolchain that ships with the *new* install.** DSH NEXT has no bundled
`node.exe`, and a leftover `%APPDATA%\dsh-desktop\harness\.desktop-bin\pnpm.cmd`
still points at the **old, deleted** app path, failing with
*"The system cannot find the path specified"*. Drive pnpm through the new install
with a system Node that satisfies `engines` (`^22.19.0 || >=24.0.0`):

```powershell
node "D:\Program\DSH\DSH NEXT\resources\app\node_modules\pnpm\bin\pnpm.cjs" install `
  --dir "$env:USERPROFILE\.dsh\profiles\web"
```

> pnpm 11 warns `The "pnpm" field in package.json is no longer read ... "pnpm.overrides"`.
> For this plugin that is **harmless**: `dependencies` carries the same `link:` spec,
> which is what pnpm actually resolves to the junction. The warning is only a concern
> for plugins that rely on `overrides` alone.

**4. Verify the load without restarting DSH.** Import the plugin through the real
profile path and drive `apply()` with a stub context — this catches an `apply()` that
would otherwise abort startup:

```js
const mod = await import('file:///C:/Users/<you>/.dsh/profiles/web/node_modules/dsh-desktop-hand/lib/index.js');
await mod.apply(stubCtx, {});   // must not throw; registers the six desktop_* tools
```

**5. Make sure you wrote to the profile DSH actually loads.** A DSH NEXT install
here had **two** profiles on disk — `web` (carried over in name from the old
machine) and `desktop` (created fresh by DSH NEXT, and the one in use). Installing
into the wrong one produces a perfectly healthy plugin that never appears, with **no
error anywhere**, because the other profile is simply not the one being composed.

Tell them apart by modification time, not by name:

```powershell
Get-ChildItem "$env:USERPROFILE\.dsh\profiles" -Directory |
  Select-Object Name, LastWriteTime
```

The active profile is the one whose timestamp moves when DSH starts. Confirm its
bundle list actually names the plugin, and that *that* profile's `node_modules`
resolves — a link in the other profile proves nothing:

```powershell
$act = "$env:USERPROFILE\.dsh\profiles\desktop"   # <- the one you verified above
(Get-Item "$act\node_modules\dsh-desktop-hand").Target
```

---

## 7. Two silent-failure traps in the tool-result serialization path

Both of these surfaced the same way — a *different* agent's tool call failing with:

```
tool result must be losslessly JSON-serializable
```

They were two distinct bugs on two distinct paths (success and error), and neither
was visible from the plugin's own code review. Recorded because the mechanism is
sharp and easy to reproduce.

### 7.1 The rule: an `undefined` **property value** rejects the whole result

The validator is `materializePresentation` (`dsh-tools/lib/index.js:2604`):

```js
function materializePresentation(candidate) {
  const detached = snapshotJsonValue(candidate);
  if (detached === void 0) throw new TypeError("tool result must be losslessly JSON-serializable");
  return deepFreeze(detached);
}
```

`snapshotJsonValue` (`dsh-util-values/lib/index.js:159`) walks the value **strictly**.
Verified by experiment, these all reject the entire result:

- **any property whose value is `undefined`** — it is *not* coerced to `null`
- functions, `Symbol`, `BigInt`, `NaN`, `Infinity`
- `Date` instances, circular references, arrays containing `undefined`

**`null` is fine.** That distinction is the whole game: `null` is a value you may
send, `undefined` is a hole that discards everything around it.

Do not confuse this error with the *other* validator. They produce different text:

| Cause | Message |
| --- | --- |
| value is `undefined` / unserializable | `tool result must be losslessly JSON-serializable` |
| extra key, given `additionalProperties: false` | `tool "x" returned invalid output: unexpected key "y"` |

### 7.2 Bug one — success path, fields copied straight from the engine

`desktop_capture` and `desktop_list_windows` passed engine fields through directly
(`bytes: payload.bytes`, `handle: w.handle`). Whenever the engine omitted one — an
error shape, an older engine, a partially-built window record — the property existed
with value `undefined` and the **entire successful result was thrown away**.

Reproduced exactly by building a fake engine that omits `bytes`: the tool then
returned an object carrying `undefined`, and the error matched the user's report
character for character.

**Fix:** required fields get `String()` / `Number.isFinite()` coercion; optional
fields are *omitted* rather than set to `undefined`:

```js
...(x === undefined || x === null ? {} : { k: x })   // correct
{ k: x }                                              // wrong when x is undefined
```

### 7.3 Bug two — error path, and the `in`-operator trap

The harder one. `errorInfo` (`dsh-tools/lib/index.js:2608`) builds the `error` field
of a *failed* result:

```js
function errorInfo(error) {
  try { return error instanceof HarnessError ? { name: error.name, code: error.code } : void 0; } ...
}
```

and `materializeFinalResult` submits `error: result.error` to the same strict walk —
**so error results are validated too.**

The plugin's `EngineError` unconditionally ran `this.code = payload.code`. When the
engine returned `{ ok: false, error }` with no `code`, that assignment **created the
property** with value `undefined`. Hence:

- the guard is effectively `"code" in e` → **`true`** (the key exists!)
- `errorInfo()` therefore returned `{ name: 'EngineError', code: undefined }`
- the whole error result was rejected, and **the real error message was replaced by
  the serialization error** — hiding the actual fault

The trap worth remembering: **assigning `undefined` creates a property**, so an
`in` check reports it as present, while `JSON.stringify` silently drops the key and
makes it look absent. Two observers of the same object disagree:

```js
const e = new EngineError({ error: 'failed' });   // engine sent no `code`
'code' in e          // true   ← the guard in errorInfo() sees this
Object.keys(e)       // ['code']
JSON.stringify(e)    // {"name":"Error"}  — no `code` at all
```

So the branch that decides whether to include `code` takes the "yes" path, while
anything inspecting the shape by serialization cannot see the problem. Verified
against the real `errorInfo` guard, not just reasoned about.

**Fix:** only set `code` when it carries a value.

```js
const code = payload.code;
if (code !== undefined && code !== null && code !== '') this.code = code;
```

Verified across four shapes (absent / present / empty string / `null`), and the real
message now reaches the model, e.g. `Error: 抓取失败：窗口已关闭`.

### 7.4 Guarding against regressions structurally

Fixing the two known sites is not enough — the failure mode is "some new field
somewhere is `undefined`". `lib/selftest.mjs` therefore walks **every tool path** and
scans the returned value, `render` output, and `finalizeContent` output for
`undefined` / functions / `Symbol` / `BigInt` / `NaN` / `Infinity` (§5), and builds
each throwing path through a replica of `toolErrorResult()` to scan error results too
(§5b).

Two things make the scanner trustworthy rather than decorative:

- **It is validated in reverse.** Reverting one line of the fix immediately makes it
  report `bytes: undefined`. A scanner that has never failed has not been tested.
- **§5b pins the mechanism directly**, asserting that `EngineError` does *not* create
  a `code` property when the engine omits it, and that `code: undefined` is
  recognized as harmful — so the `in`-operator trap cannot silently return.
