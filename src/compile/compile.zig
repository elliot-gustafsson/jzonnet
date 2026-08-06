const std = @import("std");

const lex = @import("../lex/lexer.zig");
const Interner = @import("../interner/interner.zig").Interner;
const vm = @import("../vm/vm.zig");

const OpCode = @import("program.zig").OpCode;

pub const CompileError = std.mem.Allocator.Error || lex.LexError || error{
    UnexpectedToken,
    ExpectedIndentifierInLocalBinding,
    ExpectedEqualsInLocalBinding,
    ExpectedCommaOrSemiColonAfterLocalBind,
    UnexpectedTokenAfterRootExpr,
    UnexpectedUnaryOperator,
    UnexpectedUnaryOperatorLen,
    EmptySnippet,
    InvalidNumberLiteral,
    OutOfMemory,
    UnknownBinaryOperation,
    UndefinedVariable,
    PositionalArgAfterNamedArg,
};

const bop_prec_map = std.StaticStringMap(i8).initComptime(.{
    .{ "||", 2 },
    .{ "&&", 3 },
    .{ "|", 4 },
    .{ "^", 5 },
    .{ "&", 6 },
    .{ "==", 7 },
    .{ "!=", 7 },
    .{ "<", 8 },
    .{ ">", 8 },
    .{ "<=", 8 },
    .{ ">=", 8 },
    .{ "in", 8 },
    .{ "<<", 9 },
    .{ ">>", 9 },
    .{ "+", 10 },
    .{ "-", 10 },
    .{ "*", 11 },
    .{ "/", 11 },
    .{ "%", 11 },
});

const bop_code_map = std.StaticStringMap(OpCode).initComptime(.{
    .{ "||", .BINARY_OR },
    .{ "&&", .BINARY_AND },
    .{ "|", .BINARY_BITWISE_OR },
    .{ "^", .BINARY_BITWISE_XOR },
    .{ "&", .BINARY_BITWISE_AND },
    .{ "&", .BINARY_BITWISE_AND },
    .{ "==", .BINARY_EQUAL },
    .{ "!=", .BINARY_UNEQUAL },
    .{ "<", .BINARY_LESS },
    .{ ">", .BINARY_GREATER },
    .{ "<=", .BINARY_LESS_EQ },
    .{ ">=", .BINARY_GREATER_EQ },
    // .{ "in", .BINARY_XXX },
    .{ "<<", .BINARY_SHIFT_L },
    .{ ">>", .BINARY_SHIFT_R },
    .{ "+", .BINARY_PLUS },
    .{ "-", .BINARY_MINUS },
    .{ "*", .BINARY_MULT },
    .{ "/", .BINARY_DIV },
    .{ "%", .BINARY_MOD },
});

pub const CallMeta = packed struct(u8) {
    pos_is_u32: bool = false, // Bit 0: 0 = u8, 1 = u32
    named_is_u32: bool = false, // Bit 1: 0 = u8, 1 = u32
    tailstrict: bool = false, // Bit 2: Jsonnet tailstrict flag
    _padding: u5 = 0, // Reserved
};

pub const Compiler = struct {
    lex: lex.Lexer,
    name: []const u8,
    bytecode: std.ArrayList(u8),
    peekToken: ?lex.Token,

    locals: std.ArrayList(u32),

    interner: *Interner,
    allocator: std.mem.Allocator,

    pub fn compileExpr(self: *Compiler, prec: i8) CompileError!void {
        const tok = try self.nextToken();
        return self.compileToken(tok, prec);
    }

    pub fn compileToken(self: *Compiler, tok: lex.Token, prec: i8) CompileError!void {
        switch (tok.kind) {
            else => std.debug.panic(
                "{s}:{d}: unexpected token '{s}' ({s})",
                .{ self.name, tok.pos, tok.data, @tagName(tok.kind) },
            ),

            .Number => try self.compileNumber(tok.data),
            .String => {
                const id = try self.interner.intern(tok.data);
                try self.emit_u32(.STRING, id);
            },
            .True => try self.emit(.TRUE),
            .False => try self.emit(.FALSE),
            .Null => try self.emit(.NULL),
            .Identifier => try self.compileIndentifier(tok.data),
            .Operator => try self.compileOperator(tok.data),

            .Local => try self.compileLocal(),
        }

        while (true) {
            const peekTok = try self.peek();

            if (peekTok.kind == .EOF) {
                break;
            }

            var opPrec: i8 = 0;
            var isBinary = false;
            var isApply = false;
            var isIndex = false;

            if (peekTok.kind == .Operator or peekTok.kind == .In) {
                isBinary = true;
                opPrec = getOpPrec(peekTok.data);
            } else if (peekTok.kind == .ParenL or peekTok.kind == .BraceL) {
                isApply = true;
                opPrec = 13;
            } else if (peekTok.kind == .BracketL or peekTok.kind == .Dot) {
                isIndex = true;
                opPrec = 13;
            }

            if ((!isBinary and !isApply and !isIndex) or opPrec <= prec) {
                break;
            }

            _ = try self.nextToken();

            if (isBinary) {
                try self.compileExpr(opPrec);

                if (bop_code_map.get(peekTok.data)) |opcode| {
                    try self.emit(opcode);
                    continue;
                }
                return CompileError.UnknownBinaryOperation;
            }

            if (isApply) {
                if (peekTok.kind == .ParenL) {
                    try self.compileApply();
                }
            }
        }
    }

    fn nextToken(self: *Compiler) !lex.Token {
        if (self.peekToken) |t| {
            self.peekToken = null;
            return t;
        }
        return self.lex.next();
    }

    pub fn peek(self: *Compiler) !lex.Token {
        if (self.peekToken) |t| {
            return t;
        }
        const t = try self.lex.next();
        self.peekToken = t;
        return t;
    }

    inline fn emit(self: *Compiler, code: OpCode) !void {
        try self.bytecode.append(self.allocator, @intFromEnum(code));
    }

    inline fn emit_u8(self: *Compiler, code: OpCode, v: u8) !void {
        // Allocate room for the OpCode and a u8
        const required_capacity = @sizeOf(OpCode) + @sizeOf(u8);
        try self.bytecode.ensureUnusedCapacity(self.allocator, required_capacity);

        self.bytecode.appendAssumeCapacity(@intFromEnum(code));
        self.bytecode.appendAssumeCapacity(v);
    }

    inline fn emit_u16(self: *Compiler, code: OpCode, v: u16) !void {
        // Allocate room for the OpCode and a u16
        const required_capacity = @sizeOf(OpCode) + @sizeOf(u16);
        try self.bytecode.ensureUnusedCapacity(self.allocator, required_capacity);

        self.bytecode.appendAssumeCapacity(@intFromEnum(code));

        const bits = std.mem.nativeToLittle(u16, v);
        const bytes = std.mem.toBytes(bits);
        self.bytecode.appendSliceAssumeCapacity(&bytes);
    }

    inline fn emit_u32(self: *Compiler, code: OpCode, v: u32) !void {
        // Allocate room for the OpCode and a u32
        const required_capacity = @sizeOf(OpCode) + @sizeOf(u32);
        try self.bytecode.ensureUnusedCapacity(self.allocator, required_capacity);

        self.bytecode.appendAssumeCapacity(@intFromEnum(code));

        const bits = std.mem.nativeToLittle(u32, v);
        const bytes = std.mem.toBytes(bits);
        self.bytecode.appendSliceAssumeCapacity(&bytes);
    }

    inline fn emit_u64(self: *Compiler, code: OpCode, v: u64) !void {
        // Allocate room for the OpCode and a u64
        const required_capacity = @sizeOf(OpCode) + @sizeOf(u64);
        try self.bytecode.ensureUnusedCapacity(self.allocator, required_capacity);

        self.bytecode.appendAssumeCapacity(@intFromEnum(code));

        const bits = std.mem.nativeToLittle(u64, v);
        const bytes = std.mem.toBytes(bits);

        self.bytecode.appendSliceAssumeCapacity(&bytes);
    }

    fn getOpPrec(op: []const u8) i8 {
        return bop_prec_map.get(op) orelse 0;
    }

    inline fn compileNumber(self: *Compiler, data: []const u8) !void {
        const num = std.fmt.parseFloat(f64, data) catch {
            return CompileError.InvalidNumberLiteral;
        };

        // TODO: make NUMBER_8 and NUMBER_16 for smaller integer values

        if (@trunc(num) == num) {
            if (num >= std.math.minInt(i8) and num <= std.math.maxInt(i8)) {
                try self.emit_u8(.NUMBER_8, @bitCast(@as(i8, @intFromFloat(num))));
                return;
            }

            if (num >= std.math.minInt(i16) and num <= std.math.maxInt(i16)) {
                try self.emit_u16(.NUMBER_16, @bitCast(@as(i16, @intFromFloat(num))));
                return;
            }
        }

        try self.emit_u64(.NUMBER, @as(u64, @bitCast(num)));
    }

    inline fn compileIndentifier(self: *Compiler, data: []const u8) !void {
        const id = try self.interner.intern(data);

        if (self.locals.items.len > 0) {

            // Search backwards to get the innermost shadowed variable
            var i: usize = self.locals.items.len - 1;
            var found_index: ?usize = null;
            while (i >= 0) : (i -= 1) {
                if (self.locals.items[i] == id) {
                    found_index = i;
                    break;
                }
            }

            if (found_index) |idx| {
                if (idx <= std.math.maxInt(u8)) {
                    try self.emit_u8(.VAR_8, @intCast(idx));
                    return;
                }
                try self.emit_u32(.VAR, @intCast(idx));
                return;
            }
        }

        return CompileError.UndefinedVariable;
    }

    inline fn compileOperator(self: *Compiler, data: []const u8) !void {
        if (data.len != 1) {
            return CompileError.UnexpectedUnaryOperatorLen;
        }

        const op = switch (data[0]) {
            '+' => OpCode.UNARY_PLUS,
            '-' => OpCode.UNARY_MINUS,
            '!' => OpCode.UNARY_NOT,
            '~' => OpCode.UNARY_BITWISE_NOT,
            else => return CompileError.UnexpectedUnaryOperator,
        };

        try self.compileExpr(12);

        if (op != .UNARY_PLUS) {
            // plus is noop
            try self.emit(op);
        }
    }

    fn compileLocal(self: *Compiler) CompileError!void {
        const scope_start = self.locals.items.len;
        var binds_count: usize = 0;

        // try self.emit_u32(.LOCAL, 0); // emit 0, will patch when knowing actual count

        while (true) {
            const indentifier_token = try self.nextToken();

            // std.debug.print("\n\n{s} {d}\n\n", .{ @tagName(indentifier_token.kind), indentifier_token.pos });

            if (indentifier_token.kind != .Identifier) {
                return CompileError.ExpectedIndentifierInLocalBinding;
            }

            const name_id = try self.interner.intern(indentifier_token.data);
            // try self.append_u32(name_id);

            const eq_token = try self.nextToken();
            if (eq_token.kind != .Operator or !std.mem.eql(u8, eq_token.data, "=")) {
                return CompileError.ExpectedEqualsInLocalBinding;
            }

            try self.locals.append(self.allocator, name_id);
            binds_count += 1;

            try self.compileExpr(0);

            const tok = try self.peek();
            if (tok.kind == .Comma) {
                _ = try self.nextToken();
                continue;
            } else if (tok.kind == .Semicolon) {
                _ = try self.nextToken();
                break;
            }

            return CompileError.ExpectedCommaOrSemiColonAfterLocalBind;
        }

        try self.compileExpr(0);

        // slice locals tracker
        self.locals.items.len = scope_start;

        if (binds_count <= std.math.maxInt(u8)) {
            try self.emit_u8(.POP_LOCALS_8, @intCast(binds_count));
            return;
        }

        try self.emit_u32(.POP_LOCALS, @intCast(binds_count));
    }

    fn compileApply(self: *Compiler) CompileError!void {

        // asdf.exex(asdf=2);

        var pos_count: usize = 0;
        var named_count: usize = 0;

        var named_keys = try std.ArrayList(u32).initCapacity(self.allocator, 8);
        defer named_keys.deinit(self.allocator);

        while (true) {
            const tok = try self.peek();
            if (tok.kind == .ParenR) {
                _ = try self.nextToken(); // consume right parentheses
                break;
            }

            if (tok.kind == .Identifier) {
                _ = try self.nextToken(); // consume identifier token
                const next_tok = try self.peek();

                if (next_tok.kind == .Operator and std.mem.eql(u8, next_tok.data, "=")) {
                    _ = try self.nextToken(); // consume =

                    const name_id = try self.interner.intern(tok.data);
                    try named_keys.append(self.allocator, name_id);

                    try self.compileExpr(0);
                    named_count += 1;
                } else {
                    if (named_count > 0) {
                        return CompileError.PositionalArgAfterNamedArg;
                    }

                    // if not named its need to be properly compiled
                    try self.compileToken(tok, 0);

                    pos_count += 1;
                }
            } else {
                if (named_count > 0) {
                    return CompileError.PositionalArgAfterNamedArg;
                }

                try self.compileExpr(0);
                pos_count += 1;
            }

            const next_token = try self.peek();
            if (next_token.kind == .Comma) {
                _ = try self.nextToken(); // consume ,
            } else if (next_token.kind == .ParenR) {
                _ = try self.nextToken(); // consume )
                break;
            } else {
                std.debug.print("\n\n{s}\n\n", .{@tagName(tok.kind)});
                return CompileError.UnexpectedToken;
            }
        }

        if (named_count == 0) {
            switch (pos_count) {
                0 => try self.emit(.CALL_0),
                1 => try self.emit(.CALL_1),
                2 => try self.emit(.CALL_2),
                3 => try self.emit(.CALL_3),
                4 => try self.emit(.CALL_4),
                5...255 => try self.emit_u8(.CALL_8, @intCast(pos_count)),
                else => try self.emitComplexCall(pos_count, 0, &.{}),
            }
        } else {
            // complex call with named arguments
            try self.emitComplexCall(pos_count, named_count, named_keys.items);
        }
    }

    fn emitComplexCall(self: *Compiler, pos_count: usize, named_count: usize, named_keys: []const u32) !void {
        const meta = CallMeta{
            .pos_is_u32 = pos_count > std.math.maxInt(u8),
            .named_is_u32 = named_count > std.math.maxInt(u8),
        };

        const pos_len: usize = if (meta.pos_is_u32) @sizeOf(u32) else @sizeOf(u8);
        const named_len: usize = if (meta.named_is_u32) @sizeOf(u32) else @sizeOf(u8);
        const keys_len = named_keys.len * @sizeOf(u32);

        const required_capacity = @sizeOf(OpCode) + @sizeOf(CallMeta) + pos_len + named_len + keys_len;
        try self.bytecode.ensureUnusedCapacity(self.allocator, required_capacity);

        self.bytecode.appendAssumeCapacity(@intFromEnum(OpCode.CALL));
        self.bytecode.appendAssumeCapacity(@bitCast(meta));

        // 3. Append positional argument count (u8 or u32)
        if (meta.pos_is_u32) {
            const bits = std.mem.nativeToLittle(u32, @intCast(pos_count));
            self.bytecode.appendSliceAssumeCapacity(&std.mem.toBytes(bits));
        } else {
            self.bytecode.appendAssumeCapacity(@intCast(pos_count));
        }

        // 4. Append named argument count (u8 or u32)
        if (meta.named_is_u32) {
            const bits = std.mem.nativeToLittle(u32, @intCast(named_count));
            self.bytecode.appendSliceAssumeCapacity(&std.mem.toBytes(bits));
        } else {
            self.bytecode.appendAssumeCapacity(@intCast(named_count));
        }

        // 5. Append array of named parameter key IDs
        for (named_keys) |key_id| {
            const bits = std.mem.nativeToLittle(u32, key_id);
            self.bytecode.appendSliceAssumeCapacity(&std.mem.toBytes(bits));
        }
    }

    fn isUnaryOp(data: []const u8) bool {
        if (data.len != 1) return false;
        return switch (data[0]) {
            '!', '-', '+', '~' => true,
            else => false,
        };
    }
};
