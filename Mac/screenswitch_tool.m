#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <unistd.h>

typedef CFTypeRef (*CreateAVService)(CFAllocatorRef, io_service_t);
typedef IOReturn (*I2CTransfer)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);

static const uint8_t InputSelect = 0x60;
static const uint8_t WindowsDP = 0x0f; // DP
static const uint8_t MacHDMI2 = 0x12;  // HDMI 2

static uint8_t Checksum(uint8_t seed, const uint8_t *bytes, size_t count) {
    for (size_t i = 0; i < count; i++) seed ^= bytes[i];
    return seed;
}

static CFTypeRef GetExternalAVService(void) {
    CreateAVService create = dlsym(RTLD_DEFAULT, "IOAVServiceCreateWithService");
    if (!create) return NULL;

    io_iterator_t services = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &services) != kIOReturnSuccess) {
        return NULL;
    }

    CFTypeRef targetService = NULL;
    io_service_t entry;
    while ((entry = IOIteratorNext(services))) {
        NSString *location = CFBridgingRelease(IORegistryEntryCreateCFProperty(entry, CFSTR("Location"), NULL, 0));
        if ([location isEqualToString:@"External"]) {
            targetService = create(kCFAllocatorDefault, entry);
            IOObjectRelease(entry);
            break;
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(services);
    return targetService;
}

static BOOL SendVCP(CFTypeRef service, uint8_t vcp, uint8_t val) {
    I2CTransfer writeI2C = dlsym(RTLD_DEFAULT, "IOAVServiceWriteI2C");
    if (!writeI2C || !service) return NO;

    uint8_t msg[] = {0x84, 0x03, vcp, 0x00, val, 0};
    msg[5] = Checksum(0x6e ^ 0x51, msg, 5);
    
    IOReturn kr1 = writeI2C(service, 0x37, 0x51, msg, sizeof(msg));
    usleep(30000);
    IOReturn kr2 = writeI2C(service, 0x37, 0x51, msg, sizeof(msg));

    printf("  [DDC Set 0x%02X -> 0x%02X] write 返回: 0x%08X, 重发: 0x%08X\n", vcp, val, kr1, kr2);
    return kr1 == kIOReturnSuccess || kr2 == kIOReturnSuccess;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            printf("用法:\n");
            printf("  %s brightness <0-100>  : 调节亮度（安全测试）\n", argv[0]);
            printf("  %s test-pulse          : 亮度闪烁测试（调暗1秒后恢复）\n", argv[0]);
            printf("  %s switch-to-windows   : 直接通过 DDC 发送切到 Windows (DP 0x0F)\n", argv[0]);
            printf("  %s switch-to-mac       : 直接通过 DDC 发送切到 Mac (HDMI2 0x12)\n", argv[0]);
            return 1;
        }

        CFTypeRef service = GetExternalAVService();
        if (!service) {
            fprintf(stderr, "错误: 未找到外接显示器的 DCPAVServiceProxy\n");
            return 1;
        }

        NSString *cmd = [NSString stringWithUTF8String:argv[1]];
        if ([cmd isEqualToString:@"brightness"] && argc >= 3) {
            int b = atoi(argv[2]);
            if (b < 0) b = 0; if (b > 100) b = 100;
            printf("正在向外接显示器设置亮度: %d%%\n", b);
            SendVCP(service, 0x10, (uint8_t)b);
        } else if ([cmd isEqualToString:@"test-pulse"]) {
            printf("开始亮度闪烁测试...\n");
            printf("步骤1: 调到 10%% 亮度\n");
            SendVCP(service, 0x10, 10);
            printf("等待 1.5 秒...\n");
            sleep(1);
            usleep(500000);
            printf("步骤2: 恢复到 70%% 亮度\n");
            SendVCP(service, 0x10, 70);
            printf("测试完成。请观察显示器亮度刚刚是否有明显变暗后恢复？\n");
        } else if ([cmd isEqualToString:@"switch-to-windows"]) {
            printf("正在直接向显示器发送切换指令: 切到 Windows (DP 0x%02X)...\n", WindowsDP);
            BOOL ok = SendVCP(service, InputSelect, WindowsDP);
            if (ok) {
                printf("✅ 切换指令已成功发出！\n");
            } else {
                printf("❌ 指令写入失败。\n");
            }
        } else if ([cmd isEqualToString:@"switch-to-mac"]) {
            printf("正在直接向显示器发送切换指令: 切到 Mac (HDMI 2 0x%02X)...\n", MacHDMI2);
            BOOL ok = SendVCP(service, InputSelect, MacHDMI2);
            if (ok) {
                printf("✅ 切换指令已成功发出！\n");
            } else {
                printf("❌ 指令写入失败。\n");
            }
        } else {
            fprintf(stderr, "未知命令: %s\n", argv[1]);
        }

        CFRelease(service);
        return 0;
    }
}
