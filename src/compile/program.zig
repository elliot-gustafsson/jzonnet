const std = @import("std");

const lex = @import("../lex/lexer.zig");
const vm = @import("../vm/vm.zig");
const Interner = @import("../interner/interner.zig").Interner;

const Compiler = @import("compile.zig").Compiler;
const CallMeta = @import("compile.zig").CallMeta;
const CompileError = @import("compile.zig").CompileError;
const FunctionParamMeta = @import("compile.zig").FunctionParamMeta;

pub const OpCode = enum(u8) {
    RETURN,
    ADD,

    NUMBER,
    NUMBER_8,
    NUMBER_16,

    STRING,
    TRUE,
    FALSE,
    NULL,

    VAR_8,
    VAR,
    // LOCAL,

    POP_LOCALS_8,
    POP_LOCALS,

    FUNCTION,

    BINARY_AND,
    BINARY_OR,
    BINARY_EQUAL,
    BINARY_PLUS,
    BINARY_MINUS,
    BINARY_DIV,
    BINARY_MULT,
    BINARY_MOD,
    BINARY_BITWISE_AND,
    BINARY_BITWISE_OR,
    BINARY_BITWISE_XOR,
    BINARY_SHIFT_L,
    BINARY_SHIFT_R,
    BINARY_UNEQUAL,
    BINARY_GREATER,
    BINARY_GREATER_EQ,
    BINARY_LESS,
    BINARY_LESS_EQ,

    UNARY_PLUS, // noop
    UNARY_MINUS,
    UNARY_NOT,
    UNARY_BITWISE_NOT,

    CALL_0,
    CALL_1,
    CALL_2,
    CALL_3,
    CALL_4,
    CALL_8,
    CALL,

    JUMP_FWD_16,
};

pub const Program = struct {
    name: []const u8,
    bytecode: []const u8,
    // location_data: []Location,

    pub fn disassemble(self: Program, interner: *Interner) void {
        var ip: usize = 0;

        std.debug.print("\n\n=== Bytecode Disassembly ({s}) ({d} bytes) ===\n", .{ self.name, self.bytecode.len });

        while (ip < self.bytecode.len) {
            const start_ip = ip;
            const op: OpCode = @enumFromInt(self.bytecode[ip]);
            ip += 1;

            switch (op) {
                else => {
                    std.debug.print("{d:0>4}: {s}\n", .{ start_ip, @tagName(op) });
                },

                .NUMBER => {
                    if (ip + 8 > self.bytecode.len) {
                        break;
                    }
                    const raw = std.mem.readInt(u64, self.bytecode[ip..][0..8], .little);
                    const num: f64 = @bitCast(raw);
                    ip += 8;
                    std.debug.print("{d:0>4}: {s} {d}\n", .{ start_ip, @tagName(op), num });
                },
                .NUMBER_8, .VAR_8 => {
                    if (ip + 1 > self.bytecode.len) {
                        break;
                    }
                    const raw: i8 = @bitCast(self.bytecode[ip]);
                    const num: f64 = @floatFromInt(raw);
                    ip += 1; // Advance 1 byte for i8
                    std.debug.print("{d:0>4}: {s} {d}\n", .{ start_ip, @tagName(op), num });
                },
                .NUMBER_16 => {
                    if (ip + 2 > self.bytecode.len) {
                        break;
                    }
                    const raw = std.mem.readInt(u16, self.bytecode[ip..][0..2], .little);
                    const num: f64 = @floatFromInt(@as(i16, @bitCast(raw)));
                    ip += 2; // Advance 2 bytes for i16
                    std.debug.print("{d:0>4}: {s} {d}\n", .{ start_ip, @tagName(op), num });
                },
                .STRING => {
                    if (ip + 4 > self.bytecode.len) {
                        break;
                    }
                    const raw = std.mem.readInt(u32, self.bytecode[ip..][0..4], .little);
                    const s = interner.get(raw);
                    ip += 4;
                    std.debug.print("{d:0>4}: {s} '{s}'\n", .{ start_ip, @tagName(op), s });
                },

                .POP_LOCALS_8 => {
                    if (ip + 1 > self.bytecode.len) {
                        break;
                    }
                    const raw = self.bytecode[ip];
                    ip += 1;
                    std.debug.print("{d:0>4}: {s} {d}\n", .{ start_ip, @tagName(op), raw });
                },

                .POP_LOCALS, .VAR => {
                    if (ip + 4 > self.bytecode.len) {
                        break;
                    }
                    const raw = std.mem.readInt(u32, self.bytecode[ip..][0..4], .little);
                    ip += 4;
                    std.debug.print("{d:0>4}: {s} {d}\n", .{ start_ip, @tagName(op), raw });
                },

                // .VAR => {
                //     if (ip + 4 > self.bytecode.len) {
                //         break;
                //     }
                //     const raw = std.mem.readInt(u32, self.bytecode[ip..][0..4], .little);
                //     const s = interner.get(raw);
                //     ip += 4;
                //     std.debug.print("{d:0>4}: {s} '{s}'\n", .{ start_ip, @tagName(op), s });
                // },

                .CALL_8 => {
                    const count = self.bytecode[ip];
                    ip += 1;
                    std.debug.print("{d:0>4}: CALL_8 pos={d}\n", .{ start_ip, count });
                },
                .CALL => {
                    const meta: CallMeta = @bitCast(self.bytecode[ip]);
                    ip += 1;

                    var pos_count: u32 = undefined;
                    if (meta.pos_is_u32) {
                        pos_count = std.mem.readInt(u32, self.bytecode[ip..][0..4], .little);
                        ip += 4;
                    } else {
                        pos_count = self.bytecode[ip];
                        ip += 1;
                    }

                    var named_count: u32 = undefined;
                    if (meta.named_is_u32) {
                        named_count = std.mem.readInt(u32, self.bytecode[ip..][0..4], .little);
                        ip += 4;
                    } else {
                        named_count = self.bytecode[ip];
                        ip += 1;
                    }

                    std.debug.print("{d:0>4}: CALL pos={d} named={d}", .{ start_ip, pos_count, named_count });

                    if (named_count > 0) {
                        std.debug.print(" [", .{});

                        for (0..named_count) |i| {
                            const name_id = std.mem.readInt(u32, self.bytecode[ip..][0..4], .little);
                            ip += 4;
                            if (i > 0) std.debug.print(", ", .{});
                            const name = interner.get(name_id);
                            std.debug.print("{s}", .{name});
                        }
                        std.debug.print("]", .{});
                    }

                    if (meta.tailstrict) {
                        std.debug.print(" (tailstrict) ", .{});
                    }

                    std.debug.print("\n", .{});
                },

                .FUNCTION => {
                    const jump_len = std.mem.readInt(u32, self.bytecode[ip..][0..4], .little);
                    ip += 4;

                    const args_count = std.mem.readInt(u32, self.bytecode[ip..][0..4], .little);
                    ip += 4;

                    std.debug.print("{d:0>4}: FUNCTION jump_len={d} args={d} (", .{ start_ip, jump_len, args_count });

                    for (0..args_count) |i| {
                        const name_id = std.mem.readInt(u32, self.bytecode[ip..][0..4], .little);
                        ip += 4;

                        const meta: FunctionParamMeta = @bitCast(self.bytecode[ip]);
                        ip += 1;

                        if (i > 0) std.debug.print(", ", .{});
                        std.debug.print("{s}", .{interner.get(name_id)});

                        if (meta.has_default) {
                            const default_len = std.mem.readInt(u32, self.bytecode[ip..][0..4], .little);
                            ip += 4;
                            std.debug.print("=<default len={d}>", .{default_len});

                            ip += default_len;
                        }
                    }
                    std.debug.print(")\n", .{});
                },
            }
        }

        std.debug.print("\n", .{});
    }
};

pub fn CompileSnippet(allocator: std.mem.Allocator, name: []const u8, data: []const u8, interner: *Interner) !*Program {
    const bytecode = try std.ArrayList(u8).initCapacity(allocator, 1024);

    const lexer = try allocator.create(lex.Lexer);
    lexer.* = lex.Lexer{
        .allocator = allocator,
        .data = data,
        .pos = 0,

        .tokens = try std.ArrayList(lex.TokenKind).initCapacity(allocator, 1024),
        .starts = try std.ArrayList(u32).initCapacity(allocator, 1024),
        .ends = try std.ArrayList(u32).initCapacity(allocator, 1024),
    };

    const tokenList = try lexer.lex();

    var c = Compiler{
        .name = name,
        .data = data,
        .bytecode = bytecode,
        .peekToken = null,

        .token_list = tokenList,
        .token_list_pos = 0,

        .locals = try std.ArrayList(u32).initCapacity(allocator, 128),

        .allocator = allocator,
        .interner = interner,
    };

    try c.compileExpr(0);

    const tok = c.peek();
    if (tok.kind != .EOF) {
        std.debug.print("\n\n{s}\n\n", .{@tagName(tok.kind)});
        return CompileError.UnexpectedTokenAfterRootExpr;
    }

    try c.bytecode.append(c.allocator, @intFromEnum(OpCode.RETURN));

    const program = try allocator.create(Program);

    program.* = .{
        .name = c.name,
        .bytecode = c.bytecode.items,
    };

    return program;
}

test "compile number" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const interner = try Interner.init(allocator);

    const snippet =
        \\132.32
    ;

    const p = try CompileSnippet(allocator, "test.jsonnet", snippet, interner);

    p.disassemble(interner);
}

test "compile string" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const interner = try Interner.init(allocator);

    const snippet =
        \\"banan"
    ;

    const p = try CompileSnippet(allocator, "test.jsonnet", snippet, interner);

    p.disassemble(interner);
}

test "compile local" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const interner = try Interner.init(allocator);

    const snippet =
        \\local a = 1, b = 2;
        \\local c = 3;
        \\c - a
    ;

    const p = try CompileSnippet(allocator, "test.jsonnet", snippet, interner);

    p.disassemble(interner);
}

test "compile unary expr" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const interner = try Interner.init(allocator);

    const snippet =
        \\-132.32
    ;

    const p = try CompileSnippet(allocator, "test.jsonnet", snippet, interner);

    p.disassemble(interner);
}

test "compile binary expr" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const interner = try Interner.init(allocator);

    const snippet =
        \\1 + 2
    ;

    const p = try CompileSnippet(allocator, "test.jsonnet", snippet, interner);

    p.disassemble(interner);
}

test "compile apply" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const interner = try Interner.init(allocator);

    const snippet =
        \\local asdf = 1;
        \\asdf(x=1)
    ;

    const p = try CompileSnippet(allocator, "test.jsonnet", snippet, interner);

    p.disassemble(interner);
}

test "compile tailstrict apply " {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const interner = try Interner.init(allocator);

    const snippet =
        \\local asdf = function(x, y=2, z) x * y * z;
        \\asdf(1, 2, 3) tailstrict
    ;

    const p = try CompileSnippet(allocator, "test.jsonnet", snippet, interner);

    p.disassemble(interner);
}
