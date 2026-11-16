#if SELFTEST
// Live end-to-end test, compiled only into QA builds (/define:SELFTEST). It opens its own Notepad and
// Paint windows (plus one Notepad on Desktop 2), types real Alt+Tab keystrokes and checks which window
// ends up in front. Also: number keys, W closes a spare Notepad document, Q quits Paint. Keystrokes are sent from a background thread: the keyboard hook runs on the UI thread
// and must never wait on it. Run on the desktop of a signed-in user (selftest.ps1 does that).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;

namespace Swap
{
    class SelfTest
    {
        readonly string logPath;
        readonly bool desktopsOnly;
        int failures;
        readonly List<Process> started = new List<Process>();
        readonly string dir = Path.Combine(Path.GetTempPath(), "swaptest");

        public SelfTest(string log, bool desktopsOnly) { logPath = log; this.desktopsOnly = desktopsOnly; }

        public void Start()
        {
            File.WriteAllText(logPath, "");
            new Thread(() =>
            {
                try { Run(); }
                catch (Exception e) { Log("ERROR " + e); }
                finally
                {
                    foreach (var p in started) try { if (!p.HasExited) p.Kill(); } catch { }
                    Log(failures == 0 ? "DONE all passed" : "DONE " + failures + " failed");
                    UI(() => { Application.Exit(); return 0; });
                }
            }) { IsBackground = true }.Start();
        }

        void Log(string s) { lock (this) File.AppendAllText(logPath, s + Environment.NewLine); }
        void Check(string name, bool ok, string detail = "")
        {
            if (!ok) failures++;
            Log((ok ? "PASS  " : "FAIL  ") + name + (detail == "" ? "" : "  [" + detail + "]"));
        }

        static T UI<T>(Func<T> f) { return (T)Switcher.Instance.Panel.Invoke(f); }
        static void Wait(int ms) { Thread.Sleep(ms); }
        static void Key(int vk, bool down) { Native.Key(vk, down, IntPtr.Zero); Thread.Sleep(30); }
        static void Press(int vk) { Key(vk, true); Key(vk, false); }
        static void Alt(bool down) { Key(Native.VK_LMENU, down); }
        static void Tab(bool shift = false)
        {
            if (shift) Key(Native.VK_SHIFT, true);
            Press(Native.VK_TAB);
            if (shift) Key(Native.VK_SHIFT, false);
        }
        static void QuickSwitch() { Alt(true); Tab(); Alt(false); }
        // Win+Ctrl+Left/Right: the system shortcut that moves one desktop.
        static void MoveDesktop(int vk)
        {
            Key(Native.VK_LWIN, true); Key(Native.VK_CONTROL, true);
            Press(vk);
            Key(Native.VK_CONTROL, false); Key(Native.VK_LWIN, false);
        }

        static string Front() { return Native.Text(Native.GetForegroundWindow()); }
        static List<Win> List() { return UI(() => Windows.List()); }
        static Switcher S { get { return Switcher.Instance; } }
        static T Get<T>(Func<Switcher, T> f) { return UI(() => f(S)); }

        Process Open(string exe, string file)
        {
            var p = Process.Start(exe, "\"" + file + "\"");
            started.Add(p);
            return p;
        }

        string Doc(string name)
        {
            Directory.CreateDirectory(dir);
            string path = Path.Combine(dir, name);
            File.WriteAllText(path, "Swap test window " + name);
            return path;
        }

        string Picture(string name)
        {
            Directory.CreateDirectory(dir);
            string path = Path.Combine(dir, name);
            using (var bmp = new Bitmap(320, 200))
            {
                using (var g = Graphics.FromImage(bmp)) g.Clear(Color.SteelBlue);
                bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            }
            return path;
        }

        // Any text control in this window containing a tab character means a Tab leaked through.
        static bool HasTab(IntPtr h)
        {
            foreach (var cls in new[] { "Edit", "RICHEDIT50W" })
            {
                IntPtr edit = Native.FindWindowEx(h, IntPtr.Zero, cls, null);
                if (edit == IntPtr.Zero) continue;
                int len = (int)Native.SendMessage(edit, 0x0E, IntPtr.Zero, IntPtr.Zero);   // WM_GETTEXTLENGTH
                var sb = new System.Text.StringBuilder(len + 1);
                Native.SendMessage(edit, 0x0D, new IntPtr(sb.Capacity), sb);             // WM_GETTEXT
                if (sb.ToString().Contains("\t")) return true;
            }
            return false;
        }

        void Run()
        {
            int startDesk = Desktops.CurrentIndex();
            while (Desktops.CurrentIndex() > 0) { MoveDesktop(Native.VK_LEFT); Wait(1200); }
            foreach (var n in new[] { "One", "Two", "Three" }) { Open("notepad.exe", Doc("Swap test " + n + ".txt")); Wait(700); }
            Open("mspaint.exe", Picture("Swap test picture.png"));
            Wait(3000);

            if (!desktopsOnly) Basics();
            if (Desktops.List().Count >= 2) DesktopChecks();
            else Log("SKIP  desktop checks: this PC has only one desktop");

            bool leaked = List().Any(w => HasTab(w.Handle));
            Check("Tab keystrokes were swallowed, not typed into apps", !leaked);

            foreach (var p in started) try { if (!p.HasExited) p.Kill(); } catch { }
            started.Clear();
            Wait(800);
            while (Desktops.CurrentIndex() >= 0 && Desktops.CurrentIndex() < startDesk) { MoveDesktop(Native.VK_RIGHT); Wait(1200); }
        }

        void Basics()
        {
            var three = List().FirstOrDefault(w => w.Title.StartsWith("Swap test Three"));
            if (three != null) { UI(() => { Windows.Focus(three); return 0; }); Wait(800); }
            var list = List();
            Log("windows: " + list.Count);
            for (int i = 0; i < list.Count; i++) Log("  " + i + ": " + list[i].Title + (list[i].Minimized ? " (minimised)" : ""));
            Log("front: " + Front());
            Check("at least 3 windows to test with", list.Count >= 3, list.Count.ToString());
            if (list.Count < 3) return;
            int desks = Desktops.List().Count, cur0 = 0;
            var pages0 = UI(() => Windows.Pages(out cur0));
            Log("desktops: " + desks + "  current key: " + (Desktops.Current() == Guid.Empty ? "missing" : "set") + "  pages: " + pages0.Count);
            if (desks >= 2) Check("one page per desktop before any desktop switch (fresh sign-in)", pages0.Count == desks, pages0.Count + " pages");
            string before = Front();
            int shows = Get(s => s.ShowCount);

            // 1. Quick Alt+Tab: next window, no panel. 2. Again: back.
            QuickSwitch(); Wait(900);
            Check("quick Alt+Tab goes to the next window", Front() == list[1].Title, "front=" + Front() + " expected=" + list[1].Title);
            Check("quick Alt+Tab does not flash the list", Get(s => s.ShowCount) == shows);
            Check("switcher closed after release", !Get(s => s.Active) && !Get(s => s.Panel.Visible));
            QuickSwitch(); Wait(900);
            Check("second quick Alt+Tab flips back", Front() == before, "front=" + Front() + " expected=" + before);

            // 3. Hold Alt, Tab twice: list shows, release picks the third window.
            list = List(); before = Front();
            Alt(true); Tab(); Tab(); Wait(700);
            Check("list appears while Alt is held", Get(s => s.Panel.Visible));
            Check("list shows every window", Get(s => s.Panel.Items.Count) == list.Count, Get(s => s.Panel.Items.Count) + " rows");
            Check("two Tabs select the third window", Get(s => s.Selection) == 2, "sel=" + Get(s => s.Selection));
            Screenshot(Path.Combine(Path.GetDirectoryName(logPath), "panel.png"));
            Wait(1200);
            Alt(false); Wait(1000);
            Check("releasing Alt switches to the selected window", Front() == list[2].Title, "front=" + Front() + " expected=" + list[2].Title);
            Check("list hides after release", !Get(s => s.Panel.Visible));
            var now = List();
            Check("list is in last-used order: new window first, previous second",
                  now.Count > 1 && now[0].Title == Front() && now[1].Title == before, "first=" + now[0].Title + " second=" + now[1].Title);

            // 4. Esc cancels.
            before = Front();
            Alt(true); Tab(); Wait(400); Press(Native.VK_ESCAPE); Wait(300);
            Check("Esc closes the switcher", !Get(s => s.Active) && !Get(s => s.Panel.Visible));
            Alt(false); Wait(700);
            Check("Esc keeps the same window in front", Front() == before, "front=" + Front());

            // 5. Alt+Shift+Tab steps backwards to the last window.
            list = List();
            Alt(true); Tab(true); Wait(400);
            Check("Alt+Shift+Tab selects the last window", Get(s => s.Selection) == list.Count - 1, "sel=" + Get(s => s.Selection) + " of " + list.Count);
            Press(Native.VK_ESCAPE); Alt(false); Wait(500);

            // 6. Up/Down move through the rows.
            Alt(true); Tab(); Wait(500); Press(Native.VK_DOWN); Wait(200);
            Check("Down arrow moves to the next row", Get(s => s.Selection) == 2, "sel=" + Get(s => s.Selection));
            Press(Native.VK_UP); Wait(200);
            Check("Up arrow moves back", Get(s => s.Selection) == 1, "sel=" + Get(s => s.Selection));
            Press(Native.VK_ESCAPE); Alt(false); Wait(500);

            // 7. Clicking a row switches to it.
            list = List();
            Alt(true); Tab(); Wait(600);
            var r = UI(() => S.Panel.RectangleToScreen(S.Panel.RowRect(2)));
            Native.Click(r.X + r.Width / 2, r.Y + r.Height / 2); Wait(1000);
            Check("clicking a row switches to that window", Front() == list[2].Title, "front=" + Front() + " expected=" + list[2].Title);
            Alt(false); Wait(500);

            // 8. A minimised window is listed and comes back when picked.
            list = List();
            var target = list.Skip(1).FirstOrDefault(w => w.ProcessName == "notepad");
            if (target != null)
            {
                UI(() => Native.ShowWindow(target.Handle, Native.SW_MINIMIZE)); Wait(1000);
                list = List();
                int i = list.FindIndex(w => w.Handle == target.Handle);
                Check("minimised window still listed, marked minimised", i >= 0 && list[i].Minimized, "index " + i);
                if (i >= 0)
                {
                    Alt(true); for (int t = 0; t < i; t++) Tab(); Alt(false); Wait(1300);
                    Check("picking a minimised window restores it", !Native.IsIconic(target.Handle));
                    Check("restored window is in front", Native.GetForegroundWindow() == target.Handle, "front=" + Front());
                }
            }

            // 9. Order follows real use across apps: Paint, then a Notepad, then quick Alt+Tab = Paint.
            var paint = List().FirstOrDefault(w => w.ProcessName == "mspaint");
            var pad = List().FirstOrDefault(w => w.ProcessName == "notepad");
            if (paint == null || pad == null) Check("Paint and Notepad windows to test with", false);
            else
            {
                UI(() => { Native.SetForegroundWindow(paint.Handle); return 0; }); Wait(900);
                UI(() => { Native.SetForegroundWindow(pad.Handle); return 0; }); Wait(900);
                QuickSwitch(); Wait(900);
                Check("across apps: quick Alt+Tab returns to the last-used window", Native.GetForegroundWindow() == paint.Handle, "front=" + Front());
            }

            // 10. Number keys: 3 jumps straight to the third row.
            list = List();
            if (list.Count >= 3)
            {
                Alt(true); Tab(); Wait(500); Press(Native.VK_1 + 2); Wait(900);
                Check("number key 3 picks the third window", Front() == list[2].Title, "front=" + Front() + " expected=" + list[2].Title);
                Check("list closed after a number key", !Get(s => s.Active));
                Alt(false); Wait(500);
            }

            // 11. W closes the selected window; the list stays open without that row.
            Open("notepad.exe", Doc("Swap test Close.txt")); Wait(2000);
            var close = List().FirstOrDefault(w => w.Title.StartsWith("Swap test Close"));
            Check("a window to close with", close != null);
            if (close != null && WalkTo(w => w.Handle == close.Handle, "W: the Close document"))
            {
                Press(Native.VK_W); Wait(1200);
                Check("W keeps the list open", Get(s => s.Active) && Get(s => s.Panel.Visible));
                Check("W drops the row from the list", !Get(s => s.Panel.Items.Any(w => w.Handle == close.Handle)));
                Check("W closed the window", !Native.IsWindow(close.Handle) || !Native.IsWindowVisible(close.Handle));
                Press(Native.VK_ESCAPE); Alt(false); Wait(500);
            }

            // 12. Q quits the selected window's app: Paint goes, its rows go, the list stays open.
            var paintWin = List().FirstOrDefault(w => w.ProcessName == "mspaint");
            Check("Paint to quit with", paintWin != null);
            if (paintWin != null && WalkTo(w => w.Handle == paintWin.Handle, "Q: Paint"))
            {
                Press(Native.VK_Q); Wait(2500);
                Check("Q keeps the list open", Get(s => s.Active) && Get(s => s.Panel.Visible));
                Check("Q drops the app's rows from the list", !Get(s => s.Panel.Items.Any(w => w.Pid == paintWin.Pid)));
                Check("Q quit the app", Process.GetProcesses().All(p => (uint)p.Id != paintWin.Pid) || !Native.IsWindowVisible(paintWin.Handle));
                Press(Native.VK_ESCAPE); Alt(false); Wait(500);
            }
        }

        // Open the list and walk the selection onto the matching row. False (list closed) if it can't.
        bool WalkTo(Func<Win, bool> match, string what)
        {
            Alt(true); Tab(); Wait(700);
            var rows = Get(s => s.Panel.Items.ToList());
            int i = rows.FindIndex(w => match(w));
            if (i < 0)
            {
                Check(what + " is listed", false, rows.Count + " rows");
                Press(Native.VK_ESCAPE); Alt(false); Wait(400);
                return false;
            }
            int sel = Get(s => s.Selection);
            int vk = i > sel ? Native.VK_DOWN : Native.VK_UP;
            for (int t = 0; t < Math.Abs(i - sel); t++) { Press(vk); Wait(120); }
            Wait(300);
            var picked = Get(s => s.SelectedItem);
            bool ok = picked != null && match(picked);
            Check(what + " selected before the key", ok, picked == null ? "none" : picked.Title);
            if (!ok) { Press(Native.VK_ESCAPE); Alt(false); Wait(400); }
            return ok;
        }

        void DesktopChecks()
        {
            const string deskTitle = "Swap test desktop 2";   // Notepad may hide the .txt
            // Open a window on Desktop 2 while Swap runs, as in real use.
            MoveDesktop(Native.VK_RIGHT); Wait(1500);
            Log("after Win+Ctrl+Right: desktop " + Desktops.CurrentIndex());
            Open("notepad.exe", Doc(deskTitle + ".txt")); Wait(2500);
            MoveDesktop(Native.VK_LEFT); Wait(1500);
            Log("after Win+Ctrl+Left: desktop " + Desktops.CurrentIndex());

            int cur = 0;
            var pages = UI(() => Windows.Pages(out cur));
            Log("pages: " + string.Join(", ", pages.Select(p => p.Title + "=" + p.Items.Count)) + "  current=" + cur);
            Check("one page per desktop", pages.Count == Desktops.List().Count && pages.Count >= 2, pages.Count + " pages");
            Check("the test window is listed on the Desktop 2 page",
                  pages.Count > cur + 1 && pages[cur + 1].Items.Any(w => w.Title.StartsWith(deskTitle)));
            var home = List().FirstOrDefault();

            Alt(true); Tab(); Wait(600); Press(Native.VK_RIGHT); Wait(400);
            Check("Right arrow shows the next desktop", Get(s => s.PageNumber) == 1 && Get(s => s.PageTitle) == "Desktop 2",
                  "page=" + Get(s => s.PageNumber) + " " + Get(s => s.PageTitle));
            var picked = Get(s => s.SelectedItem);
            Check("its last-used window is selected", picked != null && picked.Title.StartsWith(deskTitle), picked == null ? "none" : picked.Title);
            Press(Native.VK_LEFT); Wait(400);
            Check("Left arrow goes back", Get(s => s.PageNumber) == 0, "page=" + Get(s => s.PageNumber));
            Press(Native.VK_RIGHT); Wait(400);
            Alt(false); Wait(2200);
            Check("picking a window on Desktop 2 moves to Desktop 2", Desktops.CurrentIndex() == 1, "desktop " + Desktops.CurrentIndex());
            Check("and brings that window to the front", Front().StartsWith(deskTitle), "front=" + Front());

            Alt(true); Tab(); Wait(600); Press(Native.VK_LEFT); Wait(400);
            var sel = Get(s => s.SelectedItem);
            Check("from Desktop 2, Left arrow shows Desktop 1 with its last window selected",
                  Get(s => s.PageNumber) == 0 && sel != null && home != null && sel.Handle == home.Handle,
                  "page=" + Get(s => s.PageNumber) + " sel=" + (sel == null ? "none" : sel.Title) + " expected=" + (home == null ? "none" : home.Title));
            Alt(false); Wait(2200);
            Check("picking it moves back to Desktop 1", Desktops.CurrentIndex() == 0, "desktop " + Desktops.CurrentIndex());
            Check("and brings that window to the front", home != null && Native.GetForegroundWindow() == home.Handle, "front=" + Front());
        }

        static void Screenshot(string path)
        {
            var r = UI(() => S.Panel.Bounds);
            if (r.Width <= 0) return;
            using (var bmp = new Bitmap(r.Width, r.Height))
            {
                using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(r.Location, Point.Empty, r.Size);
                bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
            }
        }
    }
}
#endif
