// Swap for Windows: hold Alt, tap Tab, pick any window from a list in last-used order, one page per
// virtual desktop (Left/Right arrows). Release Alt to jump to it, on whichever desktop it is.
// 1 to 9 pick a row, W (or Delete) closes the selected window, Q quits its app; the list stays open.
// Colours, sizes and fonts come from design/tokens.json through Tokens.cs; dark or light follows Windows.
// Single file, C# 5, builds with the compiler that ships with Windows (see build.ps1). MIT licence.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace Swap
{
    static class Native
    {
        public const int WH_KEYBOARD_LL = 13, WM_KEYDOWN = 0x100, WM_KEYUP = 0x101, WM_SYSKEYDOWN = 0x104, WM_SYSKEYUP = 0x105;
        public const uint LLKHF_ALTDOWN = 0x20, KEYEVENTF_EXTENDEDKEY = 1, KEYEVENTF_KEYUP = 2;
        public const int VK_TAB = 9, VK_RETURN = 13, VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_ESCAPE = 0x1B;
        public const int VK_LEFT = 0x25, VK_UP = 0x26, VK_RIGHT = 0x27, VK_DOWN = 0x28, VK_LWIN = 0x5B, VK_RWIN = 0x5C;
        public const int VK_DELETE = 0x2E, VK_Q = 0x51, VK_W = 0x57, VK_1 = 0x31, VK_9 = 0x39, WM_CLOSE = 0x10;
        public const int VK_LMENU = 0xA4, VK_RMENU = 0xA5, VK_DUMMY = 0xE8;   // 0xE8 is unassigned: a harmless "other key"
        public const int GWL_EXSTYLE = -20, WS_EX_TOOLWINDOW = 0x80, WS_EX_APPWINDOW = 0x40000, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOPMOST = 0x8;
        public const int GW_OWNER = 4, SW_RESTORE = 9, SW_MINIMIZE = 6, DWMWA_CLOAKED = 14;
        public const uint EVENT_SYSTEM_FOREGROUND = 3, WINEVENT_OUTOFCONTEXT = 0;

        public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);
        public delegate bool EnumProc(IntPtr h, IntPtr l);
        public delegate void WinEventProc(IntPtr hook, uint ev, IntPtr h, int obj, int child, uint thread, uint time);

        [StructLayout(LayoutKind.Sequential)]
        public struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)]
        public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)]
        public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Explicit)]
        public struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
        [StructLayout(LayoutKind.Sequential)]
        public struct INPUT { public uint type; public InputUnion u; }

        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr mod, uint thread);
        [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
        [DllImport("kernel32.dll")] public static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
        [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc fn, IntPtr l);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, int cmd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
        [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc fn, uint pid, uint thread, uint flags);
        [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
        [DllImport("user32.dll", EntryPoint = "GetClassLongPtrW")] public static extern IntPtr GetClassLongPtr(IntPtr h, int i);
        [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int value, int size);
        [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool QueryFullProcessImageName(IntPtr h, int flags, StringBuilder s, ref int size);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, StringBuilder l);
        [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("dwmapi.dll")] public static extern int DwmGetColorizationColor(out uint color, out bool opaque);

        public static readonly IntPtr Magic = new IntPtr(0x53574150);   // "SWAP": marks keys Swap sends itself

        public static void Key(int vk, bool down, IntPtr extra)
        {
            var i = new INPUT { type = 1 };
            i.u.ki.wVk = (ushort)vk;
            i.u.ki.dwFlags = (down ? 0 : KEYEVENTF_KEYUP) |
                ((vk >= 0x21 && vk <= 0x28) || vk == VK_RMENU || vk == VK_LWIN || vk == VK_RWIN ? KEYEVENTF_EXTENDEDKEY : 0);
            i.u.ki.dwExtraInfo = extra;
            SendInput(1, new[] { i }, Marshal.SizeOf(typeof(INPUT)));
        }

        public static void Click(int x, int y)
        {
            SetCursorPos(x, y);
            Thread.Sleep(30);
            foreach (uint flag in new uint[] { 2, 4 })   // left down, left up
            {
                var i = new INPUT { type = 0 };
                i.u.mi.dwFlags = flag;
                SendInput(1, new[] { i }, Marshal.SizeOf(typeof(INPUT)));
                Thread.Sleep(30);
            }
        }

        public static string Text(IntPtr h)
        {
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, sb.Capacity);
            return sb.ToString();
        }

        public static string ClassOf(IntPtr h)
        {
            var sb = new StringBuilder(256);
            GetClassName(h, sb, sb.Capacity);
            return sb.ToString();
        }

        public static string ProcessPath(uint pid)
        {
            IntPtr p = OpenProcess(0x1000, false, pid);   // query limited information
            if (p == IntPtr.Zero) return null;
            try
            {
                var sb = new StringBuilder(1024);
                int n = sb.Capacity;
                return QueryFullProcessImageName(p, 0, sb, ref n) ? sb.ToString() : null;
            }
            finally { CloseHandle(p); }
        }
    }

    // Windows' own virtual desktop manager (documented COM interface): which desktop a window is on.
    [ComImport, Guid("a5cd92ff-29be-454c-8d04-d82879fb3f1b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IVirtualDesktopManager
    {
        [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr h, out int on);
        [PreserveSig] int GetWindowDesktopId(IntPtr h, out Guid id);
        [PreserveSig] int MoveWindowToDesktop(IntPtr h, ref Guid id);
    }
    [ComImport, Guid("aa509086-5ca9-4c25-8f95-589d3c07b48a")]
    class VirtualDesktopManagerClass { }

    // Desktop order and the current desktop come from Explorer's own registry keys.
    static class Desktops
    {
        const string Root = @"Software\Microsoft\Windows\CurrentVersion\Explorer";
        static IVirtualDesktopManager manager;

        public static IVirtualDesktopManager Manager
        {
            get
            {
                if (manager == null)
                {
                    try { manager = (IVirtualDesktopManager)new VirtualDesktopManagerClass(); } catch { }
                }
                return manager;
            }
        }

        public static List<Guid> List()
        {
            var list = new List<Guid>();
            using (var k = Registry.CurrentUser.OpenSubKey(Root + @"\VirtualDesktops"))
            {
                var bytes = k == null ? null : k.GetValue("VirtualDesktopIDs") as byte[];
                if (bytes != null)
                    for (int i = 0; i + 16 <= bytes.Length; i += 16)
                    {
                        var g = new byte[16];
                        Array.Copy(bytes, i, g, 0, 16);
                        list.Add(new Guid(g));
                    }
            }
            return list;
        }

        public static Guid Current()
        {
            int session = Process.GetCurrentProcess().SessionId;
            foreach (var path in new[] { Root + @"\SessionInfo\" + session + @"\VirtualDesktops", Root + @"\VirtualDesktops" })
                using (var k = Registry.CurrentUser.OpenSubKey(path))
                {
                    var bytes = k == null ? null : k.GetValue("CurrentVirtualDesktop") as byte[];
                    if (bytes != null && bytes.Length == 16) return new Guid(bytes);
                }
            return Guid.Empty;
        }

        public static string Name(Guid id, int number)
        {
            using (var k = Registry.CurrentUser.OpenSubKey(Root + @"\VirtualDesktops\Desktops\" + id.ToString("B").ToUpper()))
            {
                var name = k == null ? null : k.GetValue("Name") as string;
                return string.IsNullOrEmpty(name) ? "Desktop " + number : name;
            }
        }

        public static Guid Of(IntPtr h)
        {
            Guid g;
            var m = Manager;
            return m != null && m.GetWindowDesktopId(h, out g) == 0 ? g : Guid.Empty;
        }

        public static int CurrentIndex()
        {
            return List().IndexOf(Current());
        }
    }

    class Win
    {
        public IntPtr Handle;
        public uint Pid;
        public string Title, App, ProcessName;
        public Image Icon;
        public bool Minimized;
        public Guid Desktop;
    }

    class Page
    {
        public string Title;
        public List<Win> Items = new List<Win>();
    }

    // Lists windows the way the Alt+Tab of Windows does, in last-used order, split by desktop.
    static class Windows
    {
        public static readonly List<IntPtr> Recent = new List<IntPtr>();   // foreground history, newest first
        public static HashSet<string> OnlyApps;                            // self-test: limit to these processes
        static readonly Dictionary<uint, Tuple<string, string, Image>> apps = new Dictionary<uint, Tuple<string, string, Image>>();
        static Native.WinEventProc foregroundProc;

        public static void TrackForeground()
        {
            foregroundProc = (hook, ev, h, obj, child, thread, time) => Touch(h);
            Native.SetWinEventHook(Native.EVENT_SYSTEM_FOREGROUND, Native.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, foregroundProc, 0, 0, Native.WINEVENT_OUTOFCONTEXT);
            Touch(Native.GetForegroundWindow());
        }

        public static void Touch(IntPtr h)
        {
            if (h == IntPtr.Zero) return;
            Recent.Remove(h);
            Recent.Insert(0, h);
            if (Recent.Count > 300) Recent.RemoveRange(300, Recent.Count - 300);
        }

        static bool Eligible(IntPtr h, uint me)
        {
            if (!Native.IsWindowVisible(h)) return false;
            int ex = Native.GetWindowLong(h, Native.GWL_EXSTYLE);
            if ((ex & Native.WS_EX_TOOLWINDOW) != 0) return false;
            if (Native.GetWindow(h, Native.GW_OWNER) != IntPtr.Zero && (ex & Native.WS_EX_APPWINDOW) == 0) return false;
            if (Native.Text(h).Length == 0) return false;
            string cls = Native.ClassOf(h);
            if (cls == "Progman" || cls == "Shell_TrayWnd" || cls == "Windows.UI.Core.CoreWindow") return false;
            uint pid;
            Native.GetWindowThreadProcessId(h, out pid);
            if (pid == me) return false;
            // Windows on other desktops are hidden by the shell ("cloaked" = 2). Anything else cloaked is
            // not really there (suspended Store apps), and a cloaked window on this desktop is hidden too.
            int cloaked;
            if (Native.DwmGetWindowAttribute(h, Native.DWMWA_CLOAKED, out cloaked, 4) == 0 && cloaked != 0)
            {
                if (cloaked != 2) return false;
                var m = Desktops.Manager;
                int on;
                if (m != null && m.IsWindowOnCurrentVirtualDesktop(h, out on) == 0 && on != 0) return false;
            }
            return true;
        }

        static Tuple<string, string, Image> AppInfo(uint pid, IntPtr h)
        {
            Tuple<string, string, Image> info;
            if (apps.TryGetValue(pid, out info)) return info;
            string path = Native.ProcessPath(pid);
            string proc = path == null ? "" : Path.GetFileNameWithoutExtension(path);
            string name = proc;
            Image icon = null;
            if (path != null)
            {
                try
                {
                    var d = FileVersionInfo.GetVersionInfo(path).FileDescription;
                    if (!string.IsNullOrEmpty(d)) name = d;
                    var ico = System.Drawing.Icon.ExtractAssociatedIcon(path);
                    if (ico != null) icon = ico.ToBitmap();
                }
                catch { }
            }
            info = Tuple.Create(name, proc.ToLowerInvariant(), icon);
            apps[pid] = info;
            return info;
        }

        public static void ForgetApp(uint pid) { apps.Remove(pid); }

        // One page per desktop, each in last-used order, and the index of the desktop you are on.
        public static List<Page> Pages(out int current)
        {
            uint me = (uint)Process.GetCurrentProcess().Id;
            var found = new List<Win>();
            Native.EnumWindows((h, l) =>
            {
                if (!Eligible(h, me)) return true;
                uint pid;
                Native.GetWindowThreadProcessId(h, out pid);
                var info = AppInfo(pid, h);
                if (OnlyApps != null && !OnlyApps.Contains(info.Item2)) return true;
                found.Add(new Win { Handle = h, Pid = pid, Title = Native.Text(h), App = info.Item1, ProcessName = info.Item2,
                                    Icon = info.Item3, Minimized = Native.IsIconic(h), Desktop = Desktops.Of(h) });
                return true;
            }, IntPtr.Zero);

            // EnumWindows returns windows front to back, which is already last-used order; the foreground
            // history refines it (and keeps the order for windows on other desktops).
            var zOrder = new Dictionary<IntPtr, int>();
            for (int i = 0; i < found.Count; i++) zOrder[found[i].Handle] = i;
            Func<Win, int> rank = w => { int r = Recent.IndexOf(w.Handle); return r >= 0 ? r : 10000 + zOrder[w.Handle]; };
            found = found.OrderBy(rank).ToList();

            var desks = Desktops.List();
            var cur = Desktops.Current();
            if (cur == Guid.Empty && desks.Count > 0)
            {
                // Fresh sign-in: Explorer only writes the current desktop after the first switch. Until then,
                // the desktop of any window the desktop manager says is on the current one is it.
                var m = Desktops.Manager;
                foreach (var w in found)
                {
                    int on;
                    if (w.Desktop != Guid.Empty && m != null && m.IsWindowOnCurrentVirtualDesktop(w.Handle, out on) == 0 && on != 0) { cur = w.Desktop; break; }
                }
                if (cur == Guid.Empty) cur = desks[0];
            }
            current = Math.Max(0, desks.IndexOf(cur));
            if (desks.Count == 0 || cur == Guid.Empty)
            {
                current = 0;
                return new List<Page> { new Page { Title = "", Items = found } };
            }
            var pages = desks.Select((g, i) => new Page { Title = Desktops.Name(g, i + 1) }).ToList();
            foreach (var w in found)
            {
                int i = desks.IndexOf(w.Desktop);
                pages[i >= 0 ? i : current].Items.Add(w);   // pinned / unknown: the current desktop
            }
            return pages;
        }

        public static List<Win> List()
        {
            int current;
            return Pages(out current)[current].Items;
        }

        // Bring a window forward; Windows moves to its desktop if it is on another one.
        public static void Focus(Win w)
        {
            IntPtr h = w.Handle;
            if (!Native.IsWindow(h)) return;
            Touch(h);
            if (Native.IsIconic(h)) Native.ShowWindow(h, Native.SW_RESTORE);
            // Windows only lets the app that had the last input set the foreground window: send a harmless key first.
            Native.Key(Native.VK_DUMMY, true, Native.Magic);
            Native.Key(Native.VK_DUMMY, false, Native.Magic);
            if (Native.SetForegroundWindow(h) && Native.GetForegroundWindow() == h) return;
            uint pid;
            uint fg = Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out pid);
            uint mine = Native.GetCurrentThreadId();
            Native.AttachThreadInput(mine, fg, true);
            Native.BringWindowToTop(h);
            Native.SetForegroundWindow(h);
            Native.AttachThreadInput(mine, fg, false);
        }

        // Ask a window to close, as its own close button would (the app may ask about unsaved work).
        public static void Close(Win w)
        {
            if (Native.IsWindow(w.Handle)) Native.PostMessage(w.Handle, Native.WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
        }

        // Quit an app the polite way: close every top-level window it has, on every desktop. Apps with
        // unsaved work show their own dialog; nothing is killed. Never Swap itself.
        public static void Quit(Win w)
        {
            uint me = (uint)Process.GetCurrentProcess().Id;
            if (w.Pid == me) return;
            var mine = new List<IntPtr>();
            Native.EnumWindows((h, l) =>
            {
                uint pid;
                Native.GetWindowThreadProcessId(h, out pid);
                if (pid == w.Pid && Native.IsWindowVisible(h) && Native.GetWindow(h, Native.GW_OWNER) == IntPtr.Zero) mine.Add(h);
                return true;
            }, IntPtr.Zero);
            if (!mine.Contains(w.Handle)) mine.Add(w.Handle);
            foreach (var h in mine) Native.PostMessage(h, Native.WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
        }
    }

    // Dark or light, and the accent colour, as Windows has them right now.
    static class Theme
    {
        public static bool Dark
        {
            get
            {
                try
                {
                    using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                    {
                        var v = k == null ? null : k.GetValue("AppsUseLightTheme");
                        return v == null || Convert.ToInt32(v) == 0;
                    }
                }
                catch { return true; }
            }
        }

        public static void RefreshAccent()
        {
            uint argb; bool opaque;
            if (Native.DwmGetColorizationColor(out argb, out opaque) == 0)
                Tokens.AccentBase = Color.FromArgb(255, (int)(argb >> 16) & 255, (int)(argb >> 8) & 255, (int)argb & 255);
        }
    }

    // The floating list. Never takes focus, so the app underneath stays active until you pick.
    // Drawn from the design tokens (Tokens.cs): the same look as the Mac panel, dark or light as Windows is.
    class SwitcherForm : Form
    {
        public List<Win> Items = new List<Win>();
        public int Selected, PageIndex, PageCount;
        public string PageTitle = "";
        public Action<int> OnPick;
        public bool Dark = true;
        int first, visibleRows;
        float scale = 1;

        public SwitcherForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = true;
            DoubleBuffered = true;
            using (var g = CreateGraphics()) scale = g.DpiX / 96f;
        }

        protected override bool ShowWithoutActivation { get { return true; } }
        protected override CreateParams CreateParams
        {
            get
            {
                var cp = base.CreateParams;
                cp.ExStyle |= Native.WS_EX_TOOLWINDOW | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOPMOST;
                cp.ClassStyle |= 0x20000;   // drop shadow
                return cp;
            }
        }

        int S(float v) { return (int)Math.Round(v * scale); }
        Color C(Shade s) { return s.For(Dark); }
        static Color Alpha(Color c, double a) { return Color.FromArgb((int)(c.A * a), c.R, c.G, c.B); }
        Font F(float size, FontStyle style) { return new Font("Segoe UI", size, style); }
        bool HasHeader { get { return PageCount > 1; } }
        bool HasFooter { get { return Items.Count > visibleRows; } }
        int HeaderH { get { return HasHeader ? S(Tokens.HeaderHeight + Tokens.HeaderGap) : 0; } }
        int RowH { get { return S(Tokens.RowHeight); } }
        int Pad { get { return S(Tokens.PanelPad); } }

        public void ShowList(List<Win> items, int selected, string title, int pageIndex, int pageCount)
        {
            Items = items; Selected = selected; PageTitle = title; PageIndex = pageIndex; PageCount = pageCount;
            Dark = Theme.Dark;
            Theme.RefreshAccent();
            BackColor = C(Tokens.PanelSolid);
            var area = Screen.FromPoint(Cursor.Position).WorkingArea;
            int fitRows = Math.Max(1, (int)((area.Height * 0.85 - 2 * Pad - HeaderH) / RowH));
            visibleRows = Math.Min(items.Count, Math.Min(fitRows, (int)Tokens.MaxVisibleRows));
            first = 0;
            ScrollToSelection();
            int maxW = (int)Math.Min(S(Tokens.PanelMaxWidth), area.Width * Tokens.PanelWidthShare);
            int w = Math.Min(maxW, Math.Max(S(Tokens.PanelMinWidth), S(Tokens.PanelFixedWidth)));
            int rowsH = items.Count == 0 ? S(Tokens.EmptyHeight) : Math.Max(visibleRows, 1) * RowH + (HasFooter ? S(Tokens.FooterHeight) : 0);
            int h = rowsH + HeaderH + 2 * Pad;
            Bounds = new Rectangle(area.X + (area.Width - w) / 2, area.Y + (area.Height - h) / 2, w, h);
            using (var path = Rounded(new Rectangle(0, 0, w, h), S(Tokens.PanelRadius))) Region = new Region(path);
            if (!Visible) Show();
            Invalidate();
        }

        public void Select(int i)
        {
            Selected = i;
            ScrollToSelection();
            Invalidate();
        }

        void ScrollToSelection()
        {
            if (Selected < first) first = Selected;
            if (Selected >= first + visibleRows) first = Selected - visibleRows + 1;
        }

        public Rectangle RowRect(int i)
        {
            int r = i - first;
            return new Rectangle(Pad, Pad + HeaderH + r * RowH, Width - 2 * Pad, RowH);
        }

        static GraphicsPath Rounded(Rectangle r, int radius)
        {
            var p = new GraphicsPath();
            int d = Math.Max(1, radius * 2);
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.Clear(C(Tokens.PanelSolid));
            if (HasHeader) DrawHeader(g);
            if (Items.Count == 0) DrawEmpty(g);
            else
            {
                for (int i = first; i < Math.Min(Items.Count, first + visibleRows); i++) DrawRow(g, i);
                if (HasFooter) DrawFooter(g);
            }
            // Hairline rim, as on the Mac.
            using (var pen = new Pen(C(Tokens.RimInner), 1f))
            using (var path = Rounded(new Rectangle(0, 0, Width - 1, Height - 1), S(Tokens.PanelRadius)))
                g.DrawPath(pen, path);
        }

        void DrawHeader(Graphics g)
        {
            var hr = new Rectangle(Pad, Pad, Width - 2 * Pad, S(Tokens.HeaderHeight));
            using (var header = F(Tokens.HeaderSize, Tokens.HeaderStyle))
            using (var hint = F(Tokens.HintSize, Tokens.HintStyle))
            {
                TextRenderer.DrawText(g, PageTitle, header, new Rectangle(hr.X + S(Tokens.IconInset), hr.Y, hr.Width / 3, hr.Height), C(Tokens.Label),
                    TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
                // Page dots: a pill for the current desktop, a dot for the others, chevrons either side.
                int d = S(Tokens.Dot), pill = S(Tokens.DotPill), gap = S(Tokens.DotGap);
                int total = pill + (PageCount - 1) * d + (PageCount - 1) * gap;
                int x = Width / 2 - total / 2, cy = hr.Y + hr.Height / 2;
                for (int i = 0; i < PageCount; i++)
                {
                    int wd = i == PageIndex ? pill : d;
                    using (var b = new SolidBrush(C(i == PageIndex ? Tokens.DotActive : Tokens.DotInactive)))
                    using (var path = Rounded(new Rectangle(x, cy - d / 2, wd, d), d / 2))
                        g.FillPath(b, path);
                    x += wd + gap;
                }
                int chevronGap = S(Tokens.ChevronGap);
                using (var chevron = F(Tokens.HeaderSize, FontStyle.Regular))
                {
                    var left = new Rectangle(Width / 2 - total / 2 - chevronGap - S(12), hr.Y, S(12), hr.Height);
                    var right = new Rectangle(Width / 2 + total / 2 + chevronGap, hr.Y, S(12), hr.Height);
                    TextRenderer.DrawText(g, "‹", chevron, left, C(PageIndex == 0 ? Tokens.ChevronEnd : Tokens.Chevron), TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter | TextFormatFlags.NoPadding);
                    TextRenderer.DrawText(g, "›", chevron, right, C(PageIndex == PageCount - 1 ? Tokens.ChevronEnd : Tokens.Chevron), TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter | TextFormatFlags.NoPadding);
                }
                TextRenderer.DrawText(g, "← → desktops", hint, new Rectangle(hr.X, hr.Y, hr.Width - S(Tokens.TextInsetRight) + Pad, hr.Height),
                    C(Tokens.Tertiary), TextFormatFlags.VerticalCenter | TextFormatFlags.Right | TextFormatFlags.NoPrefix);
            }
            using (var line = new Pen(C(Tokens.Separator), Math.Max(1f, Tokens.SeparatorSize * scale)))
                g.DrawLine(line, hr.X, hr.Bottom + S(Tokens.HeaderGap) / 2, hr.Right, hr.Bottom + S(Tokens.HeaderGap) / 2);
        }

        void DrawEmpty(Graphics g)
        {
            var r = new Rectangle(Pad, Pad + HeaderH, Width - 2 * Pad, S(Tokens.EmptyHeight));
            using (var font = F(Tokens.EmptySize, Tokens.EmptyStyle))
            using (var hint = F(Tokens.EmptyHintSize, Tokens.EmptyHintStyle))
            {
                TextRenderer.DrawText(g, Tokens.Empty, font, new Rectangle(r.X, r.Y, r.Width, r.Height / 2 + S(8)), C(Tokens.Secondary),
                    TextFormatFlags.Bottom | TextFormatFlags.HorizontalCenter);
                string more = PageIndex < PageCount - 1 ? string.Format(Tokens.EmptyHintRight, "the next desktop")
                            : PageIndex > 0 ? string.Format(Tokens.EmptyHintLeft, "the previous desktop") : "";
                TextRenderer.DrawText(g, more, hint, new Rectangle(r.X, r.Y + r.Height / 2 + S(8), r.Width, S(20)), C(Tokens.Tertiary),
                    TextFormatFlags.Top | TextFormatFlags.HorizontalCenter);
            }
        }

        void DrawRow(Graphics g, int i)
        {
            var row = RowRect(i);
            var w = Items[i];
            bool isSel = i == Selected;
            if (isSel)
            {
                var r = new Rectangle(row.X + S(Tokens.SelectionInsetX), row.Y + S(Tokens.SelectionInsetY), row.Width - 2 * S(Tokens.SelectionInsetX), row.Height - 2 * S(Tokens.SelectionInsetY));
                using (var path = Rounded(r, S(Tokens.RadiusSelection)))
                using (var fill = new SolidBrush(C(Tokens.Selection)))
                    g.FillPath(fill, path);
                using (var bar = new SolidBrush(C(Tokens.SelectionText)))
                using (var path = Rounded(new Rectangle(row.X + S(4), row.Y + S(8), S(Tokens.SelectionBar), row.Height - S(16)), S(Tokens.SelectionBar) / 2))
                    g.FillPath(bar, path);
            }
            int s = S(Tokens.Icon);
            var iconRect = new Rectangle(row.X + S(Tokens.IconInset), row.Y + (row.Height - s) / 2, s, s);
            if (w.Icon != null)
            {
                if (w.Minimized)
                    using (var attrs = new System.Drawing.Imaging.ImageAttributes())
                    {
                        attrs.SetColorMatrix(new System.Drawing.Imaging.ColorMatrix { Matrix33 = 0.6f });
                        g.DrawImage(w.Icon, iconRect, 0, 0, w.Icon.Width, w.Icon.Height, GraphicsUnit.Pixel, attrs);
                    }
                else g.DrawImage(w.Icon, iconRect);
            }
            int textStart = iconRect.Right + S(Tokens.IconGap);
            int rightEdge = row.Right - S(Tokens.TextInsetRight);
            using (var title = F(isSel ? Tokens.TitleSelectedSize : Tokens.TitleSize, isSel ? Tokens.TitleSelectedStyle : Tokens.TitleStyle))
            using (var appFont = F(Tokens.AppNameSize, Tokens.AppNameStyle))
            using (var capsule = F(Tokens.CapsuleSize, Tokens.CapsuleStyle))
            {
                // App name on the right, in the secondary colour (or lighter on the selection).
                int titleRoom = rightEdge - textStart;
                if (!string.IsNullOrEmpty(w.App))
                {
                    int natural = TextRenderer.MeasureText(g, w.App, appFont, new Size(int.MaxValue, row.Height), TextFormatFlags.NoPadding).Width;
                    int appW = Math.Min(natural, Math.Max(S(Tokens.AppNameMinWidth), (int)(titleRoom * 0.45)));
                    var appRect = new Rectangle(rightEdge - appW, row.Y, appW, row.Height);
                    TextRenderer.DrawText(g, w.App, appFont, appRect, C(isSel ? Tokens.SelectionSub : Tokens.Secondary),
                        TextFormatFlags.VerticalCenter | TextFormatFlags.Right | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding);
                    rightEdge = appRect.X - S(Tokens.IconGap);
                }
                if (w.Minimized)
                {
                    var size = TextRenderer.MeasureText(g, Tokens.Minimised, capsule, new Size(int.MaxValue, row.Height), TextFormatFlags.NoPadding);
                    int cw = size.Width + 2 * S(Tokens.CapsulePadX), ch = size.Height + 2 * S(Tokens.CapsulePadY);
                    var cr = new Rectangle(rightEdge - cw, row.Y + (row.Height - ch) / 2, cw, ch);
                    using (var path = Rounded(cr, S(Tokens.RadiusCapsule)))
                    using (var fill = new SolidBrush(isSel ? Alpha(C(Tokens.SelectionText), 0.18) : C(Tokens.CapsuleFill)))
                        g.FillPath(fill, path);
                    TextRenderer.DrawText(g, Tokens.Minimised, capsule, cr, C(isSel ? Tokens.SelectionSub : Tokens.Secondary),
                        TextFormatFlags.VerticalCenter | TextFormatFlags.HorizontalCenter | TextFormatFlags.NoPadding);
                    rightEdge = cr.X - S(Tokens.IconGap);
                }
                var textRect = new Rectangle(textStart, row.Y, Math.Max(0, rightEdge - textStart), row.Height);
                var colour = isSel ? C(Tokens.SelectionText) : (w.Minimized ? Alpha(C(Tokens.Label), 0.7) : C(Tokens.Label));
                TextRenderer.DrawText(g, w.Title, title, textRect, colour,
                    TextFormatFlags.VerticalCenter | TextFormatFlags.Left | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding);
            }
        }

        void DrawFooter(Graphics g)
        {
            int footerH = S(Tokens.FooterHeight), fadeH = S(Tokens.FadeHeight);
            var fade = new Rectangle(0, Height - Pad - footerH - fadeH, Width, fadeH);
            var back = C(Tokens.PanelSolid);
            using (var grad = new LinearGradientBrush(fade, Color.FromArgb(0, back), back, LinearGradientMode.Vertical))
                g.FillRectangle(grad, fade);
            using (var fill = new SolidBrush(back)) g.FillRectangle(fill, new Rectangle(0, Height - Pad - footerH, Width, footerH + Pad));
            using (var font = F(Tokens.FooterSize, Tokens.FooterStyle))
                TextRenderer.DrawText(g, string.Format(Tokens.More, Items.Count - visibleRows), font,
                    new Rectangle(0, Height - Pad - footerH, Width - S(Tokens.TextInsetRight), footerH), C(Tokens.Tertiary),
                    TextFormatFlags.VerticalCenter | TextFormatFlags.Right | TextFormatFlags.NoPrefix);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            for (int i = first; i < Math.Min(Items.Count, first + visibleRows); i++)
                if (RowRect(i).Contains(e.Location)) { if (OnPick != null) OnPick(i); return; }
        }
    }

    // Hold Alt, tap Tab to step, release Alt to switch. Runs on the UI thread; the keyboard hook only
    // decides which keys to swallow and posts the work here.
    class Switcher
    {
        public static Switcher Instance;
        public readonly SwitcherForm Panel = new SwitcherForm();
        readonly System.Windows.Forms.Timer showTimer = new System.Windows.Forms.Timer { Interval = 100 };
        Native.HookProc hookProc;
        bool armed, swallowAltUp;
        bool loaded;
        List<Page> pages = new List<Page>();
        int pageIndex, currentPage, sel;
        List<Win> items = new List<Win>();
        public int ShowCount;

        public bool Active { get { return loaded; } }
        public int Selection { get { return sel; } }
        public int PageNumber { get { return pageIndex; } }
        public int PageCount { get { return pages.Count; } }
        public string PageTitle { get { return pageIndex < pages.Count ? pages[pageIndex].Title : ""; } }
        public Win SelectedItem { get { return sel >= 0 && sel < items.Count ? items[sel] : null; } }

        public Switcher()
        {
            Instance = this;
            showTimer.Tick += (s, e) => { showTimer.Stop(); if (loaded) ShowPanel(); };
            Panel.OnPick = i => { sel = i; Finish(true); };
            Panel.CreateControl();
            var unused = Panel.Handle;   // create the window now so BeginInvoke works
        }

        public void InstallHook()
        {
            hookProc = Hook;
            Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, hookProc, Native.GetModuleHandle(null), 0);
        }

        void Post(Action a) { Panel.BeginInvoke(a); }

        IntPtr Hook(int code, IntPtr wParam, IntPtr lParam)
        {
            if (code >= 0)
            {
                var k = (Native.KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(Native.KBDLLHOOKSTRUCT));
                if (k.dwExtraInfo != Native.Magic && OnKey(k, (int)wParam)) return new IntPtr(1);
            }
            return Native.CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
        }

        bool Down(int vk) { return (Native.GetAsyncKeyState(vk) & 0x8000) != 0; }

        bool OnKey(Native.KBDLLHOOKSTRUCT k, int msg)
        {
            bool down = msg == Native.WM_KEYDOWN || msg == Native.WM_SYSKEYDOWN;
            int vk = (int)k.vkCode;
            bool isAlt = vk == Native.VK_LMENU || vk == Native.VK_RMENU || vk == Native.VK_MENU;
            if (vk == Native.VK_TAB)
            {
                bool alt = (k.flags & Native.LLKHF_ALTDOWN) != 0;
                if (armed || (alt && !Down(Native.VK_CONTROL) && !Down(Native.VK_LWIN) && !Down(Native.VK_RWIN)))
                {
                    if (down)
                    {
                        armed = true;
                        bool reverse = Down(Native.VK_SHIFT);
                        Post(() => Step(reverse ? -1 : 1));
                    }
                    return true;
                }
                return false;
            }
            if (isAlt && !down && (armed || swallowAltUp))
            {
                // Swallow the real Alt release and replay it after a harmless key, so the app underneath
                // doesn't treat it as a lone Alt press and jump to its menu bar.
                bool commit = armed;
                armed = false; swallowAltUp = false;
                Native.Key(Native.VK_DUMMY, true, Native.Magic);
                Native.Key(Native.VK_DUMMY, false, Native.Magic);
                Native.Key(vk, false, Native.Magic);
                Post(() => { if (commit) Finish(true); });
                return true;
            }
            if (!armed) return false;
            int[] handled = { Native.VK_ESCAPE, Native.VK_RETURN, Native.VK_UP, Native.VK_DOWN, Native.VK_LEFT, Native.VK_RIGHT,
                              Native.VK_W, Native.VK_Q, Native.VK_DELETE };
            bool number = vk >= Native.VK_1 && vk <= Native.VK_9;
            if (!handled.Contains(vk) && !number) return false;
            if (down)
            {
                if (vk == Native.VK_ESCAPE) { armed = false; swallowAltUp = true; Post(() => Finish(false)); }
                else if (vk == Native.VK_RETURN) { armed = false; swallowAltUp = true; Post(() => Finish(true)); }
                else if (vk == Native.VK_UP) Post(() => Move(-1));
                else if (vk == Native.VK_DOWN) Post(() => Move(1));
                else if (vk == Native.VK_LEFT) Post(() => Flip(-1));
                else if (vk == Native.VK_RIGHT) Post(() => Flip(1));
                else if (vk == Native.VK_W || vk == Native.VK_DELETE) Post(() => CloseSelected());   // Delete: as the built-in Alt+Tab
                else if (vk == Native.VK_Q) Post(() => QuitSelected());
                else { int n = vk - Native.VK_1; Post(() => Pick(n)); }
            }
            return true;
        }

        // 1 to 9 jump straight to that row.
        void Pick(int i)
        {
            if (!loaded || i < 0 || i >= items.Count) return;
            sel = i;
            Finish(true);
        }

        // W (or Delete) closes the selected window; Q quits its app. The list stays open, minus those rows.
        void CloseSelected()
        {
            var item = SelectedItem;
            if (!loaded || item == null) return;
            Windows.Close(item);
            Drop(w => w.Handle == item.Handle);
        }

        void QuitSelected()
        {
            var item = SelectedItem;
            if (!loaded || item == null) return;
            Windows.Quit(item);
            Drop(w => w.Pid == item.Pid);
        }

        void Drop(Func<Win, bool> gone)
        {
            foreach (var p in pages) p.Items.RemoveAll(w => gone(w));
            if (!pages.Any(p => p.Items.Count > 0)) { Finish(false); return; }
            items = pages[pageIndex].Items;
            sel = items.Count == 0 ? 0 : Math.Min(sel, items.Count - 1);
            ShowPanel();
        }

        void Step(int d)
        {
            if (!loaded)
            {
                pages = Windows.Pages(out currentPage);
                pageIndex = currentPage;
                items = pages[pageIndex].Items;
                loaded = true;
                sel = items.Count == 0 ? 0 : ((d % items.Count) + items.Count) % items.Count;
                showTimer.Start();   // a quick Alt+Tab switches without flashing the list
            }
            else Move(d);
        }

        void Move(int d)
        {
            if (!loaded || items.Count == 0) return;
            sel = ((sel + d) % items.Count + items.Count) % items.Count;
            if (Panel.Visible) Panel.Select(sel);
        }

        // Another desktop's windows: the one used last there is selected; on your own desktop the
        // previous window is, as when the list opened.
        void Flip(int d)
        {
            if (!loaded) return;
            int n = pageIndex + d;
            if (n < 0 || n >= pages.Count) return;
            pageIndex = n;
            items = pages[n].Items;
            sel = n == currentPage && items.Count > 1 ? 1 : 0;
            ShowPanel();
        }

        void ShowPanel()
        {
            showTimer.Stop();
            ShowCount++;
            Panel.ShowList(items, sel, pages[pageIndex].Title, pageIndex, pages.Count);
        }

        void Finish(bool focus)
        {
            if (!loaded) return;
            var item = SelectedItem;
            showTimer.Stop();
            Panel.Hide();
            loaded = false;
            items = new List<Win>();
            pages = new List<Page>();
            if (focus && item != null) Windows.Focus(item);
        }
    }

    class TrayApp : ApplicationContext
    {
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        readonly NotifyIcon tray;
        readonly ToolStripMenuItem login;

        public TrayApp()
        {
            var menu = new ContextMenuStrip();
            var title = new ToolStripMenuItem("Swap " + Program.Version + ": hold Alt, press Tab" + (Elevated ? " (admin)" : "")) { Enabled = false };
            login = new ToolStripMenuItem("Start at login", null, (s, e) => ToggleLogin());
            menu.Items.Add(title);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(login);
            menu.Items.Add(new ToolStripMenuItem("Quit Swap", null, (s, e) => { tray.Visible = false; Application.Exit(); }));
            menu.Opening += (s, e) => login.Checked = LoginEnabled();
            tray = new NotifyIcon { Icon = MakeIcon(), Text = "Swap: hold Alt, press Tab", ContextMenuStrip = menu, Visible = true };
        }

        // Start at login: a Run-key entry when Swap runs as a normal user, a logon scheduled task with
        // highest privileges when it runs elevated (so it can also switch to windows of admin apps).
        public static bool Elevated
        {
            get
            {
                using (var id = System.Security.Principal.WindowsIdentity.GetCurrent())
                    return new System.Security.Principal.WindowsPrincipal(id).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
            }
        }

        static int Schtasks(string args)
        {
            var p = Process.Start(new ProcessStartInfo("schtasks.exe", args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true });
            p.WaitForExit(15000);
            return p.ExitCode;
        }

        static bool LoginEnabled()
        {
            using (var k = Registry.CurrentUser.OpenSubKey(RunKey)) if (k != null && k.GetValue("Swap") != null) return true;
            return Schtasks("/Query /TN Swap") == 0;
        }

        public static void SetLogin(bool on)
        {
            using (var k = Registry.CurrentUser.CreateSubKey(RunKey)) k.DeleteValue("Swap", false);
            Schtasks("/Delete /TN Swap /F");
            if (!on) return;
            if (Elevated)
                Schtasks("/Create /TN Swap /SC ONLOGON /RL HIGHEST /IT /F /TR \"\\\"" + Application.ExecutablePath + "\\\"\"");
            else
                using (var k = Registry.CurrentUser.CreateSubKey(RunKey)) k.SetValue("Swap", "\"" + Application.ExecutablePath + "\"");
        }

        void ToggleLogin() { SetLogin(!LoginEnabled()); }

        // Two overlapping windows, drawn at run time so the exe needs no resource file.
        public static Icon MakeIcon()
        {
            var bmp = new Bitmap(32, 32);
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                using (var back = new SolidBrush(Color.FromArgb(120, 255, 255, 255)))
                using (var front = new SolidBrush(Color.White))
                using (var bar = new SolidBrush(Color.FromArgb(0, 120, 215)))
                {
                    g.FillRectangle(back, 3, 5, 18, 15);
                    g.FillRectangle(front, 10, 12, 19, 16);
                    g.FillRectangle(bar, 10, 12, 19, 4);
                }
            }
            return System.Drawing.Icon.FromHandle(bmp.GetHicon());
        }
    }

    static class Program
    {
        public const string Version = "0.6.1";

        [STAThread]
        static void Main(string[] args)
        {
            Native.SetProcessDPIAware();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            string log = Arg(args, "--selftest");
            if (log == null)
            {
                bool created;
                var mutex = new Mutex(true, @"Local\SwapWindowSwitcher", out created);
                if (!created) return;   // already running
                if (args.Contains("--enable-login")) TrayApp.SetLogin(true);
                Windows.TrackForeground();
                new Switcher().InstallHook();
                Application.Run(new TrayApp());
                GC.KeepAlive(mutex);
                return;
            }
#if SELFTEST
            string only = Arg(args, "--only");
            if (only != null) Windows.OnlyApps = new HashSet<string>(only.ToLowerInvariant().Split(','));
            Windows.TrackForeground();
            new Switcher().InstallHook();
            new SelfTest(log, args.Contains("--desktops-only")).Start();
            Application.Run();
#endif
        }

        static string Arg(string[] args, string name)
        {
            int i = Array.IndexOf(args, name);
            return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        }
    }
}
