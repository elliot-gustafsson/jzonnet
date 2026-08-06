const std = @import("std");

pub const ValueType = enum(u8) {
    None,
    Null,
    String,
    StringConst,
    Number,
    Bool,
    Object,
    Array,
    Function,
    NativeFunction,
    Thunk,
};

pub const ValueNone: Value = Value(0);

// Value represents a NaN-boxed 64-bit value.
// Bit layout for non-float types:

// 63                   51 50    47 46                               0
// |----------------------|--------|---------------------------------|
// |  Float NaN Boundary  |  Type  |             Payload             |
// |       (13 bits)      |(4 bits)|            (47 bits)            |
// |----------------------|--------|---------------------------------|

// - Bits 63-51: Reserved for IEEE-754 Quiet NaN float64 detection.
// - Bits 50-47: ValueType enum.
// - Bits 46-0 : Payload (pointer info, interned string id, 1/0 for bools)
// Note: lowest bits can be used for flags depending on the alignment
pub const Value = struct {
    bits: u64,

    const ptr_mask: u64 = 0x0000_FFFF_FFFF_FFFF;
    const nan_tag: u64 = 0xFFF8_0000_0000_0000;
    const tag_mask: u64 = 0xFFFF_8000_0000_0000;
    const float_threshold = 1 << 51;
    const canonical_nan_bits = 0x7FF8_0000_0000_0000;
    const type_shift = 47;

    fn box(t: ValueType, data: u32) Value {
        const tag = @as(u64, @intFromEnum(t)) << type_shift;

        return .{ .bits = tag | data };
    }

    fn boxPtr(t: ValueType, ptr: anytype) Value {
        std.debug.assert(t != .Number); // Number must use makeNumber!

        const addr = @intFromPtr(ptr);
        std.debug.assert((addr & ~ptr_mask) == 0); // Ensure it's a valid 48-bit user ptr

        const tag = @as(u64, @intFromEnum(t)) << type_shift;

        return .{ .bits = tag | (addr & ptr_mask) };
    }

    pub fn makeNull() Value {
        return box(.Null, 0);
    }

    pub fn makeString(a: std.mem.Allocator, v: []const u8) Value {
        const ptr = a.alloc(u8, v.len) catch unreachable;
        @memcpy(ptr, v);

        // TODO: gör som go o spara len först som int, sen datan

        return boxPtr(.String, ptr.ptr);
    }

    pub fn makeArray(a: std.mem.Allocator, v: []const Value) !Value {
        const s = a.alloc(Value, v.len) catch unreachable;
        @memcpy(s, v);

        return boxPtr(.Array, s.ptr);
    }

    pub fn makeStringConst(id: u32) Value {
        return box(.StringConst, id);
    }

    pub fn makeNumber(v: f64) Value {
        var bits: u64 = @bitCast(v);
        if (std.math.isNan(v)) {
            bits = canonical_nan_bits;
        }
        return .{ .bits = bits ^ nan_tag };
    }

    pub fn makeBool(v: bool) Value {
        if (v) {
            return box(.Bool, 1);
        }
        return box(.Bool, 0);
    }

    pub fn typeOf(self: Value) ValueType {
        const t = self.bits >> type_shift;
        if (t >= (float_threshold >> type_shift)) {
            return .Number;
        }
        return @enumFromInt(@as(u8, @truncate(t)));
    }

    pub fn number(self: Value) f64 {
        std.debug.assert(self.typeOf() == .Number);
        return @bitCast(self.bits ^ nan_tag);
    }

    pub fn boolean(self: Value) bool {
        std.debug.assert(self.typeOf() == .Bool);
        return @as(u1, @trunc(self.bits)) == 1;
    }

    pub fn isNumber(self: Value) bool {
        return self.bits >= float_threshold;
    }
};

// --- Tests validating the layout ---

test "Value system validation" {
    // 1. Zero memory is exactly 'None'
    const val_empty = Value{ .bits = 0 };
    try std.testing.expectEqual(ValueType.None, val_empty.typeOf());

    // 2. Numbers are decoded correctly and do not collide with 0
    const val_zero_float = Value.makeNumber(0.0);
    try std.testing.expectEqual(ValueType.Number, val_zero_float.typeOf());
    try std.testing.expect(val_zero_float.bits != 0);
    try std.testing.expectEqual(@as(f64, 0.0), val_zero_float.number());

    // 3. Negative numbers work
    const val_neg = Value.makeNumber(-42.5);
    try std.testing.expectEqual(ValueType.Number, val_neg.typeOf());
    try std.testing.expectEqual(@as(f64, -42.5), val_neg.number());

    // 4. Pointers / Arena Indices are preserved
    const val_obj = Value.box(.Object, 4096);
    try std.testing.expectEqual(ValueType.Object, val_obj.typeOf());

    // val_obj.
}
