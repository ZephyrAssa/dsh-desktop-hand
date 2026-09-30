# dsh-desktop-hand

**Hands and eyes for a DSH agent on Windows.** Capture any window's own content
*even while it is fully occluded*, click by coordinate, type Unicode text that
bypasses the IME, and focus windows — all as agent-callable tools.

> A plugin for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness).
> **Windows only** (uses `user32` / `gdi32` / `shcore` via PowerShell 5.1).

---

## Why this exists

I surveyed 8 DSH plugins that can touch the desktop. **Not one had all four of
these capabilities *plus* occluded-window capture:**

| Plugin | Window capture | Click | Keyboard | Focus | **Occluded capture** |
| --- | :-: | :-: | :-: | :-: | :-: |
| **dsh-desktop-hand** | ✅ | ✅ | ✅ | ✅ | ✅ **PrintWindow** |
| Altairpaca/dsh-computer-use-windows | ✅ | ✅ | ✅ | ✅ | ❌ `CopyFromScreen` clipped to window rect |
| cbg33695/dsh-screen-reader | ✅ | ❌ | ❌ | ❌ | ✅ |
| @paicat1/dsh-screenshot | hover-snap only | ❌ | ❌ | ❌ | ✅ |
| 988hj7tczd-oss/dsh-computer-use | ✅ | ✅ | ✅ | ✅ | ⚠️ unverified |
| ysr666/dsh-vision-router | ❌ virtual screen only | ❌ | ❌ | ❌ | ❌ |
| ankye/dsh-client-vision | ✅ by id | ❌ | ❌ | ❌ | ❌ |
| FuqiangCraft/dsh-desktop | ❌ primary display only | ❌ | ❌ | ❌ | ❌ |

The ecosystem splits cleanly in half:

- plugins that use **PrintWindow** (so occlusion works) **never touch input**;
- plugins that **inject input** capture windows with `CopyFromScreen` — so an
  occluded window returns *whatever is covering it*.

The one four-capability plugin (Altairpaca) has no `PrintWindow` call anywhere in
its `helper/cu.ps1`, and `988hj7tczd-oss/dsh-computer-use` — architecturally the
most serious of the group — explicitly marks Windows as **⛔ BLOCKED / unvalidated**.

This plugin fills that specific gap.

### Proof, not a claim

Target window fully covered by a maximized blocker, both captures at the same instant:

| Capture mode | Result |
| --- | --- |
| full screen (`CopyFromScreen`) | 2560×1440 — **only the blocker**; target invisible |
| target window (`PrintWindow`) | 1115×628 — **target's own title bar and content visible** |

`lib/occlusion-test.ps1` builds this scenario and prints objective pass/fail criteria.

---

## Tools

| Tool | Purpose |
| --- | --- |
| `desktop_diagnose` | Health check: can synthetic input be trusted *right now*? |
| `desktop_list_windows` | Enumerate windows: handle, PID, process, title, rect, UWP / minimized flags |
| `desktop_capture` | Full screen / a specific window (by title or handle) / region crop. **Returns the image to the model directly** — no second `read_image` call |
| `desktop_focus` | Bring a window to the foreground, and *report whether it truly became foreground* |
| `desktop_click` | Click / double-click / right-click / drag, with landing-point verification |
| `desktop_type` | Type text (Unicode injection) or send a whitelisted key / combo |

Typical flow:

```
desktop_list_windows           → find the target, take its handle
desktop_capture(handle=...)    → look at it, measure coordinates
desktop_focus(handle=...)      → or desktop_click the window body to get focus
desktop_type(text="...")       → type
desktop_capture(handle=...)    → look again to confirm
```

---

## Install

```bash
dsh plugin --profile web add github:YOURNAME/dsh-desktop-hand
```

Or manually — clone anywhere, then add **all three** entries to your profile's
`package.json` (`~/.dsh/profiles/web/package.json`):

```jsonc
{
  "dependencies": {
    "dsh-desktop-hand": "link:/absolute/path/to/dsh-desktop-hand"
  },
  "dsh": {
    "profile": {
      "bundles": [ /* ...existing..., */ "dsh-desktop-hand" ]
    }
  },
  "pnpm": {
    "overrides": {
      "dsh-desktop-hand": "link:/absolute/path/to/dsh-desktop-hand"
    }
  }
}
```

Then run `pnpm install` inside the profile directory and restart DSH
(the bundle list is read at startup).

> ⚠️ **Use the bundle channel OR a manual `cordis.patch.yml` mount row — never both.**
> Declaring it twice double-mounts the plugin; tool registration then fails with
> "already registered", which can prevent DSH from starting.

> ⚠️ **A DSH upgrade rewrites the profile and drops local plugin entries.**
> After upgrading, re-check all three entries above, `pnpm install`, and restart.
> See [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md) — including a startup-failure
> incident this plugin caused before it was hardened.

### Requirements

- Windows 10/11
- PowerShell 5.1 (ships with Windows)
- Node `^22.19.0 || >=24.0.0`

---

## Configuration

Supplied as the plugin's `config` in the profile:

| Key | Default | Meaning |
| --- | --- | --- |
| `enginePath` | bundled `lib/desktop-hand.ps1` | Engine script path |
| `timeoutMs` | `60000` | Per-call timeout (first call compiles `Add-Type`, ~1.2 s) |
| `outputDir` | system temp | Default directory for captured PNGs |

---

## Design constraints (read before changing anything)

Each of these was learned the hard way and is load-bearing.

**1. Window capture uses `PrintWindow` + `PW_RENDERFULLCONTENT(2)`.**
This is the whole point of the plugin. Only `PrintWindow` retrieves an occluded
window's *own* content; `CopyFromScreen` returns whoever is on top. The flag
**must** be `2`: `flag=0` yields 100% black for UWP windows, `flag=2` reduces that
to 71.7%.

**2. Text injection uses `SendInput` + `KEYEVENTF_UNICODE`.**
**Not** `VkKeyScan` + `keybd_event` — that path runs through the keyboard
layout / IME layer, and a Chinese IME rewrites it. Measured: asking for
`third batch` delivered 「第三批」. Unicode direct injection bypasses the IME, so
Chinese text and format specifiers like `%.15f` arrive intact.

**3. Coordinates are physical pixels, with DPI awareness declared.**
At 2560×1440 with 150% scaling, without declaring DPI awareness
`SetCursorPos(42,1046)` lands at physical (56,1395), while `GetCursorPos` divides
back and reports (1280,720) — "the click isn't where I said it was". Declaring it
makes coordinates 1:1. Capture results include `coordScale` when a screenshot's
width differs from the physical screen width.

**4. Console output must be explicitly UTF-8.**
PowerShell 5.1 encodes redirected stdout using the **console ANSI code page**
(GBK/936 on the dev machine), while Node decodes as UTF-8 — so every non-ASCII
error message becomes mojibake. The engine sets
`[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` as its first action.
**Removing that line does not error; it silently corrupts every message.**

**5. Subprocesses go through the harness seam, not raw `spawn`.**
Official plugins use `ctx.subprocess.spawn`. This is not merely style: **the DSH
sandbox rejects Node spawning a child with piped stdio** (raw `spawn` → `EPERM`;
`stdio: 'inherit'` works). The plugin uses `ctx.subprocess`, keeping raw `spawn`
only as a fallback for standalone testing.

Three contracts there are silent-failure traps — all asserted in
`lib/selftest-harness.mjs`:

| Contract | Failure mode if missed |
| --- | --- |
| `graceMs` is **required** | every call throws |
| `handle.collected.stdout` is a *collector*; call `finalize()` for `{ text }` | reading `.text` yields `undefined`; every tool reports "no output" |
| the spec has **no** `timeoutMs` field — the caller owns the deadline | the timeout silently never fires |

**6. A required plugin must never throw from `apply()`.**
If a plugin is listed as required and `apply()` throws, **the entire DSH startup
fails** and the app enters safe mode — which rewrites the profile and removes the
plugin. Cosmetic extras (such as the system-prompt section) are therefore wrapped
in `try/catch` and only warn on failure. See
[`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md).

---

## Known boundaries (not bugs)

- **UWP apps cannot be captured** (Settings, Calculator, …). `PrintWindow` is blind
  to DirectComposition-rendered UWP content, and there is no workaround from
  PowerShell (WGC would require MSIX package identity). The tool returns
  `uwpWarning` — **do not judge UI state from that image.**
- **Minimized windows** degenerate in size; the capture is meaningless.
  The result carries `minimized: true`.
- **An active remote-control session makes synthetic clicks unreliable.** While
  someone is driving the real cursor remotely, synthetic coordinates are
  continuously overwritten — no amount of coordinate tuning helps. Use
  `desktop_diagnose` to confirm, then wait for the remote session to go idle.
  **Do not kill the remote-control process**; that drops the remote connection.
- **Windows only.**
- The black-pixel ratio is reported for reference and is **not** a success test: a
  UWP host measured 2.9% black while being an empty frame. **Look at the image.**

---

## Tests

```powershell
.\lib\link-deps.ps1               # link peer deps for standalone runs
.\lib\selftest.ps1                # 32 checks — engine
node .\lib\selftest.mjs           # 79 checks — tool layer (incl. version-compat regressions)
node .\lib\selftest-harness.mjs   # 18 checks — harness subprocess seam contract
.\lib\occlusion-test.ps1          #  7 checks — occluded capture (inspect the images)
.\lib\link-deps.ps1 -Clean
```

**136 checks, 0 failures**, stable across repeated runs. The keyboard round-trip is
verified objectively: the typed text changes the target window's title, which is
then read back — including a Chinese case that would fail if the IME were not bypassed.

---

## Layout

```
dsh-desktop-hand/
├── package.json                  dsh.bundle.patch is the field that makes it loadable
├── cordis.patch.yml              bundle mount declaration
├── README.md
├── docs/
│   ├── COMPATIBILITY.md          DSH version compatibility & the startup-failure incident
│   └── ENGINEERING-NOTES.zh-CN.md  detailed field notes (Chinese)
├── skills/desktop-hand/          agent-facing skill
└── lib/
    ├── index.js                  6 defineTool registrations + attachment image return
    ├── desktop-hand.ps1          PowerShell engine
    ├── selftest.ps1              engine checks
    ├── selftest.mjs              tool-layer checks
    ├── selftest-harness.mjs      subprocess-seam contract checks
    ├── occlusion-test.ps1        occluded-capture proof
    └── link-deps.ps1             create/remove peer-dep links for standalone runs
```

---

## Credits & scope

The `PrintWindow`, Unicode-injection, and DPI-awareness findings come from earlier
field notes on the author's machine; this plugin packages them as a globally
installable DSH plugin so any workspace can use them.

The detailed engineering notes — including every bug hit during development and how
it was diagnosed — are kept in Chinese in
[`docs/ENGINEERING-NOTES.zh-CN.md`](docs/ENGINEERING-NOTES.zh-CN.md), in the language
they were diagnosed in. The English sections here are a faithful summary.

MIT licensed — see [`LICENSE`](LICENSE).
