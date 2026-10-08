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
node .\lib\verify-serialization-contract.mjs   # re-checks section 7 against the new build
.\lib\occlusion-test.ps1
.\lib\link-deps.ps1 -Clean
```

These run standalone, so a failing one means the plugin needs a fix — not that DSH
is at fault. On a version bump pay particular attention to
`verify-serialization-contract.mjs`: it reads the host's source and asserts the
behaviour section 7 depends on, so if an upgrade closes the async trap or changes
what the validator rejects, it fails there instead of in production.

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
| App modules (for self-tests) | `<old install>\resources\app` | `<new install>\resources\app` |
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
node "<new install>\resources\app\node_modules\pnpm\bin\pnpm.cjs" install `
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

## 7. Three silent-failure traps in the tool-result serialization path

Both of these surfaced the same way — a *different* agent's tool call failing with:

```
tool result must be losslessly JSON-serializable
```

They were **three** distinct bugs on three different paths — the success path, the
error path, and a hook's return type (§7.5) — and none was visible from the plugin's
own code review. Recorded because the mechanism is sharp and easy to reproduce, and
because the single message gives no hint which of the three you are looking at.

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
- **a `Promise`** — see §7.5; this is what an `async` hook accidentally produces

**`null` is fine.** That distinction is the whole game: `null` is a value you may
send, `undefined` is a hole that discards everything around it.

Do not confuse this error with the *other* validator. They produce different text:

| Cause | Message |
| --- | --- |
| value is `undefined` / unserializable | `tool result must be losslessly JSON-serializable` |
| extra key, given `additionalProperties: false` | `tool "x" returned invalid output: unexpected key "y"` |

This one message had **three** distinct causes in this plugin, across the success
path, the error path, and a hook's return type. When you see it, do not assume you
already know which one you have.

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

Fixing the known sites is not enough — the failure mode is "some new field
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

### 7.5 Bug three — an `async` `finalizeContent`, and why review misses it

This was the **original** cause of every `desktop_capture` call failing, and it is the
sharpest of the three.

`finalizeContent` is the official hook for appending content blocks after execution —
which is how a capture tool attaches its image, since `output.schema` is
`additionalProperties: false` and the return value cannot carry an image block.
Written naturally it looks async; it is not. The contract
(`dsh-tool-cordis/lib/types/api-catalog.js:7532`) is:

```ts
execute(args, exec): Promise<unknown>;
projectContent?(exec, result): ContentBlock[] | undefined;
finalizeContent?(exec, result): ContentBlock[] | undefined;   // <- no Promise
```

and the caller (`dsh-tools/lib/index.js:3399-3407`) does **not** await:

```js
applyFinalContent(exec, result) {
  const finalizeContent = this.contentFinalizers.get(exec);
  if (finalizeContent === void 0) return result;
  const content = finalizeContent(exec, result);          // line 3402 — no await
  return content === void 0 ? result : { ...result, content };
}
```

So an `async` hook puts a **Promise** into `content`. A Promise's prototype is not
`Object.prototype`, so `snapshotJsonValue` returns `undefined` and
`materializePresentation` throws. Worse, `finishScheduledExecution` (`:3392-3394`)
then replaces the **entire successful result — including the already-rendered capture
text — with that error**, which is why the symptom is "the PNG is written correctly
but the tool reports failure".

Reproduced against the real `snapshotJsonValue`, transcribing `applyFinalContent`
verbatim:

```
A) async finalizeContent
   is a Promise?      : true
   snapshotJsonValue  : undefined
   materialize        : THREW -> tool result must be losslessly JSON-serializable
B) sync finalizeContent
   is Array?          : true
   materialize        : passed
```

**Why this survived a first review.** Any experiment that awaits the value before
inspecting it passes — the await hides the defect:

```
C) same async finalizer, but awaited first
   is Array?          : true     <- looks perfectly fine
```

Only the real, un-awaited `:3402` path exposes it. When testing a hook like this,
drive it through the actual caller; do not call it and await the result yourself, or
you are testing your `await` rather than the contract.

**Fix:** make the hook synchronous and move all async work (saving the image) into
`execute()`, stashing the prepared block in module-level state that the sync hook
reads back. The implementation and this reasoning are recorded in a comment at
`lib/index.js:571-595` so it is not "simplified" back into an `async` function later.

### 7.6 Guarding the contracts themselves

`lib/selftest.mjs` proves our *code* is correct against the host's behaviour. It
cannot catch the host *changing* that behaviour. `lib/verify-serialization-contract.mjs`
therefore reads `dsh-tools` / `dsh-util-values` source directly and pins the four
facts this section depends on:

| Guard | Fails when |
| --- | --- |
| `snapshotJsonValue` accepts/rejects | an upgrade starts accepting `undefined`, `NaN`, `Date`, … or stops accepting `null` |
| `applyFinalContent` has no `await` | upstream starts awaiting the hook — the async trap closes and 7.5 must be rewritten |
| `lib/index.js` declares no `async finalizeContent` | our own hook regresses |
| `EngineError` guards its `code` assignment | the `in`-operator trap of 7.3 returns |

It resolves the DSH install the same way `link-deps.ps1` does and prints the
`dsh-tools` version it validated, so a stale install cannot make it pass against the
wrong build. Where no desktop install is present — CI, for instance — it prints
`SKIP` and exits 0, because the npm build of `dsh-tools` differs from the desktop one.

Like the §5 scanner, it is validated in **reverse**: reverting the `EngineError` guard
makes it fail immediately with
`EngineError assigns code unconditionally -- see docs/COMPATIBILITY.md 7.3`.
