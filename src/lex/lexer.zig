const std = @import("std");

pub const TokenKind = enum(u8) {
    EOF,

    Number,
    String,
    Identifier,

    BraceL,
    BraceR,
    BracketL,
    BracketR,
    Comma,
    Dollar,
    Dot,
    ParenL,
    ParenR,
    Semicolon,
    Colon,

    Operator,

    // Keywords
    Assert,
    Else,
    Error,
    False,
    For,
    Function,
    If,
    Import,
    ImportStr,
    ImportBin,
    In,
    InSuper,
    Local,
    Null,
    Self,
    Super,
    TailStrict,
    Then,
    True,
};

pub const keywords = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "assert", .Assert },
    .{ "else", .Else },
    .{ "error", .Error },
    .{ "false", .False },
    .{ "for", .For },
    .{ "function", .Function },
    .{ "if", .If },
    .{ "import", .Import },
    .{ "importstr", .ImportStr },
    .{ "importbin", .ImportBin },
    .{ "in", .In },
    .{ "local", .Local },
    .{ "null", .Null },
    .{ "self", .Self },
    .{ "super", .Super },
    .{ "tailstrict", .TailStrict },
    .{ "then", .Then },
    .{ "true", .True },
});

pub const LexError = std.mem.Allocator.Error || error{
    UnexpectedAtSign,
    UnterminatedVerbatimStringLiteral,
    UnterminatedStringLiteral,
    UnterminatedBlockComment,
    LeadingZeroNotAllowedInNumber,

    InvalidCharacter,

    TODOHandleBlockString,
    TODOHandleInSuperHere,
};

pub const Token = struct {
    kind: TokenKind,
    data: []const u8,
    pos: usize,
};

pub const Lexer = struct {
    data: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    error_context: ?struct {
        char: u8,
        pos: usize,
    } = null,

    pub fn next(self: *Lexer) LexError!Token {
        try self.consumeWhitespaceAndComments();

        if (self.pos >= self.data.len) {
            return Token{ .kind = .EOF, .data = "", .pos = @as(u32, @truncate(self.pos)) };
        }

        const start = self.pos;
        const c = self.data[self.pos];
        self.pos += 1;

        switch (c) {
            '{' => {
                return Token{ .kind = .BraceL, .data = "{", .pos = start };
            },
            '}' => {
                return Token{ .kind = .BraceR, .data = "}", .pos = start };
            },
            '[' => {
                return Token{ .kind = .BracketL, .data = "[", .pos = start };
            },
            ']' => {
                return Token{ .kind = .BracketR, .data = "]", .pos = start };
            },
            ',' => {
                return Token{ .kind = .Comma, .data = ",", .pos = start };
            },
            '.' => {
                return Token{ .kind = .Dot, .data = ".", .pos = start };
            },
            '(' => {
                return Token{ .kind = .ParenL, .data = "(", .pos = start };
            },
            ')' => {
                return Token{ .kind = .ParenR, .data = ")", .pos = start };
            },
            ';' => {
                return Token{ .kind = .Semicolon, .data = ";", .pos = start };
            },
            '$' => {
                return Token{ .kind = .Dollar, .data = "$", .pos = start };
            },
            '"', '\'' => {
                return self.lexString(c, start);
            },
            '@' => {
                if (self.pos < self.data.len and (self.data[self.pos] == '"' or self.data[self.pos] == '\'')) {
                    const quote = self.data[self.pos];
                    self.pos += 1;
                    return self.lexVerbatimString(quote, start);
                }
                return LexError.UnexpectedAtSign;
            },
            '|' => {
                if (self.pos < self.data.len and (self.data[self.pos] == '|' and self.data[self.pos + 1] == '|')) {
                    self.pos += 2;
                    // TODO: handle block strings
                    return LexError.TODOHandleBlockString;
                }
                self.pos -= 1;
                return self.lexOperator(start);
            },
            else => {
                if (isDigit(c)) {
                    self.pos -= 1;
                    return self.lexNumber(start);
                }
                if (isIdentFirst(c)) {
                    self.pos -= 1;
                    return self.lexIndent(start);
                }
                if (isSymbol(c)) {
                    self.pos -= 1;
                    return self.lexOperator(start);
                }

                self.error_context = .{
                    .char = c,
                    .pos = start,
                };

                return LexError.InvalidCharacter;
            },
        }
    }

    fn consumeWhitespaceAndComments(self: *Lexer) LexError!void {
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];

            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                self.pos += 1;
                continue;
            }

            if (c == '/') {
                if ((self.pos + 1 < self.data.len) and (self.data[self.pos + 1] == '/')) {
                    self.pos += 2;
                    const maybe_idx = std.mem.indexOfScalar(u8, self.data[self.pos..], '\n');
                    if (maybe_idx) |idx| {
                        self.pos += idx + 1;
                    } else {
                        self.pos = self.data.len;
                    }
                    continue;
                }

                if ((self.pos + 1 < self.data.len) and (self.data[self.pos + 1] == '*')) {
                    self.pos += 2;
                    const maybe_idx = std.mem.indexOf(u8, self.data[self.pos..], "*/");
                    if (maybe_idx) |idx| {
                        self.pos += @as(u32, @truncate(idx + 2));
                        continue;
                    }
                    return LexError.UnterminatedBlockComment;
                }
            }

            if (c == '#') {
                self.pos += 1;
                const maybe_idx = std.mem.indexOfScalar(u8, self.data[self.pos..], '\n');
                if (maybe_idx) |idx| {
                    self.pos += idx + 1;
                } else {
                    self.pos = self.data.len;
                }
                continue;
            }

            break;
        }
        return;
    }

    fn lexString(self: *Lexer, quoteType: u8, start: usize) LexError!Token {
        while (true) {
            const maybe_idx = std.mem.indexOfScalar(u8, self.data[self.pos..], quoteType);
            const idx = maybe_idx orelse {
                return LexError.UnterminatedStringLiteral;
            };

            const absolute_idx = self.pos + idx;

            var backslashes: usize = 0;
            var j = absolute_idx - 1;

            while (j >= start and self.data[j] == '\\') : (j -= 1) {
                backslashes += 1;

                if (j == 0) {
                    break;
                }
            }

            self.pos = absolute_idx + 1;

            if (backslashes % 2 == 0) {
                break;
            }
        }
        return Token{ .kind = .String, .data = self.data[start + 1 .. self.pos - 1], .pos = start };
    }

    fn lexVerbatimString(self: *Lexer, quoteType: u8, start: usize) LexError!Token {
        const strStart = self.pos;
        while (true) {
            const maybe_idx = std.mem.indexOfScalar(u8, self.data[self.pos..], quoteType);
            const idx = maybe_idx orelse {
                return LexError.UnterminatedVerbatimStringLiteral;
            };

            const absolute_idx = self.pos + idx;

            if (absolute_idx + 1 < self.data.len and self.data[absolute_idx + 1] == quoteType) {
                self.pos = absolute_idx + 2;
                continue;
            }

            self.pos = absolute_idx + 1;
            break;
        }

        var str_val = self.data[strStart .. self.pos - 1];

        if (quoteType == '"' and std.mem.indexOf(u8, str_val, "\"\"") != null) {
            str_val = try std.mem.replaceOwned(u8, self.allocator, str_val, "\"\"", "\"");
        } else if (quoteType == '\'' and std.mem.indexOf(u8, str_val, "''") != null) {
            str_val = try std.mem.replaceOwned(u8, self.allocator, str_val, "''", "'");
        }

        return Token{ .kind = .String, .data = str_val, .pos = start };
    }

    fn lexNumber(self: *Lexer, start: usize) !Token {
        if (self.data[self.pos] == 0 and self.pos + 1 < self.data.len and !isDigit(self.data[self.pos + 1])) {
            return LexError.LeadingZeroNotAllowedInNumber;
        }

        // Note: the float parsing later will determine if its a valid number or not, here we just collect the data.
        while (self.pos < self.data.len) {
            const c = self.data[self.pos];
            if (isDigit(c) or c == '.' or c == 'e' or c == 'E') {
                self.pos += 1;
            } else if (c == '+' or c == '-') {
                if (self.pos > start and (self.data[self.pos - 1] == 'e' or self.data[self.pos - 1] == 'E')) {
                    self.pos += 1;
                } else {
                    break;
                }
            } else {
                break;
            }
        }
        return Token{ .kind = .Number, .data = self.data[start..self.pos], .pos = start };
    }

    fn lexIndent(self: *Lexer, start: usize) !Token {
        while (self.pos < self.data.len and isIdent(self.data[self.pos])) {
            self.pos += 1;
        }
        const data = self.data[start..self.pos];

        if (keywords.get(data)) |tk| {
            if (tk == .In) {
                return LexError.TODOHandleInSuperHere;
            }
            return Token{ .kind = tk, .data = data, .pos = start };
        }
        return Token{ .kind = .Identifier, .data = data, .pos = start };
    }

    fn lexOperator(self: *Lexer, start: usize) !Token {
        while (self.pos < self.data.len and isSymbol(self.data[self.pos])) {
            self.pos += 1;
        }
        const data = self.data[start..self.pos];

        if (std.mem.eql(u8, data, ":")) {
            return Token{ .kind = .Colon, .data = data, .pos = start };
        }
        return Token{ .kind = .Operator, .data = data, .pos = start };
    }

    fn isDigit(c: u8) bool {
        return switch (c) {
            '0'...'9' => true,
            else => false,
        };
    }

    fn isIdentFirst(c: u8) bool {
        return switch (c) {
            'a'...'z', 'A'...'Z', '_' => true,
            else => false,
        };
    }

    fn isIdent(c: u8) bool {
        return isIdentFirst(c) or isDigit(c);
    }

    fn isSymbol(c: u8) bool {
        return switch (c) {
            '!', ':', '~', '+', '-', '&', '|', '^', '=', '<', '>', '*', '/', '%' => true,
            else => false,
        };
    }
};
