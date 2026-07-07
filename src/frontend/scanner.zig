const std = @import("std");
const tokens = @import("tokens.zig");

const TokenType = tokens.TokenType;
const Token = tokens.Token;
const Span = tokens.Span;
const TokenFlags = tokens.TokenFlags;
const LexicalError = tokens.LexicalError;
const diagnostics = @import("../diagnostics/root.zig");

pub const Comment = struct {
    kind: TokenType,
    lexeme: []const u8,
    span: Span,
};

pub const ScanResult = struct {
    tokens: []const Token,
    comments: []const Comment,
    diagnostics: []const diagnostics.Diagnostic,
};

pub const ScannerConfig = struct {
    trivia_policy: tokens.TriviaPolicy = .skip,

    /// If true, line terminators are emitted as EOL tokens.
    /// If false, line terminators are consumed as trivia and represented through
    /// TokenFlags.has_leading_line_break on the next real token.
    emit_eol: bool = false,
};

const TokenStart = struct {
    index: usize,
    line: u32,
    column: u32,
    has_leading_line_break: bool,
};

pub const Scanner = struct {
    source: []const u8,
    index: usize = 0,
    line: u32 = 1,
    column: u32 = 1,
    config: ScannerConfig = .{},

    /// Set whenever trivia before the next emitted non-EOL token contained a line break.
    leading_line_break: bool = false,

    pub fn init(source: []const u8, config: ScannerConfig) Scanner {
        return .{
            .source = source,
            .config = config,
        };
    }

    pub fn nextToken(self: *Scanner) LexicalError!Token {
        while (true) {
            if (self.isAtEnd()) {
                return self.makeCurrentToken(.EOF);
            }

            const before_trivia = self.index;
            if (try self.consumeTrivia()) |trivia_token| {
                return trivia_token;
            }

            if (self.index != before_trivia) {
                continue;
            }

            break;
        }

        if (self.isAtEnd()) {
            return self.makeCurrentToken(.EOF);
        }

        const c = self.peek().?;
        const start = self.markStart();

        if (tokens.isAsciiIdentifierStart(c)) {
            return self.scanIdentifier(start);
        }

        if (c == '#') {
            if (self.peekN(1)) |next| {
                if (tokens.isAsciiIdentifierStart(next)) {
                    return self.scanPrivateIdentifier(start);
                }
            }
        }

        if (tokens.isDecimalDigit(c) or (c == '.' and self.peekN(1) != null and tokens.isDecimalDigit(self.peekN(1).?))) {
            return try self.scanNumber(start);
        }

        if (tokens.isQuote(c)) {
            return try self.scanString(start);
        }

        return self.scanPunctuatorOrInvalid(start);
    }

    //#region Cursor primitives

    fn isAtEnd(self: *const Scanner) bool {
        return self.index >= self.source.len;
    }

    fn peek(self: *const Scanner) ?u8 {
        if (self.index >= self.source.len) return null;
        return self.source[self.index];
    }

    fn peekN(self: *const Scanner, n: usize) ?u8 {
        const target = self.index + n;
        if (target >= self.source.len) return null;
        return self.source[target];
    }

    fn peekIs(self: *const Scanner, expected: u8) bool {
        return if (self.peek()) |current| current == expected else false;
    }

    fn startsWith(self: *const Scanner, text: []const u8) bool {
        return std.mem.startsWith(u8, self.source[self.index..], text);
    }

    fn advance(self: *Scanner) ?u8 {
        if (self.isAtEnd()) return null;

        const c = self.source[self.index];
        self.index += 1;

        if (c == '\r') {
            if (!self.isAtEnd() and self.source[self.index] == '\n') {
                self.index += 1;
            }

            self.line += 1;
            self.column = 1;
            return c;
        }

        if (c == '\n') {
            self.line += 1;
            self.column = 1;
            return c;
        }

        self.column += 1;
        return c;
    }

    fn advanceN(self: *Scanner, count: usize) void {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            _ = self.advance();
        }
    }

    fn markStart(self: *const Scanner) TokenStart {
        return .{
            .index = self.index,
            .line = self.line,
            .column = self.column,
            .has_leading_line_break = self.leading_line_break,
        };
    }

    fn makeSpan(self: *const Scanner, start: TokenStart) Span {
        return .{
            .start = @intCast(start.index),
            .end = @intCast(self.index),
            .line = start.line,
            .column = start.column,
        };
    }

    fn makeToken(self: *Scanner, start: TokenStart, kind: TokenType, flags: TokenFlags) Token {
        var out_flags = flags;
        out_flags.has_leading_line_break = start.has_leading_line_break;

        self.leading_line_break = false;

        return Token.initWithFlags(
            kind,
            self.source[start.index..self.index],
            self.makeSpan(start),
            out_flags,
        );
    }

    fn makeCurrentToken(self: *Scanner, kind: TokenType) Token {
        const start = self.markStart();
        return self.makeToken(start, kind, .{});
    }

    fn makeTriviaTokenPreserveLeadingBreak(self: *Scanner, start: TokenStart, kind: TokenType) Token {
        return Token.initWithFlags(
            kind,
            self.source[start.index..self.index],
            self.makeSpan(start),
            .{},
        );
    }

    //#endregion

    //#region Trivia

    fn consumeTrivia(self: *Scanner) LexicalError!?Token {
        const c = self.peek() orelse return null;

        if (tokens.isWhitespace(c)) {
            _ = self.advance();
            return null;
        }

        if (tokens.isLineTerminator(c)) {
            const start = self.markStart();
            _ = self.advance();
            self.leading_line_break = true;

            if (self.config.emit_eol) {
                return self.makeTriviaTokenPreserveLeadingBreak(start, .EOL);
            }

            return null;
        }

        if (self.index == 0 and self.startsWith("#!")) {
            return self.scanLineLikeComment(.Shebang);
        }

        if (self.startsWith("//")) {
            return self.scanLineLikeComment(.LineComment);
        }

        if (self.startsWith("/*")) {
            return try self.scanBlockComment();
        }

        return null;
    }

    fn scanLineLikeComment(self: *Scanner, kind: TokenType) ?Token {
        const start = self.markStart();

        while (!self.isAtEnd()) {
            const c = self.peek().?;
            if (tokens.isLineTerminator(c)) break;
            _ = self.advance();
        }

        if (self.config.trivia_policy == .emit_comments) {
            return self.makeToken(start, kind, .{});
        }

        return null;
    }

    fn scanBlockComment(self: *Scanner) LexicalError!?Token {
        const start = self.markStart();

        // /*
        self.advanceN(2);

        var saw_line_break = false;

        while (!self.isAtEnd()) {
            if (self.startsWith("*/")) {
                self.advanceN(2);

                if (saw_line_break) {
                    self.leading_line_break = true;
                }

                if (self.config.trivia_policy == .emit_comments) {
                    const token = self.makeTriviaTokenPreserveLeadingBreak(start, .BlockComment);
                    if (saw_line_break) {
                        self.leading_line_break = true;
                    }
                    return token;
                }

                return null;
            }

            const c = self.peek().?;
            if (tokens.isLineTerminator(c)) {
                saw_line_break = true;
            }

            _ = self.advance();
        }

        return LexicalError.UnterminatedComment;
    }

    //#endregion

    //#region Identifiers

    fn scanIdentifier(self: *Scanner, start: TokenStart) Token {
        while (!self.isAtEnd()) {
            const c = self.peek().?;
            if (!tokens.isAsciiIdentifierPart(c)) break;
            _ = self.advance();
        }

        const lexeme = self.source[start.index..self.index];
        const kind = tokens.classifyIdentifier(lexeme);

        return self.makeToken(start, kind, .{});
    }

    fn scanPrivateIdentifier(self: *Scanner, start: TokenStart) Token {
        // #
        _ = self.advance();

        while (!self.isAtEnd()) {
            const c = self.peek().?;
            if (!tokens.isAsciiIdentifierPart(c)) break;
            _ = self.advance();
        }

        return self.makeToken(start, .PrivateIdentifier, .{});
    }

    //#endregion

    //#region Numbers

    fn scanNumber(self: *Scanner, start: TokenStart) LexicalError!Token {
        var is_bigint = false;
        var saw_dot = false;
        var saw_exponent = false;

        if (self.peekIs('.')) {
            saw_dot = true;
            _ = self.advance(); // .

            const saw_fraction_digit = try self.scanDigits(tokens.isDecimalDigit);
            if (!saw_fraction_digit) return LexicalError.InvalidNumberFormat;

            if (self.peek()) |c| {
                if (c == 'e' or c == 'E') {
                    saw_exponent = true;
                    try self.scanExponent();
                }
            }

            return self.makeToken(start, .NumberLiteral, .{});
        }

        if (self.peekIs('0')) {
            if (self.peekN(1)) |prefix| {
                switch (prefix) {
                    'x', 'X' => {
                        self.advanceN(2);
                        if (!try self.scanDigits(tokens.isHexDigit)) {
                            return LexicalError.InvalidNumberFormat;
                        }

                        if (self.peekIs('n')) {
                            is_bigint = true;
                            _ = self.advance();
                        }

                        return self.makeToken(start, if (is_bigint) .BigIntLiteral else .NumberLiteral, .{});
                    },
                    'b', 'B' => {
                        self.advanceN(2);
                        if (!try self.scanDigits(tokens.isBinaryDigit)) {
                            return LexicalError.InvalidNumberFormat;
                        }

                        if (self.peekIs('n')) {
                            is_bigint = true;
                            _ = self.advance();
                        }

                        return self.makeToken(start, if (is_bigint) .BigIntLiteral else .NumberLiteral, .{});
                    },
                    'o', 'O' => {
                        self.advanceN(2);
                        if (!try self.scanDigits(tokens.isOctalDigit)) {
                            return LexicalError.InvalidNumberFormat;
                        }

                        if (self.peekIs('n')) {
                            is_bigint = true;
                            _ = self.advance();
                        }

                        return self.makeToken(start, if (is_bigint) .BigIntLiteral else .NumberLiteral, .{});
                    },
                    else => {},
                }
            }
        }

        if (!try self.scanDigits(tokens.isDecimalDigit)) {
            return LexicalError.InvalidNumberFormat;
        }

        if (self.peekIs('.')) {
            saw_dot = true;
            _ = self.advance();

            // `1.` is valid. Fraction digits are optional after the dot.
            _ = try self.scanDigits(tokens.isDecimalDigit);
        }

        if (self.peek()) |c| {
            if (c == 'e' or c == 'E') {
                saw_exponent = true;
                try self.scanExponent();
            }
        }

        if (!saw_dot and !saw_exponent and self.peekIs('n')) {
            is_bigint = true;
            _ = self.advance();
        }

        return self.makeToken(start, if (is_bigint) .BigIntLiteral else .NumberLiteral, .{});
    }

    fn scanExponent(self: *Scanner) LexicalError!void {
        // e / E
        _ = self.advance();

        if (self.peek()) |sign| {
            if (sign == '+' or sign == '-') {
                _ = self.advance();
            }
        }

        if (!try self.scanDigits(tokens.isDecimalDigit)) {
            return LexicalError.InvalidExponent;
        }
    }

    fn scanDigits(
        self: *Scanner,
        comptime isDigitFn: fn (u8) bool,
    ) LexicalError!bool {
        var saw_digit = false;
        var previous_was_separator = false;

        while (!self.isAtEnd()) {
            const c = self.peek().?;

            if (c == '_') {
                if (!saw_digit or previous_was_separator) {
                    return LexicalError.InvalidNumericSeparator;
                }

                previous_was_separator = true;
                _ = self.advance();
                continue;
            }

            if (!isDigitFn(c)) break;

            saw_digit = true;
            previous_was_separator = false;
            _ = self.advance();
        }

        if (previous_was_separator) {
            return LexicalError.InvalidNumericSeparator;
        }

        return saw_digit;
    }

    //#endregion

    //#region Strings

    fn scanString(self: *Scanner, start: TokenStart) LexicalError!Token {
        const quote = self.advance().?;
        var flags = TokenFlags{};

        while (!self.isAtEnd()) {
            const c = self.peek().?;

            if (c == quote) {
                _ = self.advance();
                return self.makeToken(start, .StringLiteral, flags);
            }

            if (tokens.isLineTerminator(c)) {
                flags.unterminated = true;
                return LexicalError.UnterminatedString;
            }

            if (c == '\\') {
                flags.has_escape = true;
                _ = self.advance();

                if (self.isAtEnd()) {
                    flags.unterminated = true;
                    return LexicalError.UnterminatedString;
                }

                // Consume escaped byte. Full escape validation belongs in the next pass.
                _ = self.advance();
                continue;
            }

            _ = self.advance();
        }

        flags.unterminated = true;
        return LexicalError.UnterminatedString;
    }

    //#endregion

    //#region Punctuators

    fn scanPunctuatorOrInvalid(self: *Scanner, start: TokenStart) LexicalError!Token {
        const slice = self.source[self.index..];

        if (tokens.matchPunctuator(slice)) |matched| {
            self.advanceN(matched.len);
            return self.makeToken(start, matched.kind, .{});
        }

        return LexicalError.UnknownCharacter;
    }

    //#endregion
};

pub fn scanAll(allocator: std.mem.Allocator, source: []const u8, collect_comments: bool) !ScanResult {
    var scanner = Scanner.init(source, .{
        .trivia_policy = if (collect_comments) .emit_comments else .skip,
    });

    var token_list: std.ArrayList(Token) = .empty;
    errdefer token_list.deinit(allocator);

    var comment_list: std.ArrayList(Comment) = .empty;
    errdefer comment_list.deinit(allocator);

    var diagnostic_list: std.ArrayList(diagnostics.Diagnostic) = .empty;
    errdefer diagnostic_list.deinit(allocator);

    var saw_eof = false;
    while (true) {
        const token = scanner.nextToken() catch |err| {
            const start = scanner.markStart();
            try diagnostic_list.append(allocator, .{
                .severity = .@"error",
                .code = diagnostics.lexicalErrorCode(err),
                .phase = .scanner,
                .message = diagnostics.lexicalErrorMessage(err),
                .span = scanner.makeSpan(start),
            });

            if (!scanner.isAtEnd()) {
                _ = scanner.advance();
            } else {
                break;
            }

            continue;
        };

        if (tokens.isCommentToken(token.kind)) {
            try comment_list.append(allocator, .{
                .kind = token.kind,
                .lexeme = token.lexeme,
                .span = token.span,
            });
            continue;
        }

        try token_list.append(allocator, token);
        if (token.kind == .EOF) {
            saw_eof = true;
            break;
        }
    }

    if (!saw_eof) {
        const start = scanner.markStart();
        try token_list.append(allocator, .{
            .kind = .EOF,
            .lexeme = source[scanner.index..scanner.index],
            .span = scanner.makeSpan(start),
            .flags = .{},
        });
    }

    return .{
        .tokens = try token_list.toOwnedSlice(allocator),
        .comments = try comment_list.toOwnedSlice(allocator),
        .diagnostics = try diagnostic_list.toOwnedSlice(allocator),
    };
}

//#region Tests

fn expectKinds(source: []const u8, expected: []const TokenType) !void {
    var scanner = Scanner.init(source, .{});

    for (expected) |kind| {
        const token = try scanner.nextToken();
        try std.testing.expectEqual(kind, token.kind);
    }
}

test "scanner handles basic variable declaration" {
    try expectKinds(
        "const x = 123;",
        &.{
            .Keyword_const,
            .Identifier,
            .Equal,
            .NumberLiteral,
            .Semicolon,
        },
    );
}

test "scanner classifies literals and contextual words correctly" {
    try expectKinds(
        "true false null undefined async require",
        &.{
            .TrueLiteral,
            .FalseLiteral,
            .NullLiteral,
            .Identifier,
            .Identifier,
            .Identifier,
        },
    );
}

test "scanner handles private identifiers" {
    try expectKinds(
        "class A { #value; }",
        &.{
            .Keyword_class,
            .Identifier,
            .LBrace,
            .PrivateIdentifier,
            .Semicolon,
            .RBrace,
        },
    );
}

test "scanner handles strings" {
    try expectKinds(
        "const s = \"hello\\nworld\";",
        &.{
            .Keyword_const,
            .Identifier,
            .Equal,
            .StringLiteral,
            .Semicolon,
        },
    );
}

test "scanner handles number forms" {
    try expectKinds(
        "1 1.5 .5 1e10 0xff 0b1010 0o755 123n",
        &.{
            .NumberLiteral,
            .NumberLiteral,
            .NumberLiteral,
            .NumberLiteral,
            .NumberLiteral,
            .NumberLiteral,
            .NumberLiteral,
            .BigIntLiteral,
        },
    );
}

test "scanner handles comments as skipped trivia by default" {
    try expectKinds(
        "const x = 1; // comment\nx++;",
        &.{
            .Keyword_const,
            .Identifier,
            .Equal,
            .NumberLiteral,
            .Semicolon,
            .Identifier,
            .PlusPlus,
            .Semicolon,
        },
    );
}

test "scanner can emit comments" {
    var scanner = Scanner.init(
        "const x = 1; // comment\n",
        .{ .trivia_policy = .emit_comments },
    );

    try std.testing.expectEqual(TokenType.Keyword_const, (try scanner.nextToken()).kind);
    try std.testing.expectEqual(TokenType.Identifier, (try scanner.nextToken()).kind);
    try std.testing.expectEqual(TokenType.Equal, (try scanner.nextToken()).kind);
    try std.testing.expectEqual(TokenType.NumberLiteral, (try scanner.nextToken()).kind);
    try std.testing.expectEqual(TokenType.Semicolon, (try scanner.nextToken()).kind);
    try std.testing.expectEqual(TokenType.LineComment, (try scanner.nextToken()).kind);
}

test "scanner marks leading line break" {
    var scanner = Scanner.init("a\nb", .{});

    const a = try scanner.nextToken();
    const b = try scanner.nextToken();

    try std.testing.expectEqual(TokenType.Identifier, a.kind);
    try std.testing.expect(!a.flags.has_leading_line_break);

    try std.testing.expectEqual(TokenType.Identifier, b.kind);
    try std.testing.expect(b.flags.has_leading_line_break);
}

test "scanner handles longest punctuators" {
    try expectKinds(
        "... >>>= === !== => ?. ??=",
        &.{
            .Spread,
            .GreaterThanGreaterThanGreaterThanEqual,
            .EqualsEqualsEquals,
            .ExclamationEqualsEquals,
            .EqualsGreaterThan,
            .QuestionDot,
            .QuestionQuestionEqual,
        },
    );
}

//#endregion
