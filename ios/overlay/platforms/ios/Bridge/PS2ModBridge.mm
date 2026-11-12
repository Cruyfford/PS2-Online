// PS2ModBridge.mm
// SPDX-License-Identifier: GPL-3.0+

#import "PS2ModBridge.h"

#include "PS2Mod.h"

@interface PS2ModResult ()
@property (nonatomic, readwrite) uint32_t address;
@property (nonatomic, readwrite) uint32_t value;
@property (nonatomic, readwrite) uint32_t previous;
@end
@implementation PS2ModResult
@end

@interface PS2ModFrozen ()
@property (nonatomic, readwrite) uint32_t address;
@property (nonatomic, readwrite) NSInteger width;
@property (nonatomic, readwrite) uint32_t value;
@end
@implementation PS2ModFrozen
@end

@implementation PS2ModTools

+ (BOOL)isAvailable { return PS2Mod::Available(); }
+ (uint32_t)ramSize { return PS2Mod::RamSize(); }

+ (NSData *)read:(uint32_t)address length:(uint32_t)length {
    NSMutableData *d = [NSMutableData dataWithLength:length];
    const uint32_t n = PS2Mod::Read(address, (uint8_t *)d.mutableBytes, length);
    d.length = n;
    return d;
}

+ (void)write:(uint32_t)address width:(NSInteger)width value:(uint32_t)value { PS2Mod::Write(address, (int)width, value); }
+ (void)freeze:(uint32_t)address width:(NSInteger)width value:(uint32_t)value { PS2Mod::Freeze(address, (int)width, value); }
+ (void)unfreeze:(uint32_t)address { PS2Mod::Unfreeze(address); }
+ (void)unfreezeAll { PS2Mod::UnfreezeAll(); }

+ (NSArray<PS2ModFrozen *> *)frozen {
    NSMutableArray *out = [NSMutableArray array];
    for (const auto &f : PS2Mod::FrozenList()) {
        PS2ModFrozen *o = [PS2ModFrozen new];
        o.address = f.addr;
        o.width = f.width;
        o.value = f.value;
        [out addObject:o];
    }
    return out;
}

+ (void)searchBeginWidth:(NSInteger)width aligned:(BOOL)aligned { PS2Mod::SearchBegin((int)width, aligned); }
+ (uint32_t)searchFilter:(NSInteger)op value:(uint32_t)value { return PS2Mod::SearchFilter((int)op, value); }
+ (uint32_t)searchCount { return PS2Mod::SearchCount(); }
+ (void)searchReset { PS2Mod::SearchReset(); }

+ (NSArray<PS2ModResult *> *)searchResults:(uint32_t)max {
    NSMutableArray *out = [NSMutableArray array];
    for (const auto &r : PS2Mod::SearchResults(max)) {
        PS2ModResult *o = [PS2ModResult new];
        o.address = r.addr;
        o.value = r.value;
        o.previous = r.previous;
        [out addObject:o];
    }
    return out;
}

+ (NSString *)dumpToDirectory:(NSString *)directory {
    const std::string p = PS2Mod::Dump(directory.UTF8String);
    return p.empty() ? nil : [NSString stringWithUTF8String:p.c_str()];
}

+ (NSArray<NSString *> *)disassemble:(uint32_t)address count:(uint32_t)count {
    NSMutableArray *out = [NSMutableArray array];
    for (const auto &s : PS2Mod::Disassemble(address, count))
        [out addObject:[NSString stringWithUTF8String:s.c_str()] ?: @"?"];
    return out;
}

+ (NSString *)serial { return [NSString stringWithUTF8String:PS2Mod::Serial().c_str()]; }

@end
