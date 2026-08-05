const std = @import("std");

const rapidSeed: u64 = 0xf4d8ef1732c4ed6e;

const rapidSecret0: u64 = 0x2d358dccaa6c78a5;
const rapidSecret1: u64 = 0x8bb84b93962eacc9;
const rapidSecret2: u64 = 0x4b33a62ed433d4a3;

inline fn rapidMix(a: u64, b: u64) u64 {
    const prod = @as(u128, a) * @as(u128, b);
    const hi: u64 = @truncate(prod >> 64);
    const lo: u64 = @truncate(prod);
    return hi ^ lo;
}

inline fn read64(s: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, s[offset..][0..8], .native);
}

inline fn read32(s: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, s[offset..][0..4], .native);
}

inline fn read8(s: []const u8, offset: usize) u8 {
    return s[offset];
}

pub fn hashString(s: []const u8) u64 {
    const l = s.len;
    var seed = rapidSeed;

    seed ^= rapidMix(seed ^ rapidSecret0, rapidSecret1) ^ l;

    if (l == 0) {
        return rapidMix(seed, rapidSecret2);
    }

    var a: u64 = 0;
    var b: u64 = 0;

    // 16 byte or smaller strings
    if (l <= 16) {
        // split strings in left and right then mix
        if (l >= 8) {
            a = read64(s, 0);
            b = read64(s, l - 8);
        } else if (l >= 4) {
            a = @as(u64, read32(s, 0));
            b = @as(u64, read32(s, l - 4));
        } else {
            a = @as(u64, read8(s, 0)) << 16;
            a |= @as(u64, read8(s, l >> 1)) << 8;
            a |= @as(u64, read8(s, l - 1));
        }
        return rapidMix(seed ^ a, rapidSecret2 ^ b);
    }

    var i: usize = 0;
    if (l > 96) {
        // reads 96 bytes at a time and splits into 6 chunks continously and mixes n with n+3 to 3 results, then xor those.
        var see1 = seed;
        var see2 = seed;
        while (i + 96 <= l) : (i += 96) {
            seed = rapidMix(read64(s, i) ^ rapidSecret0, read64(s, i + 8) ^ seed);
            see1 = rapidMix(read64(s, i + 16) ^ rapidSecret1, read64(s, i + 24) ^ see1);
            see2 = rapidMix(read64(s, i + 32) ^ rapidSecret2, read64(s, i + 40) ^ see2);
            seed = rapidMix(read64(s, i + 48) ^ rapidSecret0, read64(s, i + 56) ^ seed);
            see1 = rapidMix(read64(s, i + 64) ^ rapidSecret1, read64(s, i + 72) ^ see1);
            see2 = rapidMix(read64(s, i + 80) ^ rapidSecret2, read64(s, i + 88) ^ see2);
        }
        seed ^= see1 ^ see2;
    }

    while (i + 16 <= l) : (i += 16) {
        // consume 16 bytes at a time, first 8 bytes mixed with next 8
        seed = rapidMix(read64(s, i) ^ rapidSecret2, read64(s, i + 8) ^ seed ^ rapidSecret1);
    }

    a = read64(s, l - 16);
    b = read64(s, l - 8);

    return rapidMix(seed ^ a, rapidSecret2 ^ b);
}
