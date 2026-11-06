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

typedef CFTypeRef (*CreateAVService)(CFAllocatorRef, io_service_t);
typedef IOReturn (*I2CTransfer)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);

// ──────────────────────────────────────────────────────────────────
// 诊断信息收集
// ──────────────────────────────────────────────────────────────────
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

// ──────────────────────────────────────────────────────────────────
// 方法 1: 原始 DCPAVServiceProxy 路径（直连时有效）
// ──────────────────────────────────────────────────────────────────
static CFTypeRef OpenMonitor_DCPAVService(CreateAVService create, NSString **error) {
    uint32_t count = 0;
    CGDirectDisplayID displays[16];
    if (CGGetOnlineDisplayList(16, displays, &count) != kCGErrorSuccess || count == 16) {
        *error = @"无法读取显示器列表。";
        return NULL;
    }

    DiagAppend(@"[DCPAVService] 在线显示器数量: %u", count);
    unsigned external = 0;
    BOOL found = NO;
    for (uint32_t i = 0; i < count; i++) {
        BOOL builtin = CGDisplayIsBuiltin(displays[i]);
        uint32_t vendor = CGDisplayVendorNumber(displays[i]);
        uint32_t model = CGDisplayModelNumber(displays[i]);
        DiagAppend(@"  显示器 %u: ID=0x%x, 内置=%d, 厂商=0x%04x, 型号=0x%04x",
                   i, displays[i], builtin, vendor, model);
        if (builtin) continue;
        external++;
        found |= vendor == 0x2163 && model == 0x2420;
    }
    DiagAppend(@"  外接屏数: %u, 找到 MG24Q: %d", external, found);

    if (!found || external != 1) {
        *error = @"[方法1] 未能唯一识别 HKC MG24Q。请确认屏幕正在显示 Mac，并暂时断开其他外接屏。";
        return NULL;
    }

    io_iterator_t services = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &services)) {
        *error = @"[方法1] 无法枚举 DCPAVServiceProxy。";
        return NULL;
    }

    CFTypeRef service = NULL;
    unsigned matches = 0;
    io_service_t entry;
    while ((entry = IOIteratorNext(services))) {
        NSString *location = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR("Location"), NULL, 0));
        NSString *name = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR("IOClass"), NULL, 0));
        io_name_t entryName;
        IORegistryEntryGetName(entry, entryName);
        DiagAppend(@"  DCPAVServiceProxy: name=%s, Location=%@, IOClass=%@", entryName, location, name);

        if ([location isEqualToString:@"External"] && ++matches == 1) {
            service = create(kCFAllocatorDefault, entry);
            DiagAppend(@"    → 已打开 (service=%p)", service);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(services);

    if (matches != 1 || !service) {
        if (service) CFRelease(service);
        *error = @"[方法1] 无法打开唯一的外接屏 DCPAVServiceProxy 通道。";
        return NULL;
    }
    return service;
}

// ──────────────────────────────────────────────────────────────────
// 方法 2: 宽松搜索 — 不限 Location=External，尝试所有 DCPAVServiceProxy
// ──────────────────────────────────────────────────────────────────
static CFTypeRef OpenMonitor_AllAVServices(CreateAVService create, NSString **error) {
    io_iterator_t services = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &services)) {
        *error = @"[方法2] 无法枚举 DCPAVServiceProxy。";
        return NULL;
    }

    NSMutableArray *candidates = [NSMutableArray new];
    io_service_t entry;
    while ((entry = IOIteratorNext(services))) {
        NSString *location = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR("Location"), NULL, 0));
        io_name_t entryName;
        IORegistryEntryGetName(entry, entryName);
        DiagAppend(@"[AllAVServices] entry=%s, Location=%@", entryName, location);

        // 跳过内建屏，但不限于 "External"
        if (![location isEqualToString:@"Embedded"] && ![location isEqualToString:@"Internal"]) {
            CFTypeRef s = create(kCFAllocatorDefault, entry);
            if (s) {
                DiagAppend(@"  → 打开成功 (service=%p, Location=%@)", s, location);
                [candidates addObject:(__bridge_transfer id)s];
            }
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(services);

    if (candidates.count == 0) {
        *error = @"[方法2] 未找到任何非内建的 DCPAVServiceProxy。";
        return NULL;
    }
    DiagAppend(@"[AllAVServices] 找到 %lu 个候选通道", (unsigned long)candidates.count);

    // 返回第一个（最可能是通过扩展坞连接的外接屏）
    CFTypeRef result = (__bridge_retained CFTypeRef)candidates[0];
    return result;
}

// ──────────────────────────────────────────────────────────────────
// 方法 3: IOFramebuffer I²C 路径（旧式 Intel Mac 路径，某些扩展坞可能走这条）
// ──────────────────────────────────────────────────────────────────
static BOOL TryFramebufferI2C(uint8_t target, NSString **result, NSString **error) {
    io_iterator_t iter = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("IOFramebufferI2CInterface"), &iter) != kIOReturnSuccess) {
        DiagAppend(@"[Framebuffer I2C] 无法枚举 IOFramebufferI2CInterface");
        return NO;
    }

    unsigned found = 0;
    io_service_t entry;
    while ((entry = IOIteratorNext(iter))) {
        io_name_t name;
        IORegistryEntryGetName(entry, name);
        DiagAppend(@"[Framebuffer I2C] 找到: %s", name);
        found++;

        IOI2CConnectRef connect = NULL;
        IOReturn kr = IOI2CInterfaceOpen(entry, kNilOptions, &connect);
        DiagAppend(@"  IOI2CInterfaceOpen → 0x%08x, connect=%p", kr, connect);

        if (kr == kIOReturnSuccess && connect) {
            // 尝试发送 DDC/CI 写命令
            IOI2CRequest request;
            memset(&request, 0, sizeof(request));
            request.sendTransactionType = kIOI2CSimpleTransactionType;
            request.sendAddress = 0x6e; // DDC/CI slave address (0x37 << 1)

            if (target) {
                // VCP Set: 写入输入源
                uint8_t message[] = {0x51, 0x84, 0x03, InputSelect, 0x00, target, 0};
                message[6] = 0x6e ^ 0x51;
                for (int i = 1; i < 6; i++) message[6] ^= message[i];
                request.sendBuffer = (vm_address_t)message;
                request.sendBytes = sizeof(message);
            } else {
                // VCP Get: 读取输入源
                uint8_t message[] = {0x51, 0x82, 0x01, InputSelect, 0};
                message[4] = 0x6e;
                for (int i = 0; i < 4; i++) message[4] ^= message[i];
                request.sendBuffer = (vm_address_t)message;
                request.sendBytes = sizeof(message);
            }

            kr = IOI2CSendRequest(connect, kNilOptions, &request);
            DiagAppend(@"  IOI2CSendRequest → 0x%08x, result=0x%08x", kr, (uint32_t)request.result);

            if (kr == kIOReturnSuccess && request.result == kIOReturnSuccess) {
                if (target) {
                    *result = @"[Framebuffer I2C] 已发送切换指令。";
                } else {
                    *result = @"[Framebuffer I2C] 命令已发送（需要单独读取结果）。";
                }
                IOI2CInterfaceClose(connect, kNilOptions);
                IOObjectRelease(entry);
                IOObjectRelease(iter);
                return YES;
            }
            IOI2CInterfaceClose(connect, kNilOptions);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iter);

    if (found == 0) {
        DiagAppend(@"[Framebuffer I2C] 未找到任何 IOFramebufferI2CInterface");
    }
    return NO;
}

// ──────────────────────────────────────────────────────────────────
// DDC/CI 协议辅助
// ──────────────────────────────────────────────────────────────────
static uint8_t Checksum(uint8_t seed, const uint8_t *bytes, size_t count) {
    for (size_t i = 0; i < count; i++) seed ^= bytes[i];
    return seed;
}

// ──────────────────────────────────────────────────────────────────
// "只写不读" DDC Set — 用于扩展坞场景（write 可能成功但 read 失败）
// ──────────────────────────────────────────────────────────────────
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

    // 找到外接屏的 DCPAVServiceProxy
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

    // 发送 VCP Set Input (0x60) = target，重试 3 次
    NSString *result = nil;
    for (unsigned attempt = 0; attempt < 3 && !result; attempt++) {
        uint8_t message[] = {0x84, 0x03, InputSelect, 0x00, target, 0};
        message[5] = Checksum(0x6e ^ 0x51, message, 5);
        IOReturn status = write(service, 0x37, 0x51, message, sizeof(message));
        DiagAppend(@"[只写] 尝试 %u: write(0x37, 0x51) → 0x%08x", attempt, status);
        if (status == kIOReturnSuccess) {
            result = @"[只写模式] DDC Set 指令已成功写入。如果屏幕切换了，说明扩展坞支持 DDC 写入！";
        }
        if (!result && attempt < 2) usleep(50000);
    }

    CFRelease(service);
    if (!result) {
        *error = @"[只写] DDC 写入也失败了，扩展坞不支持 I2C 转发。";
    }
    return result;
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
            DiagAppend(@"  DDC Set 尝试 %u: write → 0x%08x", attempt, status);
            if (status == kIOReturnSuccess) result = @"已发送切换指令。";
        } else {
            BOOL alternate = attempt > 0;
            uint8_t message[] = {0x82, 0x01, InputSelect, 0};
            message[3] = Checksum(alternate ? 0x6e ^ 0x51 : 0x6e, message, 3);
            status = write(service, 0x37, 0x51, message, sizeof(message));
            DiagAppend(@"  DDC Get 尝试 %u (alt=%d): write → 0x%08x", attempt, alternate, status);
            if (alternate) {
                usleep(10000);
                status = write(service, 0x37, 0x51, message, sizeof(message));
                DiagAppend(@"    重发: write → 0x%08x", status);
            }
            if (status == kIOReturnSuccess) {
                usleep(60000 << attempt);
                uint8_t reply[12] = {0};
                status = read(service, 0x37, alternate ? 0x51 : 0, reply, alternate ? 12 : 11);
                DiagAppend(@"    read → 0x%08x, reply[0..3]=%02x %02x %02x %02x",
                           status, reply[0], reply[1], reply[2], reply[3]);
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

// ──────────────────────────────────────────────────────────────────
// 综合 MonitorInput：依次尝试多种方法
// ──────────────────────────────────────────────────────────────────
static NSString *MonitorInput(uint8_t target, NSString **error) {
    if (target != 0) {
        // 核心优化：切换输入源纯属单向写入操作，直接使用无需等待 Read 的单向 DDC 写入通道
        DiagAppend(@"\n═══ 执行单向 DDC 切换写入 (target=0x%02X) ═══", target);
        NSString *writeResult = DDCWriteOnly(target, error);
        if (writeResult) {
            DiagAppend(@"单向 DDC 切换指令已成功发出！");
            return writeResult;
        }
        DiagAppend(@"单向 DDC 写入失败: %@", *error);
    }

    CreateAVService create = dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
    I2CTransfer write = dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
    I2CTransfer read = dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");
    if (!create || !write || !read) {
        *error = @"这个 macOS 版本没有可用的显示器控制接口。";
        return nil;
    }

    // ── 方法 1: 原始严格匹配 ──
    DiagAppend(@"\n═══ 方法 1: DCPAVServiceProxy (Location=External) ═══");
    NSString *err1 = nil;
    CFTypeRef service = OpenMonitor_DCPAVService(create, &err1);
    if (service) {
        DiagAppend(@"方法 1 找到通道，发送 DDC 命令...");
        NSString *result = DDCCommand(service, write, read, target, error);
        CFRelease(service);
        if (result) {
            DiagAppend(@"方法 1 成功: %@", result);
            return result;
        }
        DiagAppend(@"方法 1 DDC 命令失败: %@", *error ?: @"无应答");
    } else {
        DiagAppend(@"方法 1 失败: %@", err1);
    }

    // ── 方法 2: 宽松搜索所有 DCPAVServiceProxy ──
    DiagAppend(@"\n═══ 方法 2: DCPAVServiceProxy (所有非内建) ═══");
    NSString *err2 = nil;
    service = OpenMonitor_AllAVServices(create, &err2);
    if (service) {
        DiagAppend(@"方法 2 找到通道，发送 DDC 命令...");
        *error = nil; // 清除之前的错误
        NSString *result = DDCCommand(service, write, read, target, error);
        CFRelease(service);
        if (result) {
            DiagAppend(@"方法 2 成功: %@", result);
            return result;
        }
        DiagAppend(@"方法 2 DDC 命令失败: %@", *error ?: @"无应答");
    } else {
        DiagAppend(@"方法 2 失败: %@", err2);
    }

    // ── 方法 3: IOFramebuffer I2C 路径 ──
    DiagAppend(@"\n═══ 方法 3: IOFramebufferI2CInterface ═══");
    NSString *fbResult = nil;
    if (TryFramebufferI2C(target, &fbResult, error)) {
        DiagAppend(@"方法 3 成功: %@", fbResult);
        return fbResult;
    }

    // ── 全部失败 ──
    if (!*error) {
        *error = [NSString stringWithFormat:@"所有直连 DDC 方法均失败。\n方法1: %@\n方法2: %@",
                  err1 ?: @"DDC 命令无应答", err2 ?: @"DDC 命令无应答"];
    }
    return nil;
}

// ──────────────────────────────────────────────────────────────────
// IORegistry 全面扫描（纯诊断用）
// ──────────────────────────────────────────────────────────────────
static NSString *DiagnosticScan(void) {
    NSMutableString *report = [NSMutableString stringWithString:@"══════ ScreenSwitch 诊断报告 ══════\n\n"];

    // 1. 在线显示器列表
    [report appendString:@"─── 在线显示器 ───\n"];
    uint32_t count = 0;
    CGDirectDisplayID displays[16];
    if (CGGetOnlineDisplayList(16, displays, &count) == kCGErrorSuccess) {
        for (uint32_t i = 0; i < count; i++) {
            [report appendFormat:@"  #%u: ID=0x%x 内置=%d 厂商=0x%04x 型号=0x%04x 串口=0x%x 活跃=%d\n",
             i, displays[i], CGDisplayIsBuiltin(displays[i]),
             CGDisplayVendorNumber(displays[i]), CGDisplayModelNumber(displays[i]),
             CGDisplaySerialNumber(displays[i]), CGDisplayIsActive(displays[i])];
        }
    } else {
        [report appendString:@"  无法读取显示器列表\n"];
    }

    // 2. DCPAVServiceProxy
    [report appendString:@"\n─── DCPAVServiceProxy ───\n"];
    io_iterator_t iter = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == kIOReturnSuccess) {
        io_service_t entry;
        unsigned idx = 0;
        while ((entry = IOIteratorNext(iter))) {
            io_name_t name;
            IORegistryEntryGetName(entry, name);
            NSString *location = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR("Location"), NULL, 0));
            NSString *ioClass = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR("IOClass"), NULL, 0));
            io_string_t path;
            IORegistryEntryGetPath(entry, kIOServicePlane, path);
            [report appendFormat:@"  #%u: name=%s Location=%@ class=%@\n      path=%s\n",
             idx++, name, location ?: @"(nil)", ioClass ?: @"(nil)", path];
            IOObjectRelease(entry);
        }
        if (idx == 0) [report appendString:@"  (无)\n"];
        IOObjectRelease(iter);
    } else {
        [report appendString:@"  枚举失败\n"];
    }

    // 3. IODisplayConnect
    [report appendString:@"\n─── IODisplayConnect ───\n"];
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iter) == kIOReturnSuccess) {
        io_service_t entry;
        unsigned idx = 0;
        while ((entry = IOIteratorNext(iter))) {
            io_name_t name;
            IORegistryEntryGetName(entry, name);
            io_string_t path;
            IORegistryEntryGetPath(entry, kIOServicePlane, path);
            NSNumber *vendorID = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR("DisplayVendorID"), NULL, 0));
            NSNumber *productID = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR("DisplayProductID"), NULL, 0));
            [report appendFormat:@"  #%u: name=%s vendor=0x%x product=0x%x\n      path=%s\n",
             idx++, name, vendorID.unsignedIntValue, productID.unsignedIntValue, path];
            IOObjectRelease(entry);
        }
        if (idx == 0) [report appendString:@"  (无)\n"];
        IOObjectRelease(iter);
    }

    // 4. IOFramebufferI2CInterface
    [report appendString:@"\n─── IOFramebufferI2CInterface ───\n"];
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebufferI2CInterface"), &iter) == kIOReturnSuccess) {
        io_service_t entry;
        unsigned idx = 0;
        while ((entry = IOIteratorNext(iter))) {
            io_name_t name;
            IORegistryEntryGetName(entry, name);
            io_string_t path;
            IORegistryEntryGetPath(entry, kIOServicePlane, path);
            [report appendFormat:@"  #%u: name=%s\n      path=%s\n", idx++, name, path];
            IOObjectRelease(entry);
        }
        if (idx == 0) [report appendString:@"  (无)\n"];
        IOObjectRelease(iter);
    }

    // 5. AppleDCPAVServiceProxy（某些系统可能用不同类名）
    NSArray *extraClasses = @[@"IOAVService", @"AppleCLCD2", @"IOMobileFramebufferShim",
                               @"DCPAVService", @"AppleDCPAVServiceProxy"];
    for (NSString *cls in extraClasses) {
        [report appendFormat:@"\n─── %@ ───\n", cls];
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls.UTF8String), &iter) == kIOReturnSuccess) {
            io_service_t entry;
            unsigned idx = 0;
            while ((entry = IOIteratorNext(iter))) {
                io_name_t name;
                IORegistryEntryGetName(entry, name);
                NSString *location = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR("Location"), NULL, 0));
                [report appendFormat:@"  #%u: name=%s Location=%@\n", idx++, name, location ?: @"(nil)"];
                IOObjectRelease(entry);
            }
            if (idx == 0) [report appendString:@"  (无)\n"];
            IOObjectRelease(iter);
        } else {
            [report appendString:@"  枚举失败或不存在\n"];
        }
    }

    // 6. 尝试用 IOAVServiceCreateWithService 打开每个 DCPAVServiceProxy
    CreateAVService create = dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
    I2CTransfer writeI2C = dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
    I2CTransfer readI2C = dlsym(RTLD_DEFAULT, "IOAVServiceReadI2C");
    if (create && writeI2C && readI2C) {
        [report appendString:@"\n─── I²C 可达性测试 ───\n"];
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == kIOReturnSuccess) {
            io_service_t entry;
            unsigned idx = 0;
            while ((entry = IOIteratorNext(iter))) {
                NSString *location = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR("Location"), NULL, 0));
                CFTypeRef service = create(kCFAllocatorDefault, entry);
                [report appendFormat:@"  #%u (Location=%@): service=%p", idx, location ?: @"(nil)", service];
                if (service) {
                    // 尝试读取 DDC/CI capabilities (VCP 0x60 get)
                    uint8_t msg[] = {0x82, 0x01, InputSelect, 0};
                    msg[3] = Checksum(0x6e, msg, 3);
                    IOReturn wr = writeI2C(service, 0x37, 0x51, msg, sizeof(msg));
                    [report appendFormat:@" → I2C write=0x%08x", wr];
                    if (wr == kIOReturnSuccess) {
                        usleep(60000);
                        uint8_t reply[11] = {0};
                        IOReturn rd = readI2C(service, 0x37, 0, reply, 11);
                        [report appendFormat:@" read=0x%08x", rd];
                        if (rd == kIOReturnSuccess) {
                            [report appendFormat:@" data=%02x%02x%02x%02x%02x",
                             reply[0], reply[1], reply[2], reply[3], reply[4]];
                        }
                    }
                    [report appendString:@" ✓ 通道可用\n"];
                    CFRelease(service);
                } else {
                    [report appendString:@" ✗ 无法打开\n"];
                }
                idx++;
                IOObjectRelease(entry);
            }
            IOObjectRelease(iter);
        }
    }

    [report appendString:@"\n══════ 诊断完成 ══════"];
    return report;
}


// ══════════════════════════════════════════════════════════════════
// App 界面
// ══════════════════════════════════════════════════════════════════

@interface ScreenSwitch : NSObject <NSApplicationDelegate>
@property NSStatusItem *statusItem;
@property NSMenuItem *switchItem;
@property NSMenuItem *readItem;
@property NSMenuItem *pairItem;
@property NSMenuItem *relayItem;
@property NSMenuItem *fallbackItem;
@property NSMenuItem *testItem;
@property NSMenuItem *diagItem;
@property EventHotKeyRef hotKey;
@property EventHandlerRef eventHandler;
@property BOOL busy;
- (void)switchInput:(id)sender;
@end

static OSStatus HotKeyPressed(EventHandlerCallRef next, EventRef event, void *context) {
    EventHotKeyID key;
    OSStatus status = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                                         NULL, sizeof(key), NULL, &key);
    if (status != noErr || key.signature != 'ScSw' || key.id != 1) return eventNotHandledErr;
    [(__bridge ScreenSwitch *)context switchInput:nil];
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
    self.statusItem.button.toolTip = @"HKC MG24Q 输入源切换（含扩展坞直连测试）";
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    self.switchItem = [self item:@"切到 Windows（DP）" action:@selector(switchInput:) menu:menu];
    self.readItem = [self item:@"读取当前输入源" action:@selector(readInput:) menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    self.diagItem = [self item:@"🔍 诊断扩展坞 DDC 通道…" action:@selector(runDiagnostic:) menu:menu];
    [self item:@"🔧 强制直连 DDC 测试（忽略中转）" action:@selector(forceDirectTest:) menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    self.pairItem = [self item:@"配对 Windows 中转…" action:@selector(pairRelay:) menu:menu];
    self.relayItem = [self item:@"使用扩展坞模式" action:@selector(toggleRelay:) menu:menu];
    self.fallbackItem = [self item:@"自动回退（直连失败时用中转）" action:@selector(toggleFallback:) menu:menu];
    self.testItem = [self item:@"测试 Windows 中转连接" action:@selector(testRelay:) menu:menu];
    [menu addItem:NSMenuItem.separatorItem];
    [self item:@"退出" action:@selector(quit:) menu:menu];
    [self refreshMenu];
    self.statusItem.menu = menu;

    EventTypeSpec event = {kEventClassKeyboard, kEventHotKeyPressed};
    OSStatus status = InstallApplicationEventHandler(HotKeyPressed, 1, &event, (__bridge void *)self, &_eventHandler);
    if (status == noErr) {
        EventHotKeyID key = {'ScSw', 1};
        status = RegisterEventHotKey(kVK_ANSI_M, controlKey | optionKey | shiftKey,
                                     key, GetApplicationEventTarget(), 0, &_hotKey);
    }
    if (status == noErr) self.switchItem.title = @"切到 Windows（DP） · ⌃⌥⇧M";
    else [self showMessage:@"快捷键注册失败，可以继续用菜单切换。"];
}

- (void)showMessage:(NSString *)message {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"换屏";
    alert.informativeText = message;
    [NSApp activate];
    [alert runModal];
}

- (void)showScrollableMessage:(NSString *)title text:(NSString *)text {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 500, 400)];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    NSTextView *textView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 480, 400)];
    textView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    textView.editable = NO;
    textView.string = text;
    textView.minSize = NSMakeSize(480, 400);
    textView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    textView.textContainer.widthTracksTextView = YES;
    [textView.textContainer setContainerSize:NSMakeSize(480, FLT_MAX)];
    textView.verticallyResizable = YES;
    scroll.documentView = textView;
    alert.accessoryView = scroll;
    [alert addButtonWithTitle:@"复制并关闭"];
    [alert addButtonWithTitle:@"关闭"];
    [NSApp activate];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString];
    }
}

- (void)refreshMenu {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL paired = ValidRelayCode([defaults stringForKey:RelayCodeKey] ?: @"");
    self.relayItem.state = [defaults boolForKey:RelayEnabledKey] && paired ? NSControlStateValueOn : NSControlStateValueOff;
    self.fallbackItem.state = [defaults boolForKey:AutoFallbackKey] ? NSControlStateValueOn : NSControlStateValueOff;
    self.switchItem.enabled = !self.busy;
    self.readItem.enabled = !self.busy;
    self.pairItem.enabled = !self.busy;
    self.diagItem.enabled = !self.busy;
    self.relayItem.enabled = paired && !self.busy;
    self.fallbackItem.enabled = paired && !self.busy;
    self.testItem.enabled = paired && !self.busy;
}

- (void)pairRelay:(id)sender {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"配对 Windows 中转";
    alert.informativeText = @"从 Windows 托盘的「扩展坞模式」复制配对码，再粘贴到这里。";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 315, 24)];
    field.placeholderString = @"SS1:…";
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"配对并测试"];
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
        [self showMessage:@"配对码格式不正确，请从 Windows 重新复制整段配对码。"];
        return;
    }
    [self runInput:0 pairingCode:code];
}

- (void)toggleRelay:(id)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:![defaults boolForKey:RelayEnabledKey] forKey:RelayEnabledKey];
    [self refreshMenu];
}

- (void)toggleFallback:(id)sender {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:![defaults boolForKey:AutoFallbackKey] forKey:AutoFallbackKey];
    [self refreshMenu];
}

// ── 核心切换逻辑（含自动回退） ──
- (void)runInput:(uint8_t)target pairingCode:(NSString *)pairingCode {
    NSString *code = pairingCode;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL autoFallback = [defaults boolForKey:AutoFallbackKey];
    BOOL relayEnabled = [defaults boolForKey:RelayEnabledKey];

    if (!code && target && relayEnabled && !autoFallback)
        code = [defaults stringForKey:RelayCodeKey];

    if (!code && target && autoFallback) {
        // 自动回退模式：先直连，失败走中转
        [self runInputWithFallback:target];
        return;
    }

    [self runInput:target relayCode:code save:pairingCode != nil];
}

- (void)runInputWithFallback:(uint8_t)target {
    if (self.busy) return;
    self.busy = YES;
    [self refreshMenu];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        diagLog = [NSMutableString new];
        DiagAppend(@"═══ 自动回退模式：先尝试直连 DDC ═══");

        NSString *error = nil;
        NSString *result = MonitorInput(target, &error);
        diagLog = nil;

        if (result) {
            // 直连成功！
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                [self refreshMenu];
                [self showMessage:[NSString stringWithFormat:@"✅ 直连 DDC 成功！\n%@", result]];
            });
            return;
        }

        // 直连失败，尝试中转
        NSString *relayCode = [NSUserDefaults.standardUserDefaults stringForKey:RelayCodeKey];
        if (!ValidRelayCode(relayCode ?: @"")) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.busy = NO;
                [self refreshMenu];
                [self showMessage:[NSString stringWithFormat:
                    @"直连 DDC 失败，且未配对中转。\n\n直连错误: %@", error]];
            });
            return;
        }

        NSString *relayError = nil;
        NSString *relayResult = RelayRequest(relayCode, target != 0, &relayError);

        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            [self refreshMenu];
            if (relayResult) {
                // 什么都不提示，静默切换成功（通过中转）
                return;
            }
            [self showMessage:[NSString stringWithFormat:
                @"直连和中转均失败。\n\n直连: %@\n中转: %@", error, relayError]];
        });
    });
}

- (void)runInput:(uint8_t)target relayCode:(NSString *)code save:(BOOL)save {
    if (self.busy) return;
    self.busy = YES;
    [self refreshMenu];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        diagLog = [NSMutableString new];
        NSString *error = nil;
        NSString *result = code ? RelayRequest(code, target != 0, &error) : MonitorInput(target, &error);
        NSString *log = [diagLog copy];
        diagLog = nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            if (save && result) {
                [NSUserDefaults.standardUserDefaults setObject:code forKey:RelayCodeKey];
                [NSUserDefaults.standardUserDefaults setBool:YES forKey:RelayEnabledKey];
            }
            if (!target || error) {
                NSString *message = save && result ? @"Windows 中转在线，扩展坞模式已开启。现在可以试切到 Windows。" : result;
                NSString *display = error ?: message;
                if (log.length > 0 && !code) {
                    display = [NSString stringWithFormat:@"%@\n\n── DDC 日志 ──\n%@", display, log];
                }
                [self showMessage:display];
            }
            self.busy = NO;
            [self refreshMenu];
        });
    });
}

// ── 诊断扫描 ──
- (void)runDiagnostic:(id)sender {
    if (self.busy) return;
    self.busy = YES;
    [self refreshMenu];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *report = DiagnosticScan();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            [self refreshMenu];
            [self showScrollableMessage:@"扩展坞 DDC 通道诊断" text:report];
        });
    });
}

// ── 强制直连测试（无论是否开启中转，都只走 DDC） ──
- (void)forceDirectTest:(id)sender {
    if (self.busy) return;
    self.busy = YES;
    [self refreshMenu];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        diagLog = [NSMutableString new];
        DiagAppend(@"═══ 强制直连 DDC 测试（读取输入源） ═══");
        NSString *error = nil;
        NSString *result = MonitorInput(0, &error);
        NSString *log = [diagLog copy];
        diagLog = nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            [self refreshMenu];
            NSString *summary = result
                ? [NSString stringWithFormat:@"✅ 直连 DDC 成功!\n%@", result]
                : [NSString stringWithFormat:@"❌ 直连 DDC 失败\n%@", error];
            [self showScrollableMessage:@"直连 DDC 测试结果" text:
             [NSString stringWithFormat:@"%@\n\n── 详细日志 ──\n%@", summary, log]];
        });
    });
}

- (void)switchInput:(id)sender { [self runInput:WindowsInput pairingCode:nil]; }
- (void)readInput:(id)sender { [self runInput:0 pairingCode:nil]; }
- (void)testRelay:(id)sender {
    [self runInput:0 relayCode:[NSUserDefaults.standardUserDefaults stringForKey:RelayCodeKey] save:NO];
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
            diagLog = [NSMutableString new];
            NSString *error = nil;
            NSString *result = MonitorInput(0, &error);
            fprintf(result ? stdout : stderr, "%s\n", (result ?: error).UTF8String);
            if (diagLog.length > 0) fprintf(stderr, "\n%s\n", diagLog.UTF8String);
            return result ? 0 : 1;
        }
        if (argc == 2 && strcmp(argv[1], "--diag") == 0) {
            NSString *report = DiagnosticScan();
            printf("%s\n", report.UTF8String);
            return 0;
        }
        if (argc != 1) {
            fprintf(stderr, "用法: ScreenSwitch [--probe | --diag]\n");
            return 2;
        }

        NSApplication *application = NSApplication.sharedApplication;
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        ScreenSwitch *delegate = [ScreenSwitch new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
