const std = @import("std");

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

    pub const Type = enum(u8) {
        None,
        Null,
        String,
        Number,
        Bool,
        Object,
        Array,
        Function,
        NativeFunction,
        Thunk,

        pub fn string(self: Type) []const u8 {
            return switch (self) {
                .None => "none",
                .String => "string",
                .Null => "null",
                .Number => "number",
                .Bool => "boolean",
                .Object => "object",
                .Array => "array",
                .Function, .NativeFunction => "function",
                .Thunk => "thunk",
            };
        }
    };

    pub const None: Value = .{ .bits = 0 };
    pub const Null: Value = box(Type.Null, 0);
    pub const False: Value = box(Type.Bool, 0);
    pub const True: Value = box(Type.Bool, 1);

    fn box(t: Type, data: u32) Value {
        const tag = @as(u64, @intFromEnum(t)) << type_shift;

        return .{ .bits = tag | data };
    }

    fn boxPtr(t: Type, ptr: anytype) Value {
        std.debug.assert(t != .Number); // Number must use makeNumber!

        const addr = @intFromPtr(ptr);
        std.debug.assert((addr & ~ptr_mask) == 0); // Ensure it's a valid 48-bit user ptr

        const tag = @as(u64, @intFromEnum(t)) << type_shift;

        return .{ .bits = tag | (addr & ptr_mask) };
    }

    // pub fn makeNull() Value {
    //     return box(.Null, 0);
    // }

    pub fn makeString(a: std.mem.Allocator, v: []const u8) Value {
        const n = v.len;
        const int_size = @sizeOf(usize);
        const total_size = int_size + n;

        const mem = a.alignedAlloc(u8, .fromByteUnits(@alignOf(usize)), total_size) catch unreachable;

        // write len at beginning of block
        @as(*usize, @ptrCast(@alignCast(mem.ptr))).* = v.len;
        // copy string data to block
        @memcpy(mem[int_size..], v);

        return boxPtr(.String, mem.ptr);
    }

    pub fn makeStringConcat(a: std.mem.Allocator, v1: []const u8, v2: []const u8) Value {
        const n = v1.len + v2.len;
        const int_size = @sizeOf(usize);
        const total_size = int_size + n;

        const mem = a.alignedAlloc(u8, .fromByteUnits(@alignOf(usize)), total_size) catch unreachable;

        // write len at beginning of block
        @as(*usize, @ptrCast(@alignCast(mem.ptr))).* = n;
        // copy string data to block
        @memcpy(mem[int_size .. int_size + v1.len], v1);
        @memcpy(mem[int_size + v1.len ..], v2);

        return boxPtr(.String, mem.ptr);
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

    pub const ArrayResult = struct {
        slice: []Value,
        value: Value,
    };

    pub fn makeArraySized(a: std.mem.Allocator, n: usize) ArrayResult {
        const header_size = @sizeOf(usize);
        const total_size = header_size + (n * @sizeOf(Value));

        // Allocate single block aligned for usize and Value (both 8-byte aligned)
        const mem = a.alignedAlloc(u8, .fromByteUnits(@max(@alignOf(usize), @alignOf(Value))), total_size) catch unreachable;

        // write len at beginning of block
        @as(*usize, @ptrCast(@alignCast(mem.ptr))).* = n;

        // get pointer to beginning of reserver space for data
        const elem_ptr: [*]Value = @ptrCast(@alignCast(mem.ptr + header_size));

        return .{ .slice = elem_ptr[0..n], .value = boxPtr(.Array, mem.ptr) };
    }

    pub fn makeArray(a: std.mem.Allocator, v: []const Value) Value {
        const res = makeArraySized(a, v.len);
        @memcpy(res.slice, v);
        return res.value;
    }

    pub fn typeOf(self: Value) Type {
        const t = self.bits >> type_shift;
        if (t >= (float_threshold >> type_shift)) {
            return .Number;
        }
        return @enumFromInt(@as(u8, @truncate(t)));
    }

    pub fn string(self: Value) []const u8 {
        std.debug.assert(self.typeOf() == .String);
        const addr: usize = @intCast(self.bits & ((1 << type_shift) - 1));
        const ptr: [*]align(@alignOf(usize)) const u8 = @ptrFromInt(addr);
        const len = @as(*const usize, @ptrCast(ptr)).*;
        return (ptr + @sizeOf(usize))[0..len];
    }

    pub fn number(self: Value) f64 {
        std.debug.assert(self.typeOf() == .Number);
        return @bitCast(self.bits ^ nan_tag);
    }

    pub fn boolean(self: Value) bool {
        std.debug.assert(self.typeOf() == .Bool);
        return @as(u1, @trunc(self.bits)) == 1;
    }

    pub fn array(self: Value) []Value {
        std.debug.assert(self.typeOf() == .Array);
        const addr: usize = @intCast(self.bits & ((1 << type_shift) - 1));
        const ptr: [*]align(@alignOf(usize)) u8 = @ptrFromInt(addr);
        const len = @as(*const usize, @ptrCast(ptr)).*;
        const elem_ptr: [*]Value = @ptrCast(@alignCast(ptr + @sizeOf(usize)));
        return elem_ptr[0..len];
    }

    pub fn isNumber(self: Value) bool {
        return self.bits >= float_threshold;
    }
};

pub const NamedValue = struct {
    key: u32,
    val: Value,
};

// --- Tests validating the layout ---

test "Value system validation" {
    // 1. Zero memory is exactly 'None'
    const val_empty = Value{ .bits = 0 };
    try std.testing.expectEqual(Value.Type.None, val_empty.typeOf());

    // 2. Numbers are decoded correctly and do not collide with 0
    const val_zero_float = Value.makeNumber(0.0);
    try std.testing.expectEqual(Value.Type.Number, val_zero_float.typeOf());
    try std.testing.expect(val_zero_float.bits != 0);
    try std.testing.expectEqual(@as(f64, 0.0), val_zero_float.number());

    // 3. Negative numbers work
    const val_neg = Value.makeNumber(-42.5);
    try std.testing.expectEqual(Value.Type.Number, val_neg.typeOf());
    try std.testing.expectEqual(@as(f64, -42.5), val_neg.number());

    // 4. Pointers / Arena Indices are preserved
    const val_obj = Value.box(.Object, 4096);
    try std.testing.expectEqual(Value.Type.Object, val_obj.typeOf());

    // val_obj.
}

test "Value Create String" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const v = Value.makeString(allocator, "Hello World!");

    try std.testing.expectEqual(Value.Type.String, v.typeOf());

    try std.testing.expectEqualStrings("Hello World!", v.string());
}

test "Value Create Concat Strings" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const v = Value.makeStringConcat(allocator, "Hello ", "World!");

    try std.testing.expectEqual(Value.Type.String, v.typeOf());

    try std.testing.expectEqualStrings("Hello World!", v.string());
}

test "Value Create Array" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const v = Value.makeArray(allocator, &.{
        Value.makeString(allocator, "Hello"),
        Value.makeString(allocator, "World!"),
    });

    try std.testing.expectEqual(Value.Type.Array, v.typeOf());

    const arr = v.array();
    try std.testing.expectEqual(2, arr.len);
    try std.testing.expectEqualStrings("Hello", arr[0].string());
    try std.testing.expectEqualStrings("World!", arr[1].string());
}

test "Value Create Array Sized" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const arrRes = Value.makeArraySized(allocator, 2);
    arrRes.slice[0] = Value.makeString(allocator, "Hello");
    arrRes.slice[1] = Value.makeString(allocator, "World!");
    const v = arrRes.value;

    try std.testing.expectEqual(Value.Type.Array, v.typeOf());

    const arr = v.array();
    try std.testing.expectEqual(2, arr.len);
    try std.testing.expectEqualStrings("Hello", arr[0].string());
    try std.testing.expectEqualStrings("World!", arr[1].string());
}
