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
        lock (Gate) return Send(target);
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
        var matches = new HashSet<IntPtr>();
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
                    if (item.Handle != IntPtr.Zero && (IsModel(item.Description) || (namedDevice && count == 1)))
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
    readonly ToolStripItem switchItem, readItem, stopRelayItem;
    const string SettingsPath = @"Software\HKC-MG24Q-ScreenSwitch";
    Relay relay;
    IPAddress relayAddress;
    byte[] relayKey;
    bool hotkeyRegistered, busy;

    public TrayApp()
    {
        ShowInTaskbar = false;
        menu = new ContextMenuStrip();
        switchItem = menu.Items.Add("切回 Mac（HDMI 2）", null, delegate { StartOperation(false); });
        readItem = menu.Items.Add("读取当前输入源", null, delegate { StartOperation(true); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("扩展坞模式：启用或复制配对码…", null, delegate { ConfigureRelay(); });
        stopRelayItem = menu.Items.Add("关闭扩展坞中转", null, delegate { StopRelay(); });
        stopRelayItem.Enabled = false;
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, delegate { Close(); });
        tray = new NotifyIcon { Text = "换屏 · HKC MG24Q", Icon = SystemIcons.Application, ContextMenuStrip = menu, Visible = true };
    }

    public void RestoreRelay()
    {
        try
        {
            using (var settings = Registry.CurrentUser.OpenSubKey(SettingsPath))
            {
                if (settings == null) return;
                relayKey = settings.GetValue("RelayKey") as byte[];
                IPAddress address;
                if (relayKey != null && relayKey.Length == 32 &&
                    IPAddress.TryParse(settings.GetValue("RelayAddress") as string, out address) &&
                    Relay.IsPrivateIPv4(address))
                    StartRelay(address);
            }
        }
        catch (SocketException)
        {
            tray.ShowBalloonTip(5000, "换屏", "中转地址已不可用，请从托盘重新配对。", ToolTipIcon.Warning);
        }
        catch (SecurityException)
        {
            tray.ShowBalloonTip(5000, "换屏", "无法读取已保存的中转设置。", ToolTipIcon.Warning);
        }
    }

    void StartRelay(IPAddress address)
    {
        if (relay != null && address.Equals(relayAddress)) return;
        var next = new Relay(address, relayKey, delegate
        {
            try { MonitorInput.Run(MonitorInput.WindowsInput); return 0; }
            catch (MonitorUnavailableException) { return 1; }
            catch (Win32Exception) { return 2; }
            catch (InvalidOperationException) { return 2; }
        });
        if (relay != null) relay.Dispose();
        relay = next;
        relayAddress = address;
        stopRelayItem.Enabled = true;
    }

    void StopRelay()
    {
        if (relay != null) relay.Dispose();
        relay = null;
        stopRelayItem.Enabled = false;
        try
        {
            using (var settings = Registry.CurrentUser.CreateSubKey(SettingsPath))
                settings.DeleteValue("RelayAddress", false);
        }
        catch (Exception error)
        {
            MessageBox.Show("本次中转已停止，但无法保存设置。\n" + error.Message, "换屏");
        }
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
            using (var cancel = new Button())
            {
                dialog.Text = "换屏 · 配对 Mac";
                dialog.ClientSize = new Size(360, 132);
                dialog.FormBorderStyle = FormBorderStyle.FixedDialog;
                dialog.MaximizeBox = dialog.MinimizeBox = false;
                dialog.StartPosition = FormStartPosition.CenterScreen;
                layout.Dock = DockStyle.Fill;
                layout.Padding = new Padding(10);
                var label = new Label { Text = "选择和 Mac 在同一局域网的 Windows 地址。", AutoSize = true };
                layout.Controls.Add(label);
                layout.SetFlowBreak(label, true);
                addressBox.Width = 325;
                addressBox.DropDownStyle = ComboBoxStyle.DropDownList;
                foreach (IPAddress address in addresses) addressBox.Items.Add(address);
                int current = Array.IndexOf(addresses, relayAddress);
                addressBox.SelectedIndex = Math.Max(0, current);
                layout.Controls.Add(addressBox);
                layout.SetFlowBreak(addressBox, true);
                copy.Text = "开启并复制配对码";
                copy.AutoSize = true;
                copy.DialogResult = DialogResult.OK;
                cancel.Text = "取消";
                cancel.DialogResult = DialogResult.Cancel;
                layout.Controls.Add(copy);
                layout.Controls.Add(cancel);
                dialog.Controls.Add(layout);
                dialog.AcceptButton = copy;
                dialog.CancelButton = cancel;
                if (dialog.ShowDialog() != DialogResult.OK) return;

                var selected = (IPAddress)addressBox.SelectedItem;
                if (relayKey == null || relayKey.Length != 32) relayKey = Relay.NewKey();
                StartRelay(selected);
                using (var settings = Registry.CurrentUser.CreateSubKey(SettingsPath))
                {
                    settings.SetValue("RelayKey", relayKey, RegistryValueKind.Binary);
                    settings.SetValue("RelayAddress", selected.ToString());
                }
                Clipboard.SetText("SS1:" + selected + ":" + Convert.ToBase64String(relayKey));
                MessageBox.Show("配对码已复制。请在 Mac 菜单栏「换屏 → 配对 Windows 中转」里粘贴。\n若防火墙询问，请仅允许私人网络。", "换屏");
            }
        }
        catch (Exception error)
        {
            MessageBox.Show("无法完成扩展坞配对。\n" + error.Message, "换屏");
        }
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
        worker.DoWork += delegate(object sender, DoWorkEventArgs args) { args.Result = MonitorInput.Run(read ? 0 : MonitorInput.MacInput); };
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
                app.RestoreRelay();
                Application.Run(new ApplicationContext(app));
            }
        }
    }
}
