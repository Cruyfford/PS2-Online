// PS2NetplayBridge.mm
// SPDX-License-Identifier: GPL-3.0+

#import "PS2NetplayBridge.h"

#include "Netplay.h"

#include <zlib.h>

static void (^s_sendInput)(uint32_t, NSData *) = nil;
static void (^s_sendCheck)(uint32_t, uint32_t) = nil;
static void (^s_stateSaved)(NSString *, BOOL) = nil;
static void (^s_stateLoaded)(BOOL) = nil;

static void np_send_input(void *, uint32_t frame, const uint8_t *data)
{
    @autoreleasepool {
        auto cb = s_sendInput;
        if (cb) cb(frame, [NSData dataWithBytes:data length:Netplay::INPUT_SIZE]);
    }
}

static void np_send_check(void *, uint32_t frame, uint32_t crc)
{
    auto cb = s_sendCheck;
    if (cb) cb(frame, crc);
}

static void np_state_saved(void *, const char *path, int ok)
{
    @autoreleasepool {
        auto cb = s_stateSaved;
        if (cb) cb([NSString stringWithUTF8String:path ? path : ""], ok != 0);
    }
}

static void np_state_loaded(void *, int ok)
{
    auto cb = s_stateLoaded;
    if (cb) cb(ok != 0);
}

@implementation PS2Netplay

+ (void)configureAsHost:(BOOL)host delay:(NSInteger)delay guestCard:(NSString *)guestCard {
    Netplay::Callbacks cb;
    cb.send_input = np_send_input;
    cb.send_check = np_send_check;
    cb.state_saved = np_state_saved;
    cb.state_loaded = np_state_loaded;
    Netplay::Configure(host, (int)delay, cb, guestCard ? guestCard.UTF8String : nullptr);
}

+ (void)stop { Netplay::Stop(); }
+ (BOOL)isActive { return Netplay::IsActive(); }
+ (BOOL)isWaiting { return Netplay::IsWaiting(); }
+ (uint32_t)frame { return Netplay::Frame(); }

+ (void)requestSync:(NSString *)path { Netplay::RequestSync(path.UTF8String); }
+ (void)waitForPeer { Netplay::WaitForPeer(); }
+ (void)provideState:(NSString *)path delay:(NSInteger)delay { Netplay::ProvideState(path.UTF8String, (int)delay); }

+ (void)pushRemoteInput:(uint32_t)frame data:(NSData *)data {
    if (data.length < (NSUInteger)Netplay::INPUT_SIZE) return;
    Netplay::PushRemoteInput(frame, (const uint8_t *)data.bytes);
}

+ (NSString *)hostCardPath {
    const std::string p = Netplay::HostCardPath();
    return p.empty() ? nil : [NSString stringWithUTF8String:p.c_str()];
}

+ (uint32_t)crc32:(uint32_t)crc bytes:(const void *)bytes length:(NSUInteger)length {
    return (uint32_t)::crc32((uLong)crc, (const Bytef *)bytes, (uInt)length);
}

+ (NSString *)memoryCardFolder {
    return [NSString stringWithUTF8String:Netplay::MemoryCardFolder().c_str()];
}

+ (void)setSendInput:(void (^)(uint32_t, NSData *))sendInput
           sendCheck:(void (^)(uint32_t, uint32_t))sendCheck
          stateSaved:(void (^)(NSString *, BOOL))stateSaved
         stateLoaded:(void (^)(BOOL))stateLoaded {
    s_sendInput = [sendInput copy];
    s_sendCheck = [sendCheck copy];
    s_stateSaved = [stateSaved copy];
    s_stateLoaded = [stateLoaded copy];
}

@end
