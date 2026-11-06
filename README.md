# 换屏 (ScreenSwitch) · HKC MG24Q 双电脑一键切屏工具

通过软件全局快捷键，在 **Mac (HDMI 2)** 与 **Windows PC (DisplayPort)** 之间一键无缝切换 HKC MG24Q 显示器输入源。无需每次伸手按显示器背后生涩的物理摇杆。

---

## 快捷键

两端使用同一组按键习惯，按键由当前操作的电脑接收：

- **Mac 端**：`Control + Option + Command + M` (`⌃⌥⌘M`)
- **Windows 端**：`Ctrl + Alt + Shift + M`

---

## 工作模式

### 1. 直连模式（推荐）
- **连接方式**：Mac 视频线直接接入显示器 HDMI 2（通过 Mac 自带 HDMI 口或独立 Type-C 转 HDMI 线直插）；Windows 接 DP。
- **工作机制**：Mac 本地通过 Apple Silicon 的 IOKit / `DCPAVServiceProxy` 发送 DDC/CI VCP Set 指令（0x60 -> 0x0F），毫秒级直接切换，**完全不需要 Windows 电脑配合中转**。
- **切换速度优化建议**：
  > 切换输入源时显示器黑屏约 1~2 秒属于正常物理硬件握手（Link Training）。若想压到最短，建议将 **Mac 和 Windows 的分辨率与刷新率对齐（如均设为 2K @ 120Hz 或 144Hz）**，避免显示器切源时因突跳刷新率触发额外的时钟复位延时。

---

### 2. 扩展坞中转模式（LAN Relay）
- **适用场景**：Mac 必须通过多功能 USB-C 扩展坞连接显示器 HDMI。
- **为何需要中转**：
  市面上大部分 USB-C 拓展坞内部使用 DP-to-HDMI 协议转换芯片（LSPCON）。虽然能读取 EDID，但硬件芯片丢弃了 I²C 地址 0x37（DDC/CI 控制指令）。
  扩展坞模式让 Mac 通过局域网向 Windows 发送加密认证请求，Windows 通过原生直连的 DP 口调用 `SetVCPFeature` 指令切换显示器输入源。

#### 扩展坞模式配置步骤：
1. **Windows 端**：
   - 双击 `Windows/Start-Windows.cmd`（自动调用 .NET 编译并启动 `ScreenSwitch.exe`）；
   - 右键右下角托盘图标，选择「扩展坞模式：启用或复制配对码」，选择局域网 IP 并点击「开启并复制配对码」。
2. **Mac 端**：
   - 打开 `Mac/ScreenSwitch.app`；
   - 点击菜单栏图标「配对 Windows 中转…」，粘贴配对码并确认；
   - 勾选「自动回退（直连失败时用中转）」，即可实现优先直连、断开时自动走网络中转的双保险。

---

## 目录结构

```text
├── Mac/
│   ├── ScreenSwitch.m        # Mac 菜单栏主程序 (DDC/CI 通信、状态管理与网络中转)
│   ├── Relay.h / Relay.m     # 安全局域网客户端 (HMAC-SHA256 挑战应答协议)
│   ├── screenswitch_tool.m   # 命令行底层 DDC 通道与闪烁诊断工具
│   ├── Info.plist            # macOS 应用程序属性列表
│   ├── build.sh              # 编译与代码签名脚本
│   └── ScreenSwitch.app/     # 编译就绪的 macOS 原生应用程序
├── Windows/
│   ├── ScreenSwitch.cs       # Windows 托盘主程序 (Dxva2 DDC/CI API)
│   ├── Relay.cs              # 局域网 TCP 监听服务端
│   └── Start-Windows.cmd     # Windows 一键编译与运行脚本
└── README.md
```

---

## 编译指南

### Mac
系统需装有 Xcode Command Line Tools：
```bash
cd Mac
bash build.sh
```

### Windows
Windows 7/10/11 自带 .NET Framework 4.x，双击运行 `Windows/Start-Windows.cmd` 即可自动编译生成 `ScreenSwitch.exe`。

---

## 参考与致谢
- [waydabber/m1ddc](https://github.com/waydabber/m1ddc)
- [Microsoft Low Level Monitor Configuration API (SetVCPFeature)](https://learn.microsoft.com/en-us/windows/win32/api/lowlevelmonitorconfigurationapi/nf-lowlevelmonitorconfigurationapi-setvcpfeature)
- [VESA DDC/CI Standard Specification](https://en.wikipedia.org/wiki/Display_Data_Channel)
