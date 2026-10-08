<#
.SYNOPSIS
    dsh-desktop-hand 的 Windows 执行引擎。

.DESCRIPTION
    这不是"又一个截屏脚本"，而是把三份实测脚本里**验证过的那些坑**固化下来的产物。
    所有设计约束都有实测依据，改动前先读这段和同目录 README 的"为什么"章节。

    四条硬约束（踩过的坑，不要"优化"掉）：

    1) DPI 感知必须每一层都声明。
       本机 2560x1440 + 150% 缩放。没声明 DPI 感知时 SetCursorPos(42,1046) 会被
       系统乘 1.333 落到物理 (56,1395)，而 GetCursorPos 又除回去报 1280,720。
       表现是"点的位置和说的不一样"。声明后坐标 1:1 直达物理像素。
       ⚠️ 只声明一次不够：SetProcessDpiAwareness 必须在**任何窗口/DC 创建之前**，
         而且截图前要复核。capture 冷启动第一次抓到 1920x1080 就是因为这个竞态。

    2) 文本注入必须走 SendInput + KEYEVENTF_UNICODE，不能用 VkKeyScan + keybd_event。
       后者走键盘布局/输入法通路，中文输入法会在中间转换 —— 实测想输入
       "third batch"，MATLAB 收到的是「第三批」。Unicode 直投绕过输入法。

    3) 抓窗口必须用 PrintWindow + PW_RENDERFULLCONTENT(2)，不是 CopyFromScreen。
       只有 PrintWindow 能抓到**被遮挡**的窗口（实测 0% 黑像素）；
       全屏 CopyFromScreen 抓到的永远是遮挡者。
       flag 必须是 2：flag=0 对 UWP 是 100% 黑，flag=2 降到 71.7%，即 0 更糟。

    4) 绝不能用"黑像素比例"判定抓取成功。
       实测 UWP 宿主 ApplicationFrameWindow 黑像素仅 2.9%，图像却是空白框架。
       黑像素只作参考，判断成功与否必须看图。

    本脚本输出 JSON，由 lib/index.js 消费。

.PARAMETER Action
    list-windows | capture | click | move | drag | type | key | focus | info

.PARAMETER Json
    仅作标记（本脚本恒以 JSON 输出），保留是为了调用处语义清晰。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Action,

    # ---- capture ----
    [string]$Window,
    [Int64]$Handle = 0,
    [switch]$FullScreen,
    [string]$Region,              # "x,y,w,h"，相对被抓对象
    [string]$OutPath,
    [int]$ScreenIndex = -1,       # 指定显示器序号（-1 = 全部/虚拟屏）

    # ---- mouse ----
    [int]$X = 0,
    [int]$Y = 0,
    [int]$ToX = [int]::MinValue,
    [int]$ToY = [int]::MinValue,
    [switch]$Double,
    [switch]$Right,
    [int]$ShotWidth = 0,          # 坐标所依据的截图宽度；0 = 按物理屏宽（1:1）
    [int]$SettleMs = 30,          # 移到→按下 之间的等待，压到最小以躲远程鼠标

    # ---- keyboard ----
    [string]$Text,
    [string]$Key,
    [switch]$Enter,
    [int]$Delay = 0,

    # ---- focus ----
    [switch]$Restore,

    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# =====================================================================
#  输出编码 —— 必须是第一件事
# =====================================================================
# PowerShell 5.1 在 stdout 被重定向（管道/子进程捕获）时，默认按**控制台 ANSI 代码页**
# 编码输出，本机是 GBK(936)。Node 那边按 UTF-8 解码，中文就全成了乱码
# （实测错误信息变成乱码，模型读到的是无效字符串）。
# 把 OutputEncoding 显式设成 UTF-8 后，Node 侧 toString('utf8') 才是对的。
# ⚠️ 这行不能删：删掉不会报错，只会让所有中文提示变成乱码，很难查。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# =====================================================================
#  P/Invoke 层
# =====================================================================
if (-not ('DSKHand.Api' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

namespace DSKHand {

    public class WinInfo {
        public long Handle;
        public uint Pid;
        public int X, Y, W, H;
        public string Title;
        public string Class;
        public string Process;
        public bool IsUwp;
        public bool Minimized;
        public int BlackPermille;
        /// 是否是 ApplicationFrameHost 宿主壳（唯一真正抓不出内容的盲区）。
        /// 与 IsUwp 分开：CoreWindow 也是 UWP，但它能抓。
        public bool IsFrameHost;
    }

    /// 窗口类名的语义分类（2026-10-03 实测修正）。
    ///
    /// ⚠️ 历史错误：本文档与 SKILL.md 曾断言"UWP 应用是 PrintWindow 的盲区"。
    /// **该表述是错的，且会让人放弃一个本来能抓的窗口。** 实测对照：
    ///
    ///   | 窗口类名                        | 结果                                   |
    ///   | ------------------------------- | -------------------------------------- |
    ///   | Windows.UI.Core.CoreWindow      | **完整真实内容**（SystemSettings 418KB）|
    ///   | ApplicationFrameWindow          | 空白框架 + 齿轮 logo（31KB，零可操作信息）|
    ///
    /// 真正的判据是**类名**，不是"是不是 UWP"，也不是"是不是应用自己的进程"
    /// （本例两者恰好重合，极易被误当成因果）。
    ///
    /// CoreWindow：UWP 真实的 XAML 窗口，PrintWindow 抓得到 → 不该报警告。
    /// ApplicationFrameWindow：AFH 宿主壳，抓出来是空的 → 这才是唯一的盲区。
    public static class WinClass {
        public const string CoreWindow = "Windows.UI.Core.CoreWindow";
        public const string FrameHost = "ApplicationFrameWindow";

        /// UWP 真窗口：能抓，**不是**盲区。
        public static bool IsCoreWindow(string cls) { return cls == CoreWindow; }

        /// 宿主壳：抓出来可能是空白框架，需要提示。
        public static bool IsFrameHost(string cls) { return cls == FrameHost; }

        /// 宽泛的"与 UWP 有关"（仅用于列表标注，不用于决定警告）。
        public static bool IsUwpRelated(string cls) { return IsCoreWindow(cls) || IsFrameHost(cls); }
    }

    public class Shot {
        public string Path;
        public int Width, Height;
        public int BlackPermille;
        public string Target;
        public string TargetClass;
        public bool UwpWarning;
        public bool Minimized;
        public long Bytes;
        public bool BlackVerdict;
    }

    public class Api {
        // ---- window enumeration ----
        public delegate bool EnumProc(IntPtr h, IntPtr p);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextLengthW(IntPtr h);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);

        // ---- capture ----
        [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
        [DllImport("user32.dll")] public static extern IntPtr GetWindowDC(IntPtr h);
        [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr dc);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int cb);
        [DllImport("gdi32.dll")] public static extern int GetDeviceCaps(IntPtr hdc, int i);
        [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);

        // ---- dpi ----
        [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);   // 2 = PER_MONITOR
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("shcore.dll")] public static extern int GetProcessDpiAwareness(IntPtr p, out int v);

        // ---- mouse ----
        [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out PT p);
        [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);

        // ---- keyboard: Unicode direct injection ----
        [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);

        public const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;

        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
        [StructLayout(LayoutKind.Sequential)] public struct PT { public int X, Y; }

        [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL, wParamH; }
        [StructLayout(LayoutKind.Explicit)] public struct IU {
            [FieldOffset(0)] public KEYBDINPUT ki;
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public HARDWAREINPUT hi; }
        [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public IU u; }

        public const uint INPUT_KEYBOARD = 1, INPUT_MOUSE = 0;
        public const uint KU = 0x0002, UNICODE = 0x0004;
        public const uint MOVE = 0x0001, LEFTDOWN = 0x0002, LEFTUP = 0x0004,
                           RIGHTDOWN = 0x0008, RIGHTUP = 0x0010, ABSOLUTE = 0x8000;
        public const byte VK_RETURN = 0x0D, VK_ESCAPE = 0x1B, VK_TAB = 0x09;
        public const byte VK_CONTROL = 0x11, VK_SHIFT = 0x10, VK_MENU = 0x12;
        public const byte VK_A = 0x41, VK_C = 0x43, VK_V = 0x56, VK_S = 0x53, VK_X = 0x58, VK_Z = 0x5A, VK_W = 0x57;
        public const byte VK_UP = 0x26, VK_DOWN = 0x28, VK_LEFT = 0x25, VK_RIGHT = 0x27;
        public const byte VK_HOME = 0x24, VK_END = 0x23, VK_PRIOR = 0x21, VK_NEXT = 0x22;
        public const byte VK_DELETE = 0x2E, VK_BACK = 0x08, VK_SPACE = 0x20;
        public const byte VK_F1 = 0x70;

        /// 声明 DPI 感知。必须在任何窗口/DC 创建之前调用，否则拿到虚拟化坐标。
        public static string Aware() {
            int cur;
            try { if (GetProcessDpiAwareness(IntPtr.Zero, out cur) == 0 && cur >= 2) return "already:" + cur; } catch { }
            try { if (SetProcessDpiAwareness(2) == 0) return "shcore:2"; } catch { }
            try { if (SetProcessDPIAware()) return "user32"; } catch { }
            return "FAILED";
        }

        private static int _vw = 0, _vh = 0;
        /// 物理屏幕尺寸（所有显示器的包围盒）。
        public static void RefreshScreen() {
            IntPtr dc = GetDC(IntPtr.Zero);
            _vw = GetDeviceCaps(dc, 118);   // DESKTOPHORZRES
            _vh = GetDeviceCaps(dc, 117);   // DESKTOPVERTRES
            ReleaseDC(IntPtr.Zero, dc);
        }
        public static int ScreenW { get { if (_vw == 0) RefreshScreen(); return _vw; } }
        public static int ScreenH { get { if (_vh == 0) RefreshScreen(); return _vh; } }
        public static string PhysScreen() { return ScreenW + "x" + ScreenH; }

        public static string Cur() { PT p; GetCursorPos(out p); return p.X + "," + p.Y; }

        // ---------------- window enumeration ----------------
        public static List<WinInfo> ListWindows() {
            var list = new List<WinInfo>();
            EnumWindows((h, p) => {
                if (!IsWindowVisible(h)) return true;
                int len = GetWindowTextLengthW(h);
                var sb = new StringBuilder(len + 2);
                GetWindowTextW(h, sb, sb.Capacity);
                string title = sb.ToString();
                var cb = new StringBuilder(256);
                GetClassNameW(h, cb, cb.Capacity);
                string cls = cb.ToString();
                // 无标题的壳窗口没有操作价值，跳过（Shell_TrayWnd 等仍保留供测量）
                if (title.Length == 0 && cls != "Shell_TrayWnd") return true;

                uint pid; GetWindowThreadProcessId(h, out pid);
                RECT r; GetWindowRect(h, out r);
                string pname = "";
                try { pname = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }

                list.Add(new WinInfo {
                    Handle = (long)h, Pid = pid,
                    X = r.L, Y = r.T, W = r.R - r.L, H = r.B - r.T,
                    Title = title, Class = cls, Process = pname,
                    IsUwp = WinClass.IsUwpRelated(cls),
                    IsFrameHost = WinClass.IsFrameHost(cls),
                    Minimized = IsIconic(h)
                });
                return true;
            }, IntPtr.Zero);
            return list;
        }
        /// 按标题模糊匹配；返回所有命中（不擅自选第一个）。
        public static List<WinInfo> MatchWindows(string needle) {
            var all = ListWindows();
            var hit = new List<WinInfo>();
            string n = needle.ToLowerInvariant();
            foreach (var w in all)
                if (w.Title.ToLowerInvariant().Contains(n)) hit.Add(w);
            return hit;
        }

        public static WinInfo ByHandle(long h) {
            foreach (var w in ListWindows()) if (w.Handle == h) return w;
            // 句柄有效但不在可见列表（可能最小化）——仍构造一个
            IntPtr hp = (IntPtr)h;
            if (!IsWindow(hp)) return null;
            var cb = new StringBuilder(256); GetClassNameW(hp, cb, cb.Capacity);
            var tb = new StringBuilder(GetWindowTextLengthW(hp) + 2); GetWindowTextW(hp, tb, tb.Capacity);
            RECT r; GetWindowRect(hp, out r);
            uint pid; GetWindowThreadProcessId(hp, out pid);
            string pname = "";
            try { pname = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { }
            return new WinInfo {
                Handle = h, Pid = pid, X = r.L, Y = r.T, W = r.R - r.L, H = r.B - r.T,
                Title = tb.ToString(), Class = cb.ToString(), Process = pname,
                IsUwp = WinClass.IsUwpRelated(cb.ToString()),
                IsFrameHost = WinClass.IsFrameHost(cb.ToString()),
                Minimized = IsIconic(hp)
            };
        }

        // ---------------- focus ----------------
        /// SetForegroundWindow 会被前台锁挡掉（返回 True 但没生效）。
        /// AttachThreadInput + ALT 抖动是实测有效的组合。
        public static string Focus(IntPtr h) {
            if (!IsWindow(h)) return "invalid-handle";
            if (IsIconic(h)) ShowWindow(h, 9);   // SW_RESTORE
            IntPtr fg = GetForegroundWindow();
            if (fg == h) return "already-foreground";
            uint tidFg; GetWindowThreadProcessId(fg, out tidFg);
            uint myTid = GetCurrentThreadId();
            bool att = (tidFg != myTid) && AttachThreadInput(myTid, tidFg, true);
            try {
                keybd_event(VK_MENU, 0, 0, IntPtr.Zero);
                keybd_event(VK_MENU, 0, KU, IntPtr.Zero);
                SetForegroundWindow(h);
                BringWindowToTop(h);
            } finally { if (att) AttachThreadInput(myTid, tidFg, false); }
            System.Threading.Thread.Sleep(120);
            return GetForegroundWindow() == h ? "ok" : "failed(foreground-lock)";
        }

        public static string ForegroundTitle() {
            IntPtr h = GetForegroundWindow();
            var sb = new StringBuilder(GetWindowTextLengthW(h) + 2);
            GetWindowTextW(h, sb, sb.Capacity);
            var cb = new StringBuilder(256); GetClassNameW(h, cb, cb.Capacity);
            return sb.ToString() + " [" + cb.ToString() + "]";
        }

        // ---------------- capture ----------------
        /// PrintWindow 抓整个窗口（含被遮挡内容）。flag 必须为 2。
        public static Bitmap CaptureWindow(IntPtr h, out string err) {
            err = null;
            if (!IsWindow(h)) { err = "invalid-handle"; return null; }
            RECT r;
            // 优先用 DWM 扩展边框（去掉 Win10+ 的透明阴影边距）
            if (DwmGetWindowAttribute(h, DWMWA_EXTENDED_FRAME_BOUNDS, out r, Marshal.SizeOf(typeof(RECT))) != 0)
                GetWindowRect(h, out r);
            int w = r.R - r.L, hh = r.B - r.T;
            if (w <= 0 || hh <= 0) { err = "zero-size(minimized?)"; return null; }
            if (w > 20000 || hh > 20000) { err = "absurd-size:" + w + "x" + hh; return null; }

            var bmp = new Bitmap(w, hh, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bmp)) {
                IntPtr hdc = g.GetHdc();
                try {
                    // flag=2 PW_RENDERFULLCONTENT —— 关键
                    if (!PrintWindow(h, hdc, 2)) {
                        if (!PrintWindow(h, hdc, 0)) { err = "printwindow-failed"; }
                    }
                } finally { g.ReleaseHdc(hdc); }
            }
            return bmp;
        }

        /// 全屏抓取（CopyFromScreen）。只能抓到屏幕上可见的像素。
        public static Bitmap CaptureScreen(int screenIndex) {
            if (screenIndex >= 0) {
                var scr = System.Windows.Forms.Screen.AllScreens;
                if (screenIndex < scr.Length) {
                    var b = scr[screenIndex].Bounds;
                    var bm = new Bitmap(b.Width, b.Height, PixelFormat.Format32bppArgb);
                    using (var g = Graphics.FromImage(bm)) g.CopyFromScreen(b.X, b.Y, 0, 0, b.Size);
                    return bm;
                }
            }
            var full = new Bitmap(ScreenW, ScreenH, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(full)) g.CopyFromScreen(0, 0, 0, 0, new Size(ScreenW, ScreenH));
            return full;
        }

        /// 黑像素千分比。**仅作参考，不是成功判据**（UWP 反例见文件头）。
        /// 粗采样（约 120x120 个点）算黑像素千分比。
        /// 用 GetPixel 而非 LockBits/unsafe：本机是 PowerShell 5.1，其 Add-Type
        /// 内部的 CodeDom 编译器**不支持 unsafe**（没有 /unsafe 开关可传）。
        /// 采样点很少，GetPixel 的开销可以忽略，不值得为它引入不安全代码。
        public static int BlackPermille(Bitmap bmp) {
            int dark = 0, total = 0;
            int stepX = Math.Max(1, bmp.Width / 120), stepY = Math.Max(1, bmp.Height / 120);
            for (int y = 0; y < bmp.Height; y += stepY) {
                for (int x = 0; x < bmp.Width; x += stepX) {
                    Color c = bmp.GetPixel(x, y);
                    total++;
                    if (c.R < 12 && c.G < 12 && c.B < 12) dark++;
                }
            }
            return total == 0 ? 0 : (int)(1000L * dark / total);
        }

        /// 空白度判据：**按实测像素**判断"抓出来的图是不是空的"，
        /// 而不是按"这个窗口是不是 UWP"。理由见 WinClass 的注释：
        /// 旧逻辑用 IsUwp 触发 warning，导致 418KB 的完整图也带警告、
        /// 31KB 的空白框架同样只是"带警告"——警告完全失去区分力。
        ///
        /// 判据（2026-10-03 实测标定，本机 Win11 25H2）：
        ///
        ///   | 窗口                      | PNG 字节 | dominant‰ | distinctColors |
        ///   | ------------------------- | -------- | --------- | -------------- |
        ///   | ApplicationFrameWindow 壳 | 31,176   | 977       | **17**         |
        ///   | CoreWindow（真内容）      | 418,069  | 944       | **173**        |
        ///
        /// 关键区分量是 **distinctColors**（相差 10 倍），不是 dominant
        /// （两者都高：空白壳是纯色，真内容也有大片同色背景）。
        /// 阈值取 distinctColors <= 48：远高于 17、远低于 173，两侧都留足余量。
        /// 再要求主导色偏暗，避免把"纯白空白页"（如新建记事本）误判成抓取失败。
        ///
        /// ⚠️ 这里**不**看 blackPermille：实测空白壳只有 16‰（不黑）、
        /// 真内容反而 617‰（深色主题）——黑像素比例是反的，本就不能当判据。
        ///
        /// 用 GetPixel 的理由同 BlackPermille：PS5.1 的 Add-Type 不支持 unsafe。
        public static bool LooksBlank(Bitmap bmp, out int dominantPermille, out int distinctColors) {
            dominantPermille = 0; distinctColors = 0;
            var counts = new Dictionary<int, int>();
            int total = 0;
            int stepX = Math.Max(1, bmp.Width / 160), stepY = Math.Max(1, bmp.Height / 160);
            for (int y = 0; y < bmp.Height; y += stepY) {
                for (int x = 0; x < bmp.Width; x += stepX) {
                    Color c = bmp.GetPixel(x, y);
                    // 量化到 8 级/通道（>>5 = 每通道 32 级）：抗 PNG 压缩与亚像素抖动。
                    // 量化粒度直接决定 distinctColors 的量级，改这里要重新标定阈值。
                    int key = ((c.R >> 5) << 10) | ((c.G >> 5) << 5) | (c.B >> 5);
                    int n; counts.TryGetValue(key, out n);
                    counts[key] = n + 1;
                    total++;
                }
            }
            if (total == 0) return false;
            int best = 0, bestKey = 0;
            foreach (var kv in counts) if (kv.Value > best) { best = kv.Value; bestKey = kv.Key; }
            dominantPermille = (int)(1000L * best / total);
            distinctColors = counts.Count;
            int domR = ((bestKey >> 10) & 31) << 5, domG = ((bestKey >> 5) & 31) << 5, domB = (bestKey & 31) << 5;
            bool dominantIsDark = domR < 192 && domG < 192 && domB < 192;
            // 主导色占比高 + 颜色种类极少 + 主导色不亮 → 空白壳
            return dominantPermille >= 900 && distinctColors <= 48 && dominantIsDark;
        }

        // ---------------- mouse ----------------
        /// 点击：SetCursorPos 后**尽快**按下。等 140ms 会给远程鼠标插进来的时间窗。
        public static void Click(int x, int y, bool right, bool dbl, int settleMs) {
            SetCursorPos(x, y);
            if (settleMs > 0) System.Threading.Thread.Sleep(settleMs);
            uint d = right ? RIGHTDOWN : LEFTDOWN;
            uint u = right ? RIGHTUP : LEFTUP;
            MouseEvent(d); System.Threading.Thread.Sleep(40); MouseEvent(u);
            if (dbl) {
                System.Threading.Thread.Sleep(80);
                MouseEvent(d); System.Threading.Thread.Sleep(40); MouseEvent(u);
            }
        }

        public static void MoveTo(int x, int y) { SetCursorPos(x, y); }

        public static void Drag(int x1, int y1, int x2, int y2) {
            SetCursorPos(x1, y1);
            System.Threading.Thread.Sleep(120);
            MouseEvent(LEFTDOWN);
            System.Threading.Thread.Sleep(80);
            int steps = 24;
            for (int i = 1; i <= steps; i++) {
                SetCursorPos(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps);
                System.Threading.Thread.Sleep(15);
            }
            System.Threading.Thread.Sleep(80);
            MouseEvent(LEFTUP);
        }

        /// 用 SendInput 做绝对定位鼠标事件（比 mouse_event 更规范）。
        private static void MouseEvent(uint flags) {
            INPUT[] a = new INPUT[1];
            a[0].type = INPUT_MOUSE;
            a[0].u.mi.dwFlags = flags;
            SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
        }

        /// 设定后连续采样，判断光标是被"覆盖"还是"被拒绝"。诊断用。
        public static string Probe(int x, int y) {
            SetCursorPos(x, y);
            var sb = new StringBuilder();
            for (int i = 0; i < 5; i++) {
                System.Threading.Thread.Sleep(70);
                PT c; GetCursorPos(out c);
                sb.Append(c.X).Append(",").Append(c.Y).Append("  ");
            }
            return sb.ToString();
        }

        // ---------------- keyboard ----------------
        /// KEYEVENTF_UNICODE 直投：绕过输入法。这是能打进中文/格式符的关键。
        public static int TypeUnicode(string s) {
            int sent = 0;
            foreach (char c in s) {
                INPUT[] a = new INPUT[2];
                a[0].type = INPUT_KEYBOARD; a[0].u.ki.wVk = 0; a[0].u.ki.wScan = (ushort)c; a[0].u.ki.dwFlags = UNICODE;
                a[1].type = INPUT_KEYBOARD; a[1].u.ki.wVk = 0; a[1].u.ki.wScan = (ushort)c; a[1].u.ki.dwFlags = UNICODE | KU;
                if (SendInput(2, a, Marshal.SizeOf(typeof(INPUT))) != 2)
                    throw new Exception("SendInput(unicode) failed at char " + sent + ", err=" + Marshal.GetLastWin32Error());
                sent++;
                System.Threading.Thread.Sleep(5);
            }
            return sent;
        }

        public static void KeyVk(byte vk) {
            keybd_event(vk, 0, 0, IntPtr.Zero);
            System.Threading.Thread.Sleep(35);
            keybd_event(vk, 0, KU, IntPtr.Zero);
        }

        public static void KeyCombo(byte mod, byte vk) {
            keybd_event(mod, 0, 0, IntPtr.Zero);
            keybd_event(vk, 0, 0, IntPtr.Zero);
            System.Threading.Thread.Sleep(35);
            keybd_event(vk, 0, KU, IntPtr.Zero);
            keybd_event(mod, 0, KU, IntPtr.Zero);
        }

        /// 输入法状态查询（诊断用）：能解释"输入被打进别处/被转换"。
        public static string ImeState() {
            try {
                IntPtr h = GetForegroundWindow();
                IntPtr himc = ImmGetContext(h);
                if (himc == IntPtr.Zero) return "no-ime-context";
                int mode, sent;
                int conv = ImmGetConversionStatus(himc, out mode, out sent);
                ImmReleaseContext(h, himc);
                if (conv == 0) return "unknown";
                return "conversion=0x" + mode.ToString("X") + (mode == 0 ? " (English/off)" : " (IME OPEN)");
            } catch { return "query-failed"; }
        }
        [DllImport("imm32.dll")] public static extern IntPtr ImmGetContext(IntPtr h);
        [DllImport("imm32.dll")] public static extern bool ImmReleaseContext(IntPtr h, IntPtr c);
        [DllImport("imm32.dll")] public static extern int ImmGetConversionStatus(IntPtr c, out int mode, out int sent);
    }
}
'@ -ReferencedAssemblies System.Drawing, System.Windows.Forms
}

# =====================================================================
#  输出助手：恒输出 JSON
# =====================================================================
function Emit($obj) {
    $json = $obj | ConvertTo-Json -Depth 6 -Compress
    [Console]::Out.Write($json)
}

function Fail([string]$msg, [string]$code = 'ERROR') {
    Emit @{ ok = $false; error = $msg; code = $code }
    exit 1
}

# =====================================================================
#  DPI 感知 —— 第一件事，任何窗口/DC 创建之前
# =====================================================================
$dpiMode = [DSKHand.Api]::Aware()
[DSKHand.Api]::RefreshScreen()
$physW = [DSKHand.Api]::ScreenW
$physH = [DSKHand.Api]::ScreenH

if ($Delay -gt 0) { Start-Sleep -Milliseconds $Delay }

# =====================================================================
#  动作分发
# =====================================================================
try {
    switch ($Action.ToLower()) {

        # ---------------------------------------------------------------
        'info' {
            $fg = [DSKHand.Api]::ForegroundTitle()
            $remote = @(Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessName -match 'GameViewer|Sunlogin|ToDesk|AnyDesk|rustdesk|Parsec|TeamViewer|mstsc' } |
                Select-Object -ExpandProperty ProcessName -Unique)
            $displays = @()
            try {
                $displays = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
                    ForEach-Object { "$($_.Name) $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)" })
            } catch { }
            Emit @{
                ok = $true
                dpiMode = $dpiMode
                screenWidth = $physW
                screenHeight = $physH
                cursor = [DSKHand.Api]::Cur()
                foreground = $fg
                ime = [DSKHand.Api]::ImeState()
                remoteTools = $remote
                displays = $displays
                psVersion = $PSVersionTable.PSVersion.ToString()
            }
        }

        # ---------------------------------------------------------------
        'list-windows' {
            $all = [DSKHand.Api]::ListWindows()
            $items = @($all | Where-Object { $_.W -gt 0 -and $_.H -gt 0 } | Sort-Object -Property @{E={$_.Process}}, @{E={$_.Title}} |
                ForEach-Object {
                    @{
                        handle = $_.Handle; pid = $_.Pid
                        x = $_.X; y = $_.Y; width = $_.W; height = $_.H
                        title = $_.Title; class = $_.Class; process = $_.Process
                        uwp = $_.IsUwp; minimized = $_.Minimized
                        # 区分宿主壳：同一标题出现多个句柄时，该抓哪个靠这个字段判断
                        # （以前两个窗口都打 [UWP]，agent 只能盲选）。
                        frameHost = $_.IsFrameHost
                    }
                })
            $fgw = [DSKHand.Api]::GetForegroundWindow()
            Emit @{ ok = $true; count = $items.Count; foregroundHandle = [long]$fgw; windows = $items }
        }

        # ---------------------------------------------------------------
        'capture' {
            $bmp = $null
            $targetDesc = ''
            $targetClass = ''
            $isFrameHost = $false
            $uwpWarn = $false
            $minimized = $false
            $clipX = 0; $clipY = 0

            if ($Window -or $Handle -ne 0) {
                $w = $null
                if ($Handle -ne 0) {
                    $w = [DSKHand.Api]::ByHandle($Handle)
                    if ($null -eq $w) { Fail "窗口句柄 $Handle 无效或已关闭。" 'NO_SUCH_WINDOW' }
                } else {
                    $hits = @([DSKHand.Api]::MatchWindows($Window))
                    if ($hits.Count -eq 0) {
                        Fail "没有标题包含'$Window'的可见窗口。用 list-windows 看当前有哪些窗口。" 'NO_MATCH'
                    }
                    if ($hits.Count -gt 1) {
                        $cand = ($hits | ForEach-Object { "handle=$($_.Handle) title='$($_.Title)' process=$($_.Process)" }) -join ' | '
                        Fail "标题'$Window'匹配到 $($hits.Count) 个窗口，请用 handle 精确指定：$cand" 'AMBIGUOUS'
                    }
                    $w = $hits[0]
                }
                $targetDesc = $w.Title
                $targetClass = $w.Class
                $isFrameHost = $w.IsFrameHost
                $minimized = $w.Minimized
                # 窗口被抓时的原点（DWM 扩展边框）
                $rect = New-Object 'DSKHand.Api+RECT'
                $rc = [DSKHand.Api]::DwmGetWindowAttribute([IntPtr]$w.Handle, 9, [ref]$rect, 16)
                if ($rc -eq 0) { $clipX = $rect.L; $clipY = $rect.T } else { $clipX = $w.X; $clipY = $w.Y }
                $err = $null
                $bmp = [DSKHand.Api]::CaptureWindow([IntPtr]$w.Handle, [ref]$err)
                if ($null -eq $bmp) { Fail "抓取窗口失败：$err" 'CAPTURE_FAILED' }
            }
            else {
                $targetDesc = if ($ScreenIndex -ge 0) { "display[$ScreenIndex]" } else { 'virtual-screen' }
                $bmp = [DSKHand.Api]::CaptureScreen($ScreenIndex)
                if ($ScreenIndex -lt 0) { $clipX = 0; $clipY = 0 }
            }

            # 区域裁切（相对被抓对象）
            if ($Region) {
                $parts = $Region -split ','
                if ($parts.Count -ne 4) { Fail "Region 格式应为 `"x,y,w,h`"，收到：$Region" 'BAD_REGION' }
                $rx = [int]$parts[0]; $ry = [int]$parts[1]; $rw = [int]$parts[2]; $rh = [int]$parts[3]
                if ($rw -le 0 -or $rh -le 0) { Fail "Region 的宽高必须为正数：$Region" 'BAD_REGION' }
                if ($rx -lt 0 -or $ry -lt 0 -or ($rx + $rw) -gt $bmp.Width -or ($ry + $rh) -gt $bmp.Height) {
                    Fail "Region $Region 超出被抓对象范围 $($bmp.Width)x$($bmp.Height)。" 'REGION_OOB'
                }
                $crop = New-Object System.Drawing.Bitmap $rw, $rh
                $g = [System.Drawing.Graphics]::FromImage($crop)
                $g.DrawImage($bmp, (New-Object System.Drawing.Rectangle 0,0,$rw,$rh),
                             (New-Object System.Drawing.Rectangle $rx,$ry,$rw,$rh), [System.Drawing.GraphicsUnit]::Pixel)
                $g.Dispose()
                $bmp.Dispose()
                $bmp = $crop
                $clipX += $rx; $clipY += $ry
            }

            if (-not $OutPath) {
                $dir = Join-Path $env:TEMP 'dsh-desktop-hand'
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
                $OutPath = Join-Path $dir ("shot_{0:yyyyMMdd_HHmmss_fff}.png" -f (Get-Date))
            } else {
                $OutPath = [System.IO.Path]::GetFullPath($OutPath)
                $parent = Split-Path $OutPath -Parent
                if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            }

            $black = [DSKHand.Api]::BlackPermille($bmp)
            # 警告按**实测空白度**决定，不按"是不是 UWP"（2026-10-03 修正）。
            # 旧逻辑 $uwpWarn = $w.IsUwp 有两个问题：
            #   1. CoreWindow（能抓）也被判成需要警告，警告失去区分力；
            #   2. 真正该警告的是"抓出来是空白"，与窗口类别只是相关而非等同。
            $domPermille = 0; $distinct = 0
            $blank = [DSKHand.Api]::LooksBlank($bmp, [ref]$domPermille, [ref]$distinct)
            $uwpWarn = $blank
            $bmp.Save($OutPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $wi = $bmp.Width; $hi = $bmp.Height
            $bmp.Dispose()
            $bytes = (Get-Item $OutPath).Length

            Emit @{
                ok = $true
                path = $OutPath
                width = $wi
                height = $hi
                bytes = $bytes
                target = $targetDesc
                targetClass = $targetClass
                originX = $clipX
                originY = $clipY
                screenWidth = $physW
                screenHeight = $physH
                # 坐标换算提示：截图宽 != 物理屏宽时，点击坐标需乘这个系数。
                # ⚠️ 只在"整对象抓取"时有意义：区域裁切后的图宽是裁切宽，
                #    拿它算比例会得到荒谬的值（实测裁 600 宽得到 4.2667）。
                #    所以裁切时不报这个字段，改报 originX/originY 供换算。
                coordScale = $(if ($Region) { $null } else { [math]::Round([double]$physW / [double]$wi, 4) })
                blackPermille = $black
                uwpWarning = $uwpWarn
                # 判据透明化：让 agent 能自己复核"为什么说它空白/不空白"。
                dominantPermille = $domPermille
                distinctColors = $distinct
                isFrameHost = $isFrameHost
                minimized = $minimized
                note = '黑像素比例仅供参考，不是成功判据。空白判据见 dominantPermille/distinctColors。'
            }
        }

        # ---------------------------------------------------------------
        'click' {
            $sw = if ($ShotWidth -le 0) { $physW } else { $ShotWidth }
            $scale = [double]$physW / [double]$sw
            $px = [int][math]::Round($X * $scale)
            $py = [int][math]::Round($Y * $scale)
            if ($ToX -ne [int]::MinValue -and $ToY -ne [int]::MinValue) {
                $tx = [int][math]::Round($ToX * $scale)
                $ty = [int][math]::Round($ToY * $scale)
                [DSKHand.Api]::Drag($px, $py, $tx, $ty)
                Emit @{ ok = $true; action = 'drag'; fromShot = "$X,$Y"; toShot = "$ToX,$ToY"
                       fromPhys = "$px,$py"; toPhys = "$tx,$ty"; scale = $scale
                       cursor = [DSKHand.Api]::Cur() }
            } else {
                [DSKHand.Api]::Click($px, $py, [bool]$Right, [bool]$Double, $SettleMs)
                Emit @{ ok = $true; action = $(if ($Right) { 'right-click' } elseif ($Double) { 'double-click' } else { 'click' })
                       shot = "$X,$Y"; phys = "$px,$py"; scale = $scale
                       cursor = [DSKHand.Api]::Cur() }
            }
        }

        # ---------------------------------------------------------------
        'move' {
            $sw = if ($ShotWidth -le 0) { $physW } else { $ShotWidth }
            $scale = [double]$physW / [double]$sw
            $px = [int][math]::Round($X * $scale)
            $py = [int][math]::Round($Y * $scale)
            [DSKHand.Api]::MoveTo($px, $py)
            Emit @{ ok = $true; action = 'move'; phys = "$px,$py"; cursor = [DSKHand.Api]::Cur() }
        }

        # ---------------------------------------------------------------
        'probe' {
            $a = [DSKHand.Api]::Probe($X, $Y)
            $b = [DSKHand.Api]::Probe($X, $Y)
            Emit @{ ok = $true; probeA = $a.Trim(); probeB = $b.Trim()
                   note = 'A/B 不同或设定值被推走 = 有别的输入源在覆盖（远程会话在动鼠标）。' }
        }

        # ---------------------------------------------------------------
        'type' {
            if (-not $Text) { Fail 'type 动作需要 -Text。' 'MISSING_TEXT' }
            $n = [DSKHand.Api]::TypeUnicode($Text)
            if ($Enter) { [DSKHand.Api]::KeyVk([DSKHand.Api]::VK_RETURN) }
            Emit @{ ok = $true; action = 'type'; chars = $n; enter = [bool]$Enter
                   mode = 'SendInput+KEYEVENTF_UNICODE (绕过输入法)'
                   foreground = [DSKHand.Api]::ForegroundTitle() }
        }

        # ---------------------------------------------------------------
        'key' {
            if (-not $Key) { Fail 'key 动作需要 -Key。' 'MISSING_KEY' }
            $k = $Key.ToLower().Trim()
            $A = [DSKHand.Api]
            switch -Regex ($k) {
                '^enter$'    { $A::KeyVk($A::VK_RETURN) }
                '^return$'   { $A::KeyVk($A::VK_RETURN) }
                '^esc(ape)?$'{ $A::KeyVk($A::VK_ESCAPE) }
                '^tab$'      { $A::KeyVk($A::VK_TAB) }
                '^space$'    { $A::KeyVk($A::VK_SPACE) }
                '^backspace$'{ $A::KeyVk($A::VK_BACK) }
                '^delete$'   { $A::KeyVk($A::VK_DELETE) }
                '^up$'       { $A::KeyVk($A::VK_UP) }
                '^down$'     { $A::KeyVk($A::VK_DOWN) }
                '^left$'     { $A::KeyVk($A::VK_LEFT) }
                '^right$'    { $A::KeyVk($A::VK_RIGHT) }
                '^home$'     { $A::KeyVk($A::VK_HOME) }
                '^end$'      { $A::KeyVk($A::VK_END) }
                '^pageup$'   { $A::KeyVk($A::VK_PRIOR) }
                '^pagedown$' { $A::KeyVk($A::VK_NEXT) }
                '^f1$'       { $A::KeyVk($A::VK_F1) }
                '^ctrl\+a$'  { $A::KeyCombo($A::VK_CONTROL, $A::VK_A) }
                '^ctrl\+c$'  { $A::KeyCombo($A::VK_CONTROL, $A::VK_C) }
                '^ctrl\+v$'  { $A::KeyCombo($A::VK_CONTROL, $A::VK_V) }
                '^ctrl\+s$'  { $A::KeyCombo($A::VK_CONTROL, $A::VK_S) }
                '^ctrl\+w$'  { $A::KeyCombo($A::VK_CONTROL, $A::VK_W) }
                '^ctrl\+x$'  { $A::KeyCombo($A::VK_CONTROL, $A::VK_X) }
                '^ctrl\+z$'  { $A::KeyCombo($A::VK_CONTROL, $A::VK_Z) }
                '^alt\+f4$'  { $A::KeyCombo($A::VK_MENU, 0x73) }   # VK_F4
                default {
                    if ($k -match '^f([1-9]|1[0-2])$') {
                        $A::KeyVk([byte]($A::VK_F1 + [int]$Matches[1] - 1))
                    } else {
                        Fail "不认识的按键 `"$Key`"。可用：enter esc tab space backspace delete up down left right home end pageup pagedown f1-f12 ctrl+a/c/v/s/w/x/z alt+f4" 'BAD_KEY'
                    }
                }
            }
            Emit @{ ok = $true; action = 'key'; key = $k; foreground = [DSKHand.Api]::ForegroundTitle() }
        }

        # ---------------------------------------------------------------
        'focus' {
            $w = $null
            if ($Handle -ne 0) {
                $w = [DSKHand.Api]::ByHandle($Handle)
                if ($null -eq $w) { Fail "窗口句柄 $Handle 无效。" 'NO_SUCH_WINDOW' }
            } else {
                if (-not $Window) { Fail 'focus 需要 -Window 或 -Handle。' 'MISSING_TARGET' }
                $hits = @([DSKHand.Api]::MatchWindows($Window))
                if ($hits.Count -eq 0) { Fail "没有标题包含'$Window'的可见窗口。" 'NO_MATCH' }
                if ($hits.Count -gt 1) {
                    $cand = ($hits | ForEach-Object { "handle=$($_.Handle) title='$($_.Title)'" }) -join ' | '
                    Fail "标题'$Window'匹配到 $($hits.Count) 个窗口，请用 handle 指定：$cand" 'AMBIGUOUS'
                }
                $w = $hits[0]
            }
            $res = [DSKHand.Api]::Focus([IntPtr]$w.Handle)
            Emit @{ ok = ($res -eq 'ok' -or $res -eq 'already-foreground'); action = 'focus'
                   result = $res; target = $w.Title; handle = $w.Handle
                   foreground = [DSKHand.Api]::ForegroundTitle()
                   note = $(if ($res -eq 'failed(foreground-lock)') {
                       '前台锁挡掉了 SetForegroundWindow。改用 click_shot 在目标窗口体上点一下（真实点击能拿到激活），再 type_text。'
                   } else { '' }) }
        }

        default { Fail "未知动作 `"$Action`"。可用：info list-windows capture click move drag probe type key focus" 'BAD_ACTION' }
    }
}
catch {
    Emit @{ ok = $false; error = $_.Exception.Message; code = 'EXCEPTION'; stack = $_.ScriptStackTrace }
    exit 1
}
