const std = @import("std");

const Lexer = @import("../lex/lexer.zig").Lexer;
const LexError = @import("../lex/lexer.zig").LexError;
const Token = @import("../lex/lexer.zig").Token;
const TokenKind = @import("../lex/lexer.zig").TokenKind;
const Interner = @import("../interner/interner.zig").Interner;
const Node = @import("../ast/node.zig").Node;
const NodeType = @import("../ast/node.zig").NodeType;
const AST = @import("../ast/node.zig").AST;

pub const ParseError = std.mem.Allocator.Error || LexError || error{
    UnexpectedToken,
    ExpectedIndentifierInLocalBinding,
    ExpectedEqualsInLocalBinding,
    ExpectedCommaOrSemiColonAfterLocalBind,
    UnexpectedTokenAfterRootExpr,
    EmptySnippet,
    InvalidNumberLiteral,
    OutOfMemory,
};

const op_prec_map = std.StaticStringMap(i8).initComptime(.{
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

const Parser = struct {
    lex: Lexer,
    name: []const u8,
    peekToken: ?Token,

    nodes: std.ArrayList(Node),
    side_table: std.ArrayList(u32),
    // locations: []NodeContext, // TODO: build locations

    interner: *Interner,
    allocator: std.mem.Allocator,

    pub fn nextToken(self: *Parser) ParseError!Token {
        if (self.peekToken) |t| {
            self.peekToken = null;
            return t;
        }
        return self.lex.next();
    }

    pub fn peek(self: *Parser) ParseError!Token {
        if (self.peekToken) |t| {
            return t;
        }
        const t = try self.lex.next();
        self.peekToken = t;
        return t;
    }

    pub fn emit(self: *Parser, n: Node) !u32 {
        const id: u32 = @as(u32, @truncate(self.nodes.items.len));
        try self.nodes.append(self.allocator, n);
        return id;
    }

    pub fn parseExpr(self: *Parser, prec: i8) ParseError!u32 {
        const tok = try self.nextToken();

        var lhs: u32 = 0;

        switch (tok.kind) {
            else => return ParseError.UnexpectedToken,

            .Number => {
                const num = std.fmt.parseFloat(f64, tok.data) catch {
                    return ParseError.InvalidNumberLiteral;
                };
                lhs = try self.emit(Node{
                    .type = .Number,
                    .data = .{
                        .number = .{ .value = num },
                    },
                });
            },
            .String => {
                const id = try self.interner.intern(tok.data);
                lhs = try self.emit(Node{
                    .type = .String,
                    .data = .{
                        .string = .{ .key_id = id },
                    },
                });
            },
            .True => {
                lhs = try self.emit(Node{
                    .type = .True,
                    .data = .{
                        .none = .{},
                    },
                });
            },
            .False => {
                lhs = try self.emit(Node{
                    .type = .False,
                    .data = .{
                        .none = .{},
                    },
                });
            },
            .Null => {
                lhs = try self.emit(Node{
                    .type = .Null,
                    .data = .{
                        .none = .{},
                    },
                });
            },
            .Identifier => {
                const id = try self.interner.intern(tok.data);
                lhs = try self.emit(Node{
                    .type = .Var,
                    .data = .{
                        .variable = .{ .key_id = id },
                    },
                });
            },
            .Local => {
                return self.parseLocal();
            },
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
        }

        return lhs;
    }

    pub fn parseLocal(self: *Parser) ParseError!u32 {
        const start_idx = @as(u32, @truncate((self.side_table.items.len)));

        while (true) {
            const indentTok = try self.nextToken();

            if (indentTok.kind != .Identifier) {
                return ParseError.ExpectedIndentifierInLocalBinding;
            }

            const name_id = try self.interner.intern(indentTok.data);
            try self.side_table.append(self.allocator, name_id);

            const eqTok = try self.nextToken();
            if (eqTok.kind != .Operator or !std.mem.eql(u8, eqTok.data, "=")) {
                return ParseError.ExpectedEqualsInLocalBinding;
            }

            const exprId = try self.parseExpr(0);
            try self.side_table.append(self.allocator, exprId);

            const tok = try self.peek();
            if (tok.kind == .Comma) {
                _ = try self.nextToken();
                continue;
            } else if (tok.kind == .Semicolon) {
                _ = try self.nextToken();
                break;
            }

            return ParseError.ExpectedCommaOrSemiColonAfterLocalBind;
        }

        const bodyIp = try self.parseExpr(0);

        const curr_idx = @as(u32, @truncate((self.side_table.items.len)));
        const binds_count = (curr_idx - start_idx) / 2;

        return try self.emit(Node{
            .type = .Local,
            .data = .{
                .local = .{ .body = bodyIp, .binds_start = start_idx, .binds_count = binds_count },
            },
        });
    }

    fn getOpPrec(op: []const u8) i8 {
        return op_prec_map.get(op) orelse 0;
    }
};

pub fn ParseSnippet(allocator: std.mem.Allocator, name: []const u8, data: []const u8, interner: *Interner) ParseError!*AST {
    const nodes = try std.ArrayList(Node).initCapacity(allocator, @max(64, data.len / 4));
    // @memset(nodes, .{});

    const side_table = try std.ArrayList(u32).initCapacity(allocator, @max(64, data.len / 4));
    // @memset(side_table, 0);

    var p = Parser{
        .lex = Lexer{ .data = data, .pos = 0, .allocator = allocator },
        .name = name,
        .interner = interner,
        .nodes = nodes,
        .side_table = side_table,
        .peekToken = null,

        .allocator = allocator,
    };

    const root_idx = try p.parseExpr(0);

    const tok = try p.peek();
    if (tok.kind != .EOF) {
        return ParseError.UnexpectedTokenAfterRootExpr;
    }

    if (p.nodes.items.len == 0) {
        return ParseError.EmptySnippet;
    }

    const ast = try allocator.create(AST);

    ast.* = .{
        .root_id = root_idx,
        .nodes = p.nodes.items,
        .side_table = p.side_table.items,
    };

    return ast;
}

test "parse number" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const interner = try Interner.init(allocator);

    const snippet =
        \\123.456
    ;

    const ast = try ParseSnippet(allocator, "test.jsonnet", snippet, interner);

    try std.testing.expectEqual(1, ast.nodes.len);
    try std.testing.expectEqual(NodeType.Number, ast.nodes[0].type);
    try std.testing.expectEqual(123.456, ast.nodes[0].data.number.value);
}

test "parse string" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const interner = try Interner.init(allocator);

    const snippet =
        \\'hello world!'
    ;

    const ast = try ParseSnippet(allocator, "test.jsonnet", snippet, interner);

    try std.testing.expectEqual(1, ast.nodes.len);
    try std.testing.expectEqual(NodeType.String, ast.nodes[0].type);
    try std.testing.expect(ast.nodes[0].data.string.key_id != 0);

    const actual = interner.get(ast.nodes[0].data.string.key_id);
    std.debug.print("\n\n{s}\n\n", .{actual});
    try std.testing.expect(std.mem.eql(u8, "hello world!", actual));
}

test "parse local" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const interner = try Interner.init(allocator);

    const snippet =
        \\local a = 1, b = 2;
        \\12
    ;

    const ast = try ParseSnippet(allocator, "test.jsonnet", snippet, interner);

    const nodes = ast.nodes;

    try std.testing.expectEqual(4, nodes.len);

    try std.testing.expectEqual(NodeType.Number, nodes[0].type);
    try std.testing.expectEqual(1, nodes[0].data.number.value);

    try std.testing.expectEqual(NodeType.Number, nodes[1].type);
    try std.testing.expectEqual(2, nodes[1].data.number.value);

    try std.testing.expectEqual(NodeType.Number, nodes[2].type);
    try std.testing.expectEqual(12, nodes[2].data.number.value);

    try std.testing.expectEqual(NodeType.Local, nodes[3].type);
    try std.testing.expectEqual(0, nodes[3].data.local.binds_start);
    try std.testing.expectEqual(2, nodes[3].data.local.binds_count);
}
