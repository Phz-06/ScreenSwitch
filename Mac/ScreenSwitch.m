#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/i2c/IOI2CInterface.h>
#include <dlfcn.h>
#include <unistd.h>
#import "Relay.h"

static NSString *const RelayCodeKey = @"RelayPairingCode";
static NSString *const RelayEnabledKey = @"RelayEnabled";
static NSString *const AutoFallbackKey = @"AutoFallback";
static const uint8_t InputSelect = 0x60;
static const uint8_t WindowsInput = 0x0f; // DisplayPort
static const uint8_t MacInput = 0x12;     // HDMI 2

static uint8_t g_lastDirectTarget = WindowsInput;

typedef CFTypeRef (*CreateAVService)(CFAllocatorRef, io_service_t);
typedef IOReturn (*I2CTransfer)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);

static NSMutableString *diagLog = nil;
static void DiagAppend(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void DiagAppend(NSString *format, ...) {
    if (!diagLog) return;
    va_list args;
    va_start(args, format);
    [diagLog appendString:[[NSString alloc] initWithFormat:format arguments:args]];
    [diagLog appendString:@"\n"];
    va_end(args);
}

static uint8_t Checksum(uint8_t seed, const uint8_t *bytes, size_t count) {
    for (size_t i = 0; i < count; i++) seed ^= bytes[i];
    return seed;
}

static NSString *DDCWriteOnly(uint8_t target, NSString **error) {
    if (target == 0) {
        *error = @"只写模式不支持读取操作。";
        return nil;
    }

    CreateAVService create = dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
    I2CTransfer write = dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
    if (!create || !write) {
        *error = @"这个 macOS 版本没有可用的 I2C 写入接口。";
        return nil;
    }

    io_iterator_t services = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &services)) {
        *error = @"[只写] 无法枚举 DCPAVServiceProxy。";
        return nil;
    }

    CFTypeRef service = NULL;
    io_service_t entry;
    while ((entry = IOIteratorNext(services))) {
        NSString *location = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR("Location"), NULL, 0));
        if (![location isEqualToString:@"Embedded"] && ![location isEqualToString:@"Internal"]) {
            if (!service) service = create(kCFAllocatorDefault, entry);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(services);

    if (!service) {
        *error = @"[只写] 没找到外接屏 DCPAVServiceProxy。";
        return nil;
    }

    NSString *result = nil;
    for (unsigned attempt = 0; attempt < 3 && !result; attempt++) {
        uint8_t message[] = {0x84, 0x03, InputSelect, 0x00, target, 0};
        message[5] = Checksum(0x6e ^ 0x51, message, 5);
        IOReturn status = write(service, 0x37, 0x51, message, sizeof(message));
        DiagAppend(@"[只写] 尝试 %u: write(0x37, 0x51) → 0x%08x", attempt, status);
        if (status == kIOReturnSuccess) {
            result = [NSString stringWithFormat:@"已发送切换指令到 0x%02X。", target];
        }
        if (!result && attempt < 2) usleep(30000);
    }

    CFRelease(service);
    if (!result) {
        *error = @"[只写] DDC 写入失败。";
    }
    return result;
}

static CFTypeRef OpenMonitor_DCPAVService(CreateAVService create, NSString **error) {
    uint32_t count = 0;
    CGDirectDisplayID displays[16];
    if (CGGetOnlineDisplayList(16, displays, &count) != kCGErrorSuccess || count == 16) {
        *error = @"无法读取显示器列表。";
        return NULL;
    }

    unsigned external = 0;
    BOOL found = NO;
    for (uint32_t i = 0; i < count; i++) {
        if (CGDisplayIsBuiltin(displays[i])) continue;
        external++;
        found |= CGDisplayVendorNumber(displays[i]) == 0x2163 &&
                 CGDisplayModelNumber(displays[i]) == 0x2420;
    }

    if (!found || external != 1) {
        *error = @"未能唯一识别 HKC MG24Q。请确认屏幕正在显示 Mac。";
        return NULL;
    }

    io_iterator_t services = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &services)) {
        *error = @"无法枚举 DCPAVServiceProxy。";
        return NULL;
    }

    CFTypeRef service = NULL;
    unsigned matches = 0;
    io_service_t entry;
    while ((entry = IOIteratorNext(services))) {
        NSString *location = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR("Location"), NULL, 0));
        if ([location isEqualToString:@"External"] && ++matches == 1) {
            service = create(kCFAllocatorDefault, entry);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(services);

    if (matches != 1 || !service) {
        if (service) CFRelease(service);
        *error = @"无法打开外接屏控制通道。";
        return NULL;
    }
    return service;
}

static NSString *DDCCommand(CFTypeRef service, I2CTransfer write, I2CTransfer read,
                            uint8_t target, NSString **error) {
    IOReturn status = kIOReturnError;
    NSString *result = nil;
    for (unsigned attempt = 0; attempt < 3 && !result; attempt++) {
        if (target) {
            uint8_t message[] = {0x84, 0x03, InputSelect, 0x00, target, 0};
            message[5] = Checksum(0x6e ^ 0x51, message, 5);
            status = write(service, 0x37, 0x51, message, sizeof(message));
            if (status == kIOReturnSuccess) result = @"已发送切换指令。";
        } else {
            BOOL alternate = attempt > 0;
            uint8_t message[] = {0x82, 0x01, InputSelect, 0};
            message[3] = Checksum(alternate ? 0x6e ^ 0x51 : 0x6e, message, 3);
            status = write(service, 0x37, 0x51, message, sizeof(message));
            if (alternate) {
                usleep(10000);
                status = write(service, 0x37, 0x51, message, sizeof(message));
            }
            if (status == kIOReturnSuccess) {
                usleep(60000 << attempt);
                uint8_t reply[12] = {0};
                status = read(service, 0x37, alternate ? 0x51 : 0, reply, alternate ? 12 : 11);
                if (alternate && reply[1] == 0x51) reply[1] = 0x88;
                if (status == kIOReturnSuccess && reply[0] == 0x6e && reply[1] == 0x88 &&
                    reply[2] == 0x02 && reply[4] == InputSelect &&
                    Checksum(0x50, reply, 11) == 0) {
                    if (reply[3] != 0) {
                        *error = @"显示器回复不支持通过 DDC/CI 读取输入源。";
                        break;
                    }
                    result = [NSString stringWithFormat:@"HKC MG24Q 当前输入源代码是 0x%04X。", (reply[8] << 8) | reply[9]];
                }
            }
        }
        if (!result && attempt < 2) usleep(35000);
    }
    return result;
}

static NSString *MonitorInput(uint8_t target, NSString **error) {
    if (target != 0) {
        NSString *writeResult = DDCWriteOnly(target, error);
        if (writeResult) return writeResult;
    }

    CreateAVService create = dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
    I2CTransfer write = dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
    I2CTransfer read = dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");
    if (!create || !write || !read) {
        *error = @"这个 macOS 版本没有可用的显示器控制接口。";
        return nil;
    }

    CFTypeRef service = OpenMonitor_DCPAVService(create, error);
    if (!service) return nil;

    NSString *result = DDCCommand(service, write, read, target, error);
    CFRelease(service);
    return result;
}

@interface ScreenSwitch : NSObject <NSApplicationDelegate>
@property NSStatusItem *statusItem;
@property NSMenuItem *toggleItem;
@property NSMenuItem *toWinItem;
@property NSMenuItem *toMacItem;
@property NSMenuItem *readItem;
@property NSMenuItem *pairItem;
@property NSMenuItem *relayItem;
@property NSMenuItem *testItem;
@property EventHotKeyRef hotKey;
@property EventHandlerRef eventHandler;
@property BOOL busy;
- (void)toggleInput:(id)sender;
@end

static OSStatus HotKeyPressed(EventHandlerCallRef next, EventRef event, void *context) {
    EventHotKeyID key;
    OSStatus status = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                                         NULL, sizeof(key), NULL, &key);
    if (status != noErr || key.signature != 'ScSw' || key.id != 1) return eventNotHandledErr;
    [(__bridge ScreenSwitch *)context toggleInput:nil];
    return noErr;
}

@implementation ScreenSwitch
- (NSMenuItem *)item:(NSString *)title action:(SEL)action menu:(NSMenu *)menu {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    return item;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"换屏";
    self.statusItem.button.toolTip = @"HKC MG24Q 双电脑一键切换";
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;

    self.toggleItem = [self item:@"切换下一个设备 · ⌃⌥⌘M" action:@selector(toggleInput:) menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    self.toWinItem = [self item:@"强制切到 Windows (DP)" action:@selector(switchToWindows:) menu:menu];
    self.toMacItem = [self item:@"强制切到 Mac (HDMI 2)" action:@selector(switchToMac:) menu:menu];
    self.readItem = [self item:@"读取当前输入源" action:@selector(readInput:) menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    self.pairItem = [self item:@"配对 Windows 中转…" action:@selector(pairRelay:) menu:menu];
    self.relayItem = [self item:@"使用扩展坞模式 (局域网中转)" action:@selector(toggleRelay:) menu:menu];
    self.testItem = [self item:@"测试 Windows 中转连接" action:@selector(testRelay:) menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    [self item:@"退出" action:@selector(quit:) menu:menu];
    
    // 默认记住历史连接：如果已配对过，启动时确保扩展坞模式生效
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *savedCode = [defaults stringForKey:RelayCodeKey];
    if (ValidRelayCode(savedCode ?: @"")) {
        if (![defaults objectForKey:RelayEnabledKey]) {
            [defaults setBool:YES forKey:RelayEnabledKey];
        }
    }

    [self refreshMenu];
    self.statusItem.menu = menu;

    EventTypeSpec event = {kEventClassKeyboard, kEventHotKeyPressed};
    OSStatus status = InstallApplicationEventHandler(HotKeyPressed, 1, &event, (__bridge void *)self, &_eventHandler);
    if (status == noErr) {
        EventHotKeyID key = {'ScSw', 1};
        RegisterEventHotKey(kVK_ANSI_M, controlKey | optionKey | cmdKey,
                            key, GetApplicationEventTarget(), 0, &_hotKey);
    }
}

- (void)showMessage:(NSString *)message {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"换屏";
    alert.informativeText = message;
    [NSApp activate];
    [alert runModal];
}

- (void)refreshMenu {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL paired = ValidRelayCode([defaults stringForKey:RelayCodeKey] ?: @"");
    self.relayItem.state = [defaults boolForKey:RelayEnabledKey] && paired ? NSControlStateValueOn : NSControlStateValueOff;
    self.toggleItem.enabled = !self.busy;
    self.toWinItem.enabled = !self.busy;
    self.toMacItem.enabled = !self.busy;
    self.readItem.enabled = !self.busy;
    self.pairItem.enabled = !self.busy;
    self.relayItem.enabled = paired && !self.busy;
    self.testItem.enabled = paired && !self.busy;
}

- (void)pairRelay:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"配对 Windows 中转";
    alert.informativeText = @"从 Windows 托盘复制配对码并粘贴到这里。配对成功后将自动记住并永久自动连接。";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 24)];
    field.placeholderString = @"SS1:…";
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"配对并保存"];
    [alert addButtonWithTitle:@"取消"];
    alert.window.initialFirstResponder = field;
    self.busy = YES;
    [self refreshMenu];
    [NSApp activate];
    NSModalResponse response = [alert runModal];
    self.busy = NO;
    [self refreshMenu];
    if (response != NSAlertFirstButtonReturn) return;

    NSString *code = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!ValidRelayCode(code)) {
        [self showMessage:@"配对码格式不正确，请重新从 Windows 复制。"];
        return;
    }
    [self runCommand:0 relayCode:code save:YES];
}

- (void)toggleRelay:(id)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:![defaults boolForKey:RelayEnabledKey] forKey:RelayEnabledKey];
    [self refreshMenu];
}

// 核心执行：支持 command 0 (probe), 1 (toWin), 2 (toMac), 3 (Toggle)
- (void)runCommand:(uint8_t)command relayCode:(NSString *)code save:(BOOL)save {
    if (self.busy) return;
    self.busy = YES;
    [self refreshMenu];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSString *result = nil;

        if (code) {
            // 通过局域网向 Windows 发送切换请求 (支持自动子网自愈重连)
            result = RelayRequestCommand(code, command, &error);
            NSString *updatedCode = RelayGetUpdatedCode();
            if (updatedCode) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSUserDefaults.standardUserDefaults setObject:updatedCode forKey:RelayCodeKey];
                });
            }
        } else {
            // 本地直连 DDC 切换
            uint8_t directTarget = WindowsInput;
            if (command == 1) directTarget = WindowsInput;
            else if (command == 2) directTarget = MacInput;
            else if (command == 3) {
                // 本地 Toggle 交替
                directTarget = (g_lastDirectTarget == WindowsInput) ? MacInput : WindowsInput;
                g_lastDirectTarget = directTarget;
            } else directTarget = 0; // read

            result = MonitorInput(directTarget, &error);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (save && result) {
                [NSUserDefaults.standardUserDefaults setObject:code forKey:RelayCodeKey];
                [NSUserDefaults.standardUserDefaults setBool:YES forKey:RelayEnabledKey];
            }
            if (command == 0 || error) {
                NSString *message = save && result ? @"Windows 中转已连接！以后每次启动均会自动连接，按 ⌃⌥⇧M 即可在两台电脑间交替切换。" : result;
                [self showMessage:error ?: message];
            }
            self.busy = NO;
            [self refreshMenu];
        });
    });
}

// 一键交替切换下一个设备
- (void)toggleInput:(id)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *code = nil;
    if ([defaults boolForKey:RelayEnabledKey]) {
        code = [defaults stringForKey:RelayCodeKey];
    }
    [self runCommand:3 relayCode:code save:NO];
}

- (void)switchToWindows:(id)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *code = [defaults boolForKey:RelayEnabledKey] ? [defaults stringForKey:RelayCodeKey] : nil;
    [self runCommand:1 relayCode:code save:NO];
}

- (void)switchToMac:(id)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *code = [defaults boolForKey:RelayEnabledKey] ? [defaults stringForKey:RelayCodeKey] : nil;
    [self runCommand:2 relayCode:code save:NO];
}

- (void)readInput:(id)sender {
    [self runCommand:0 relayCode:nil save:NO];
}

- (void)testRelay:(id)sender {
    NSString *code = [NSUserDefaults.standardUserDefaults stringForKey:RelayCodeKey];
    [self runCommand:0 relayCode:code save:NO];
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (self.hotKey) UnregisterEventHotKey(self.hotKey);
    if (self.eventHandler) RemoveEventHandler(self.eventHandler);
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--probe") == 0) {
            NSString *error = nil;
            NSString *result = MonitorInput(0, &error);
            fprintf(result ? stdout : stderr, "%s\n", (result ?: error).UTF8String);
            return result ? 0 : 1;
        }
        if (argc != 1) return 2;

        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        ScreenSwitch *delegate = [ScreenSwitch new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
