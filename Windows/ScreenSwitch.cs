using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security;
using Microsoft.Win32;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

sealed class MonitorUnavailableException : InvalidOperationException
{
    public MonitorUnavailableException() : base("未能唯一识别 HKC MG24Q。请确认屏幕已连接，且未开启复制屏幕模式。") { }
}

static class MonitorInput
{
    const byte InputSelect = 0x60;
    public const uint MacInput = 0x12; // HDMI 2
    public const uint WindowsInput = 0x0f; // DisplayPort
    static readonly object Gate = new object();
    static uint lastSwitchedTarget = MacInput;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PhysicalMonitor
    {
        public IntPtr Handle;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct Rect { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MonitorInfo
    {
        public int Size;
        public Rect Bounds, WorkArea;
        public int Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Device;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DisplayDevice
    {
        public int Size;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Id;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Key;
    }

    delegate bool MonitorCallback(IntPtr monitor, IntPtr dc, IntPtr rect, IntPtr data);

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorCallback callback, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplayDevices(string device, uint index, ref DisplayDevice child, uint flags);
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr monitor, out uint count);
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr monitor, uint count, [Out] PhysicalMonitor[] physical);
    [DllImport("dxva2.dll")]
    static extern bool DestroyPhysicalMonitors(uint count, PhysicalMonitor[] physical);
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr monitor, byte code, IntPtr type, out uint value, IntPtr maximum);
    [DllImport("dxva2.dll", SetLastError = true)]
    static extern bool SetVCPFeature(IntPtr monitor, byte code, uint value);

    static bool IsModel(string description)
    {
        return description != null && description.IndexOf("MG24Q", StringComparison.OrdinalIgnoreCase) >= 0;
    }

    static bool HasModelDevice(IntPtr monitor)
    {
        var info = new MonitorInfo { Size = Marshal.SizeOf(typeof(MonitorInfo)) };
        if (!GetMonitorInfo(monitor, ref info)) return false;
        var child = new DisplayDevice { Size = Marshal.SizeOf(typeof(DisplayDevice)) };
        for (uint index = 0; EnumDisplayDevices(info.Device, index, ref child, 0); index++)
        {
            if (IsModel(child.Description)) return true;
            foreach (string segment in (child.Id ?? "").Split('\\'))
                if (String.Equals(segment, "HKC2420", StringComparison.OrdinalIgnoreCase)) return true;
            child.Size = Marshal.SizeOf(typeof(DisplayDevice));
        }
        return false;
    }

    public static string Run(uint target)
    {
        lock (Gate)
        {
            if (target != 0) lastSwitchedTarget = target;
            return Send(target);
        }
    }

    public static string Toggle()
    {
        lock (Gate)
        {
            uint current = 0;
            try { current = ReadCurrent(); } catch { }

            uint target;
            if (current == WindowsInput)
                target = MacInput;
            else if (current == MacInput)
                target = WindowsInput;
            else
                target = (lastSwitchedTarget == WindowsInput) ? MacInput : WindowsInput;

            lastSwitchedTarget = target;
            return Send(target);
        }
    }

    static uint ReadCurrent()
    {
        var logical = new List<IntPtr>();
        MonitorCallback collect = delegate(IntPtr monitor, IntPtr dc, IntPtr rect, IntPtr data)
        {
            logical.Add(monitor);
            return true;
        };
        if (!EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, collect, IntPtr.Zero))
            return 0;

        var opened = new List<PhysicalMonitor[]>();
        try
        {
            foreach (IntPtr monitor in logical)
            {
                bool namedDevice = HasModelDevice(monitor);
                uint count;
                if (!GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, out count) || count == 0) continue;
                var physical = new PhysicalMonitor[count];
                if (!GetPhysicalMonitorsFromHMONITOR(monitor, count, physical)) continue;
                opened.Add(physical);
                foreach (PhysicalMonitor item in physical)
                {
                    if (IsModel(item.Description) || (namedDevice && count == 1))
                    {
                        uint current;
                        if (GetVCPFeatureAndVCPFeatureReply(item.Handle, InputSelect, IntPtr.Zero, out current, IntPtr.Zero))
                            return current;
                    }
                }
            }
            return 0;
        }
        finally
        {
            foreach (PhysicalMonitor[] physical in opened)
                DestroyPhysicalMonitors((uint)physical.Length, physical);
        }
    }

    static string Send(uint target)
    {
        var logical = new List<IntPtr>();
        MonitorCallback collect = delegate(IntPtr monitor, IntPtr dc, IntPtr rect, IntPtr data)
        {
            logical.Add(monitor);
            return true;
        };
        if (!EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, collect, IntPtr.Zero))
            throw new Win32Exception();

        var opened = new List<PhysicalMonitor[]>();
        var matches = new List<IntPtr>();
        try
        {
            foreach (IntPtr monitor in logical)
            {
                bool namedDevice = HasModelDevice(monitor);
                uint count;
                if (!GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, out count) || count == 0)
                {
                    if (namedDevice) throw new InvalidOperationException("找到了 MG24Q，但 Windows 无法打开它的控制通道。");
                    continue;
                }
                var physical = new PhysicalMonitor[count];
                if (!GetPhysicalMonitorsFromHMONITOR(monitor, count, physical))
                {
                    if (namedDevice) throw new Win32Exception();
                    continue;
                }
                opened.Add(physical);
                foreach (PhysicalMonitor item in physical)
                    if (IsModel(item.Description) || (namedDevice && count == 1))
                        matches.Add(item.Handle);
            }

            if (matches.Count != 1)
                throw new MonitorUnavailableException();

            foreach (IntPtr handle in matches)
            {
                if (target == 0)
                {
                    uint current;
                    if (!GetVCPFeatureAndVCPFeatureReply(handle, InputSelect, IntPtr.Zero, out current, IntPtr.Zero))
                        throw new Win32Exception();
                    return String.Format("HKC MG24Q 当前输入源是 0x{0:X2}。\n常见值：0x0F = DP，0x11 = HDMI 1，0x12 = HDMI 2。", current);
                }
                if (!SetVCPFeature(handle, InputSelect, target))
                    throw new Win32Exception();
            }
            return "已发送切换指令。";
        }
        finally
        {
            foreach (PhysicalMonitor[] physical in opened)
                DestroyPhysicalMonitors((uint)physical.Length, physical);
        }
    }
}

sealed class TrayApp : Form
{
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")]
    static extern bool UnregisterHotKey(IntPtr window, int id);

    const int HotkeyId = 1;
    const int WmHotkey = 0x0312;
    const uint CtrlAltShiftNoRepeat = 0x4007;
    readonly NotifyIcon tray;
    readonly ContextMenuStrip menu;
    readonly ToolStripItem switchItem, readItem;
    const string SettingsPath = @"Software\HKC-MG24Q-ScreenSwitch";
    Relay relay;
    IPAddress relayAddress;
    byte[] relayKey;
    bool hotkeyRegistered, busy;

    public TrayApp()
    {
        ShowInTaskbar = false;
        menu = new ContextMenuStrip();
        switchItem = menu.Items.Add("切换下一个设备", null, delegate { StartOperation(false); });
        readItem = menu.Items.Add("读取当前输入源", null, delegate { StartOperation(true); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("扩展坞模式：查看或复制配对码…", null, delegate { ConfigureRelay(); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, delegate { Close(); });
        tray = new NotifyIcon { Text = "换屏 · HKC MG24Q", Icon = SystemIcons.Application, ContextMenuStrip = menu, Visible = true };
        tray.MouseClick += delegate(object sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left)
                tray.ShowBalloonTip(3000, "换屏 · HKC MG24Q", "运行中：按 Ctrl+Alt+Shift+M 切换设备，右键打开设置菜单。", ToolTipIcon.Info);
        };
    }

    public void RestoreOrAutoStartRelay()
    {
        try
        {
            using (var settings = Registry.CurrentUser.CreateSubKey(SettingsPath))
            {
                relayKey = settings.GetValue("RelayKey") as byte[];
                if (relayKey == null || relayKey.Length != 32)
                {
                    relayKey = Relay.NewKey();
                    settings.SetValue("RelayKey", relayKey, RegistryValueKind.Binary);
                }

                IPAddress address;
                string savedAddr = settings.GetValue("RelayAddress") as string;
                if (!string.IsNullOrEmpty(savedAddr) && IPAddress.TryParse(savedAddr, out address) && Relay.IsPrivateIPv4(address))
                    relayAddress = address;
                else
                    relayAddress = Relay.GetPreferredPrivateIP();

                settings.SetValue("RelayAddress", relayAddress.ToString());
            }

            StartRelay(relayAddress);
        }
        catch (Exception error)
        {
            tray.ShowBalloonTip(4000, "换屏", "自动开启中转失败：" + error.Message, ToolTipIcon.Warning);
        }
    }

    void StartRelay(IPAddress address)
    {
        if (relay != null) relay.Dispose();
        relayAddress = address;
        relay = new Relay(IPAddress.Any, relayKey, delegate(byte command)
        {
            try
            {
                if (command == 1) { MonitorInput.Run(MonitorInput.WindowsInput); return 0; }
                if (command == 2) { MonitorInput.Run(MonitorInput.MacInput); return 0; }
                if (command == 3) { MonitorInput.Toggle(); return 0; }
                return 0; // command 0 is probe
            }
            catch (MonitorUnavailableException) { return 1; }
            catch (Win32Exception) { return 2; }
            catch (InvalidOperationException) { return 2; }
        });
    }

    void ConfigureRelay()
    {
        try
        {
            IPAddress[] addresses = NetworkInterface.GetAllNetworkInterfaces()
                .Where(adapter => adapter.OperationalStatus == OperationalStatus.Up)
                .SelectMany(adapter => adapter.GetIPProperties().UnicastAddresses)
                .Select(entry => entry.Address).Where(Relay.IsPrivateIPv4).Distinct().ToArray();
            if (addresses.Length == 0)
            {
                MessageBox.Show("Windows 没有可用的局域网 IPv4 地址。", "换屏");
                return;
            }

            using (var dialog = new Form())
            using (var layout = new FlowLayoutPanel())
            using (var addressBox = new ComboBox())
            using (var copy = new Button())
            using (var rekey = new Button())
            using (var cancel = new Button())
            {
                dialog.Text = "换屏 · 配对 Mac";
                dialog.ClientSize = new Size(380, 140);
                dialog.FormBorderStyle = FormBorderStyle.FixedDialog;
                dialog.MaximizeBox = dialog.MinimizeBox = false;
                dialog.StartPosition = FormStartPosition.CenterScreen;
                layout.Dock = DockStyle.Fill;
                layout.Padding = new Padding(10);
                var label = new Label { Text = "中转已默认自动开启。请选择并复制配对码：", AutoSize = true };
                layout.Controls.Add(label);
                layout.SetFlowBreak(label, true);

                addressBox.Width = 345;
                addressBox.DropDownStyle = ComboBoxStyle.DropDownList;
                foreach (IPAddress address in addresses) addressBox.Items.Add(address);
                int current = Array.IndexOf(addresses, relayAddress);
                addressBox.SelectedIndex = Math.Max(0, current);
                layout.Controls.Add(addressBox);
                layout.SetFlowBreak(addressBox, true);

                copy.Text = "复制配对码";
                copy.AutoSize = true;
                copy.DialogResult = DialogResult.OK;

                rekey.Text = "重置密钥";
                rekey.AutoSize = true;

                cancel.Text = "关闭";
                cancel.DialogResult = DialogResult.Cancel;

                rekey.Click += delegate
                {
                    if (MessageBox.Show("重置密钥后，Mac 端需要重新粘贴配对码。确认重置？", "换屏", MessageBoxButtons.YesNo) == DialogResult.Yes)
                    {
                        relayKey = Relay.NewKey();
                        using (var settings = Registry.CurrentUser.CreateSubKey(SettingsPath))
                            settings.SetValue("RelayKey", relayKey, RegistryValueKind.Binary);
                        MessageBox.Show("密钥已重置，请点击「复制配对码」并在 Mac 重新配对。", "换屏");
                    }
                };

                layout.Controls.Add(copy);
                layout.Controls.Add(rekey);
                layout.Controls.Add(cancel);
                dialog.Controls.Add(layout);
                dialog.AcceptButton = copy;
                dialog.CancelButton = cancel;

                if (dialog.ShowDialog() != DialogResult.OK) return;

                var selected = (IPAddress)addressBox.SelectedItem;
                relayAddress = selected;
                using (var settings = Registry.CurrentUser.CreateSubKey(SettingsPath))
                    settings.SetValue("RelayAddress", selected.ToString());

                Clipboard.SetText("SS1:" + selected + ":" + Convert.ToBase64String(relayKey));
                MessageBox.Show("配对码已复制！\n中转服务在后台持续运行，每次开机均会自动连接。\n请在 Mac 菜单栏「换屏 → 配对 Windows 中转」粘贴即可。", "换屏");
            }
        }
        catch (Exception error)
        {
            MessageBox.Show("无法完成配置。\n" + error.Message, "换屏");
        }
    }

    public void ShowStartupTip()
    {
        tray.ShowBalloonTip(4000, "换屏 · HKC MG24Q", "已在后台启动并自动开启扩展坞中转。\n按 Ctrl+Alt+Shift+M 切换设备。", ToolTipIcon.Info);
    }

    public void RegisterShortcut()
    {
        hotkeyRegistered = RegisterHotKey(Handle, HotkeyId, CtrlAltShiftNoRepeat, (uint)Keys.M);
        if (hotkeyRegistered) switchItem.Text += " · Ctrl+Alt+Shift+M";
        else MessageBox.Show("快捷键注册失败，可以用托盘菜单切换。", "换屏");
    }

    protected override void SetVisibleCore(bool value)
    {
        base.SetVisibleCore(false);
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WmHotkey && message.WParam.ToInt32() == HotkeyId)
            StartOperation(false);
        base.WndProc(ref message);
    }

    void StartOperation(bool read)
    {
        if (busy) return;
        busy = true;
        switchItem.Enabled = readItem.Enabled = false;
        var worker = new BackgroundWorker();
        worker.DoWork += delegate(object sender, DoWorkEventArgs args)
        {
            args.Result = read ? MonitorInput.Run(0) : MonitorInput.Toggle();
        };
        worker.RunWorkerCompleted += delegate(object sender, RunWorkerCompletedEventArgs args)
        {
            worker.Dispose();
            if (IsDisposed) return;
            try
            {
                if (args.Error != null)
                    MessageBox.Show("显示器控制失败。\n" + args.Error.Message, "换屏");
                else if (read)
                    MessageBox.Show((string)args.Result, "换屏");
            }
            finally
            {
                busy = false;
                switchItem.Enabled = readItem.Enabled = true;
            }
        };
        worker.RunWorkerAsync();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            if (relay != null) relay.Dispose();
            if (hotkeyRegistered && IsHandleCreated) UnregisterHotKey(Handle, HotkeyId);
            if (tray != null) tray.Dispose();
            if (menu != null) menu.Dispose();
        }
        base.Dispose(disposing);
    }

    [STAThread]
    static void Main()
    {
        bool first;
        using (var instance = new Mutex(true, "Local\\HKC-MG24Q-ScreenSwitch", out first))
        {
            if (!first)
            {
                MessageBox.Show("换屏已经在运行，请查看任务栏右侧的托盘图标。", "换屏");
                return;
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            using (var app = new TrayApp())
            {
                app.RegisterShortcut();
                app.RestoreOrAutoStartRelay();
                app.ShowStartupTip();
                Application.Run(new ApplicationContext(app));
            }
        }
    }
}
