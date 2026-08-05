const std = @import("std");
const wyhash_seed = 0xb704f588cfebd85f;

const default_interner_size = 16384; // Must be a power of 2
const default_interner_mask = default_interner_size - 1;

const Entry = struct {
    hash: u32,
    idx: u32,
};

pub const Interner = struct {
    table: []Entry,
    strings: std.ArrayList([]const u8),
    mask: u32,
    count: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*Interner {
        var i = try allocator.create(Interner);

        i.* = .{
            .table = try allocator.alloc(Entry, default_interner_size),
            .strings = try std.ArrayList([]const u8).initCapacity(allocator, default_interner_size / 2),
            .mask = default_interner_mask,
            .count = 0,
            .allocator = allocator,
        };

        @memset(i.table, .{ .hash = 0, .idx = 0 });

        try i.strings.append(allocator, "");

        return i;
    }

    pub fn deinit(self: *Interner) void {
        self.allocator.free(self.table);
        self.strings.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn intern(self: *Interner, s: []const u8) !u32 {
        const h = @as(u32, @truncate(std.hash.Wyhash.hash(wyhash_seed, s)));

        var idx = h & self.mask;

        while (true) {
            const e = self.table[idx];

            if (e.idx == 0) {
                const newId = @as(u32, @intCast(self.strings.items.len));
                try self.strings.append(self.allocator, s);
                self.table[idx] = Entry{ .hash = h, .idx = newId };

                self.count = self.count + 1;

                if (self.count > self.mask / 2) {
                    try self.resize();
                }
                return newId;
            }

            if (e.hash == h and std.mem.eql(u8, self.strings.items[e.idx], s)) {
                return e.idx;
            }

            idx = (idx + 1) & self.mask;
        }
    }

    pub fn get(self: *Interner, id: u32) []const u8 {
        if (id == 0 || (id >= self.strings.items.len)) {
            return "";
        }
        return self.strings.items[id];
    }

    pub fn reset(self: *Interner) void {
        @memset(self.table, .{ .hash = 0, .idx = 0 });
        self.strings.shrinkRetainingCapacity(1);
        self.count = 0;
    }

    fn resize(self: *Interner) !void {
        const newMask = (self.mask << 1) | 1;
        const newTable = try self.allocator.alloc(Entry, newMask + 1);

        @memset(newTable, .{ .hash = 0, .idx = 0 });

        for (self.table) |e| {
            if (e.idx == 0) {
                continue;
            }

            var idx = e.hash & newMask;
            while (true) {
                if (newTable[idx].idx == 0) {
                    newTable[idx] = e;
                    break;
                }
                idx = (idx + 1) & newMask;
            }
        }

        self.table = newTable;
        self.mask = newMask;
    }
};

test "BenchmarkInterner_Unique" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    const bench_keys_unique = try allocator.alloc([]const u8, 10_000);
    for (0..bench_keys_unique.len) |i| {
        var b: [10]u8 = undefined;
        random.bytes(&b);
        bench_keys_unique[i] = try std.fmt.allocPrint(allocator, "key_{s}", .{std.fmt.bytesToHex(&b, .lower)});
    }

    const loop_count: usize = 10_000;
    const total_ops: u64 = loop_count * bench_keys_unique.len;

    const start_time = std.Io.Clock.awake.now(std.testing.io).nanoseconds;

    for (0..loop_count) |_| {
        var i = try Interner.init(allocator);

        for (bench_keys_unique) |key| {
            _ = try i.intern(key);
        }

        i.deinit();
    }

    const end_time = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    const elapsed_ns = end_time - start_time;
    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_ops));

    std.debug.print("\n--- BenchmarkInterner_Unique ---\n", .{});
    std.debug.print("Time elapsed: {} ms\n", .{@divTrunc(elapsed_ns, std.time.ns_per_ms)});
    std.debug.print("Speed: {d:.2} ns/op\n\n", .{ns_per_op});
}

test "BenchmarkInterner_Repeated" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    const bench_keys_unique = try allocator.alloc([]const u8, 10_000);
    for (0..bench_keys_unique.len) |i| {
        var b: [10]u8 = undefined;
        random.bytes(&b);
        bench_keys_unique[i] = try std.fmt.allocPrint(allocator, "key_{s}", .{std.fmt.bytesToHex(&b, .lower)});
    }

    const bench_keys_repeated = try allocator.alloc([]const u8, 100_000);
    for (0..bench_keys_repeated.len) |i| {
        bench_keys_repeated[i] = bench_keys_unique[i % 100];
    }

    var i = try Interner.init(allocator);
    defer i.deinit();

    for (bench_keys_repeated) |key| {
        _ = try i.intern(key);
    }

    const loop_count: usize = 5000;
    const total_ops: u64 = loop_count * bench_keys_repeated.len;

    const start_time = std.Io.Clock.awake.now(std.testing.io).nanoseconds;

    for (0..loop_count) |_| {
        for (bench_keys_repeated) |key| {
            _ = try i.intern(key);
        }
    }

    const end_time = std.Io.Clock.awake.now(std.testing.io).nanoseconds;
    const elapsed_ns = end_time - start_time;
    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total_ops));

    std.debug.print("\n--- BenchmarkInterner_Repeated ---\n", .{});
    std.debug.print("Time elapsed: {} ms\n", .{@divTrunc(elapsed_ns, std.time.ns_per_ms)});
    std.debug.print("Speed: {d:.2} ns/op\n\n", .{ns_per_op});
}
