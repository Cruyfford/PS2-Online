// PS2ModBridge.h — Swift ↔ the game-modding tools (pcsx2/PS2Mod.h)
// SPDX-License-Identifier: GPL-3.0+

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PS2ModResult : NSObject
@property (nonatomic, readonly) uint32_t address;
@property (nonatomic, readonly) uint32_t value;
@property (nonatomic, readonly) uint32_t previous;
@end

@interface PS2ModFrozen : NSObject
@property (nonatomic, readonly) uint32_t address;
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) uint32_t value;
@end

@interface PS2ModTools : NSObject

+ (BOOL)isAvailable;
+ (uint32_t)ramSize;
+ (NSData *)read:(uint32_t)address length:(uint32_t)length;

/// width: 1, 2, 4, or 0x14 (float)
+ (void)write:(uint32_t)address width:(NSInteger)width value:(uint32_t)value;
+ (void)freeze:(uint32_t)address width:(NSInteger)width value:(uint32_t)value;
+ (void)unfreeze:(uint32_t)address;
+ (void)unfreezeAll;
+ (NSArray<PS2ModFrozen *> *)frozen;

+ (void)searchBeginWidth:(NSInteger)width aligned:(BOOL)aligned;
+ (uint32_t)searchFilter:(NSInteger)op value:(uint32_t)value;
+ (uint32_t)searchCount;
+ (NSArray<PS2ModResult *> *)searchResults:(uint32_t)max;
+ (void)searchReset;

+ (nullable NSString *)dumpToDirectory:(NSString *)directory;
+ (NSArray<NSString *> *)disassemble:(uint32_t)address count:(uint32_t)count;
+ (NSString *)serial;

@end

NS_ASSUME_NONNULL_END
