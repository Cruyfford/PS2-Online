// PS2NetplayBridge.h — Swift ↔ the core's lockstep netplay (pcsx2/Netplay.h)
// SPDX-License-Identifier: GPL-3.0+

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PS2Netplay : NSObject

/// Before booting the game. host = player 1. guestCard = memory card file (inside the memory card folder)
/// the guest boots with; nil keeps the configured card.
+ (void)configureAsHost:(BOOL)host delay:(NSInteger)delay guestCard:(nullable NSString *)guestCard;
+ (void)stop;
+ (BOOL)isActive;
+ (BOOL)isWaiting;
+ (uint32_t)frame;

+ (void)requestSync:(NSString *)path;
+ (void)waitForPeer;
+ (void)provideState:(NSString *)path delay:(NSInteger)delay;
+ (void)pushRemoteInput:(uint32_t)frame data:(NSData *)data;

+ (nullable NSString *)hostCardPath;
/// zlib crc32 (for the disc fingerprint both players compare).
+ (uint32_t)crc32:(uint32_t)crc bytes:(const void *)bytes length:(NSUInteger)length;
+ (NSString *)memoryCardFolder;

/// Called on the emulator's CPU thread.
+ (void)setSendInput:(nullable void (^)(uint32_t frame, NSData *data))sendInput
           sendCheck:(nullable void (^)(uint32_t frame, uint32_t crc))sendCheck
          stateSaved:(nullable void (^)(NSString *path, BOOL ok))stateSaved
         stateLoaded:(nullable void (^)(BOOL ok))stateLoaded;

@end

NS_ASSUME_NONNULL_END
