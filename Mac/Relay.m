#import "Relay.h"
#import <CommonCrypto/CommonHMAC.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static const uint16_t RelayPort = 43862;
static const size_t TagLength = 32;
static NSString *lastDiscoveredCode = nil;

NSString *RelayGetUpdatedCode(void) {
    NSString *res = lastDiscoveredCode;
    lastDiscoveredCode = nil;
    return res;
}

static NSData *ParseCode(NSString *code, struct sockaddr_in *address) {
    NSArray<NSString *> *parts = [code componentsSeparatedByString:@":"];
    if (parts.count != 3 || ![parts[0] isEqualToString:@"SS1"]) return nil;

    *address = (struct sockaddr_in){.sin_len = sizeof(*address), .sin_family = AF_INET,
                                    .sin_port = htons(RelayPort)};
    if (inet_pton(AF_INET, parts[1].UTF8String, &address->sin_addr) != 1) return nil;
    uint32_t ip = ntohl(address->sin_addr.s_addr);
    if ((ip >> 24) != 10 && (ip >> 20) != 0xac1 && (ip >> 16) != 0xc0a8) return nil;

    NSData *key = [[NSData alloc] initWithBase64EncodedString:parts[2] options:0];
    return key.length == TagLength ? key : nil;
}

BOOL ValidRelayCode(NSString *code) {
    struct sockaddr_in address;
    return ParseCode(code, &address) != nil;
}

static double MonotonicTime(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}

static BOOL WaitForSocket(int socketFD, short events, double deadline) {
    struct pollfd descriptor = {.fd = socketFD, .events = events};
    for (;;) {
        double remaining = deadline - MonotonicTime();
        if (remaining <= 0) return NO;
        int ready = poll(&descriptor, 1, (int)(remaining * 1000) + 1);
        if (ready >= 0) return ready > 0 && (descriptor.revents & events);
        if (errno != EINTR) return NO;
    }
}

static BOOL Transfer(int socketFD, uint8_t *bytes, size_t length, BOOL sending, double deadline) {
    size_t offset = 0;
    while (offset < length && WaitForSocket(socketFD, sending ? POLLOUT : POLLIN, deadline)) {
        ssize_t count = sending ? send(socketFD, bytes + offset, length - offset, 0)
                                : recv(socketFD, bytes + offset, length - offset, 0);
        if (count == 0) break;
        if (count < 0) {
            if (errno == EAGAIN || errno == EINTR) continue;
            break;
        }
        offset += (size_t)count;
    }
    return offset == length;
}

static BOOL Exchange(int socketFD, const struct sockaddr_in *address, NSData *key,
                     uint8_t command, uint8_t *status, NSString **error) {
    int on = 1;
    if (fcntl(socketFD, F_SETFL, O_NONBLOCK) != 0 ||
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on)) != 0) {
        *error = @"无法配置局域网连接。";
        return NO;
    }

    int connected = connect(socketFD, (const struct sockaddr *)address, sizeof(*address));
    if (connected != 0) {
        int socketError = 0;
        socklen_t size = sizeof(socketError);
        if (errno != EINPROGRESS || !WaitForSocket(socketFD, POLLOUT, MonotonicTime() + 2) ||
            getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &socketError, &size) != 0 || socketError) {
            *error = @"连不上 Windows。请确认两台电脑在同一局域网、Windows 已唤醒且中转已开启，并检查局域网和防火墙权限。";
            return NO;
        }
    }

    uint8_t challenge[34] = {0};
    uint8_t request[33] = {command};
    uint8_t reply[33];
    double deadline = MonotonicTime() + 4;
    if (!Transfer(socketFD, challenge, 32, NO, deadline)) {
        *error = @"已连接 Windows，但没收到中转握手。";
        return NO;
    }
    challenge[32] = command;
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, challenge, 33, request + 1);
    if (!Transfer(socketFD, request, sizeof(request), YES, deadline) ||
        !Transfer(socketFD, reply, sizeof(reply), NO, deadline)) {
        *error = @"Windows 未完成请求。请检查配对码是否最新，或稍后重试。";
        return NO;
    }

    challenge[33] = reply[0];
    uint8_t expected[32];
    CCHmac(kCCHmacAlgSHA256, key.bytes, key.length, challenge, 34, expected);
    volatile uint8_t difference = 0;
    for (size_t i = 0; i < TagLength; i++) difference |= expected[i] ^ reply[i + 1];
    if (difference) {
        *error = @"Windows 的应答认证失败，请重新配对。";
        return NO;
    }
    *status = reply[0];
    return YES;
}

// 快速子网发现自愈：如果 Windows 的 IP 变了，自动扫描同子网寻找匹配该 key 的设备
static BOOL AutoDiscoverWindows(const struct sockaddr_in *origAddr, NSData *key,
                                uint8_t command, uint8_t *status, NSString **newCode) {
    uint32_t ip = ntohl(origAddr->sin_addr.s_addr);
    uint32_t subnet = ip & 0xFFFFFF00; // 假设 /24 子网
    uint32_t origHost = ip & 0xFF;

    for (uint32_t host = 1; host < 255; host++) {
        if (host == origHost) continue; // 原 IP 刚试过失败了，跳过
        struct sockaddr_in testAddr = {
            .sin_len = sizeof(testAddr),
            .sin_family = AF_INET,
            .sin_port = htons(RelayPort),
            .sin_addr = {.s_addr = htonl(subnet | host)}
        };

        int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (fd < 0) continue;

        NSString *dummyErr = nil;
        if (Exchange(fd, &testAddr, key, command, status, &dummyErr)) {
            close(fd);
            char ipStr[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &testAddr.sin_addr, ipStr, sizeof(ipStr));
            NSString *b64Key = [key base64EncodedStringWithOptions:0];
            *newCode = [NSString stringWithFormat:@"SS1:%s:%@", ipStr, b64Key];
            return YES;
        }
        close(fd);
    }
    return NO;
}

NSString *RelayRequestCommand(NSString *code, uint8_t command, NSString **error) {
    struct sockaddr_in address;
    NSData *key = ParseCode(code, &address);
    if (!key) {
        *error = @"请先填入 Windows 托盘里复制的配对码。";
        return nil;
    }

    int socketFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socketFD < 0) {
        *error = @"无法创建局域网连接。";
        return nil;
    }

    uint8_t status = 0;
    BOOL received = Exchange(socketFD, &address, key, command, &status, error);
    close(socketFD);

    // 如果首选 IP 连接失败，自动在同网段自愈寻找 Windows 的新 IP
    if (!received) {
        NSString *newCode = nil;
        uint8_t fallbackStatus = 0;
        if (AutoDiscoverWindows(&address, key, command, &fallbackStatus, &newCode)) {
            lastDiscoveredCode = newCode;
            status = fallbackStatus;
            received = YES;
            *error = nil;
        }
    }

    if (!received) return nil;

    switch (status) {
        case 0:
            if (command == 0) return @"配对成功，Windows 中转在线。";
            if (command == 1) return @"Windows 已发出切到 DP 的指令。";
            if (command == 2) return @"Windows 已发出切到 Mac (HDMI 2) 的指令。";
            return @"已切换输入源。";
        case 1: *error = @"Windows 当前识别不到 HKC MG24Q。显示器可能在断开 DP。"; break;
        case 2: *error = @"Windows 找到了显示器，但切换指令失败。请检查显示器 DDC/CI 设置。"; break;
        case 3: *error = @"配对码不匹配，请从 Windows 重新复制。"; break;
        default: *error = @"Windows 中转返回了未知结果。";
    }
    return nil;
}

NSString *RelayRequest(NSString *code, BOOL switchInput, NSString **error) {
    return RelayRequestCommand(code, switchInput ? 1 : 0, error);
}
