//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

pub const interner = @import("interner/interner.zig");
// pub const ast = @import("ast/node.zig");
// pub const parser = @import("parse/parser.zig");
pub const compile = @import("compile/compile.zig");
pub const program = @import("compile/program.zig");
pub const vm = @import("vm/vm.zig");

test {
    // This forces the compiler to run tests in these files
    // when `zig build test` is run against `root.zig`
    std.testing.refAllDecls(@This());
}

test "evaluate number" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const i = try interner.Interner.init(allocator);

    const snippet =
        \\132.32
    ;

    const p = try program.CompileSnippet(allocator, "test.jsonnet", snippet, i);

    const x = try allocator.create(vm.VM);
    x.* = .{
        .program = p,
    };

    p.disassemble(i);

    const val = try x.execute(0);

    try std.testing.expectEqual(@as(f64, 132.32), val.number());
}

test "evaluate locals" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const i = try interner.Interner.init(allocator);

    const snippet =
        \\local a = 1.2, b = 2;
        \\local c = 3;
        \\c - a
    ;

    const p = try program.CompileSnippet(allocator, "test.jsonnet", snippet, i);

    const x = try allocator.create(vm.VM);
    x.* = .{
        .program = p,
    };

    p.disassemble(i);

    const val = try x.execute(0);

    try std.testing.expectEqual(@as(f64, 1.8), val.number());
}
