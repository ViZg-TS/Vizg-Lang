const std = @import("std");
const tokens = @import("tokens.zig");
const unicode_identifiers = @import("unicode_identifiers.zig");

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
    allow_regexp: bool = true,
    template_depth: usize = 0,
    template_brace_depths: [64]usize = [_]usize{0} ** 64,
    last_token_start: ?TokenStart = null,

    pub fn init(source: []const u8, config: ScannerConfig) Scanner {
        return .{
            .source = source,
            .config = config,
        };
    }

    pub fn nextToken(self: *Scanner) LexicalError!Token {
        self.last_token_start = null;
        while (true) {
            if (self.isAtEnd()) {
                if (self.template_depth != 0) return LexicalError.UnterminatedTemplateString;
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
            if (self.template_depth != 0) return LexicalError.UnterminatedTemplateString;
            return self.makeCurrentToken(.EOF);
        }

        const c = self.peek().?;
        const start = self.markStart();
        self.last_token_start = start;

        if (try self.isIdentifierStartAtCurrent()) {
            return try self.scanIdentifier(start);
        }

        if (c == '#') {
            if (self.peekN(1)) |next| {
                if (next == '\\' or tokens.isAsciiIdentifierStart(next) or next >= 0x80) {
                    _ = self.advance();
                    if (try self.isIdentifierStartAtCurrent()) {
                        self.index = start.index;
                        self.line = start.line;
                        self.column = start.column;
                        return try self.scanPrivateIdentifier(start);
                    }
                    self.index = start.index;
                    self.line = start.line;
                    self.column = start.column;
                }
            }
        }

        if (tokens.isDecimalDigit(c) or (c == '.' and self.peekN(1) != null and tokens.isDecimalDigit(self.peekN(1).?))) {
            return self.scanNumber(start) catch |err| {
                self.consumeNumericErrorTail();
                return err;
            };
        }

        if (c == '`') {
            return try self.scanTemplateStart(start);
        }

        if (c == '}' and self.template_depth != 0) {
            const depth = &self.template_brace_depths[self.template_depth - 1];
            if (depth.* == 0) return try self.scanTemplateContinuation(start);
            depth.* -= 1;
        } else if (c == '{' and self.template_depth != 0) {
            self.template_brace_depths[self.template_depth - 1] += 1;
        }

        if (tokens.isQuote(c)) {
            return try self.scanString(start);
        }

        if (c == '/' and self.allow_regexp and self.peekN(1) != '=') {
            return try self.scanRegExp(start);
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
        if (kind != .EOL and kind != .EOF) self.allow_regexp = allowsRegExpAfter(kind);

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

    //#region RegExp Literals

    fn scanRegExp(self: *Scanner, start: TokenStart) LexicalError!Token {
        _ = self.advance(); // opening slash
        var in_class = false;

        while (!self.isAtEnd()) {
            const c = self.peek().?;
            if (tokens.isLineTerminator(c)) return LexicalError.UnterminatedRegExp;

            if (c == '\\') {
                _ = self.advance();
                if (self.isAtEnd() or tokens.isLineTerminator(self.peek().?)) return LexicalError.UnterminatedRegExp;
                _ = self.advance();
                continue;
            }

            if (c == '[') {
                in_class = true;
                _ = self.advance();
                continue;
            }
            if (c == ']' and in_class) {
                in_class = false;
                _ = self.advance();
                continue;
            }
            if (c == '/' and !in_class) {
                _ = self.advance();
                var flags = tokens.RegExpFlags{};
                while (self.peek()) |flag_char| {
                    if (!tokens.isAsciiIdentifierPart(flag_char)) break;
                    _ = self.advance();
                    const flag = tokens.regexpFlagFromChar(flag_char) orelse return LexicalError.InvalidRegExp;
                    if (flags.get(flag)) return LexicalError.InvalidRegExp;
                    flags.set(flag);
                }
                return self.makeToken(start, .RegExpLiteral, .{});
            }

            _ = self.advance();
        }

        return LexicalError.UnterminatedRegExp;
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

    const DecodedCodePoint = struct {
        value: u21,
        byte_len: usize,
        escaped: bool = false,
    };

    fn decodeCodePointAt(self: *const Scanner, index: usize) LexicalError!DecodedCodePoint {
        if (index >= self.source.len) return LexicalError.UnexpectedEndOfFile;
        const byte_len = std.unicode.utf8ByteSequenceLength(self.source[index]) catch return LexicalError.InvalidUtf8;
        if (byte_len > self.source.len - index) return LexicalError.InvalidUtf8;
        const value = std.unicode.utf8Decode(self.source[index .. index + byte_len]) catch return LexicalError.InvalidUtf8;
        return .{ .value = value, .byte_len = byte_len };
    }

    fn decodeIdentifierEscapeAt(self: *const Scanner, index: usize) LexicalError!DecodedCodePoint {
        if (index + 2 > self.source.len or self.source[index] != '\\' or self.source[index + 1] != 'u') {
            return LexicalError.InvalidEscapeSequence;
        }

        var cursor = index + 2;
        var value: u32 = 0;
        if (cursor < self.source.len and self.source[cursor] == '{') {
            cursor += 1;
            const digits_start = cursor;
            while (cursor < self.source.len and self.source[cursor] != '}') : (cursor += 1) {
                const digit: u32 = std.fmt.charToDigit(self.source[cursor], 16) catch return LexicalError.InvalidEscapeSequence;
                if (value > (0x10FFFF - digit) / 16) return LexicalError.InvalidEscapeSequence;
                value = value * 16 + digit;
            }
            if (cursor == digits_start or cursor >= self.source.len) return LexicalError.InvalidEscapeSequence;
            cursor += 1;
        } else {
            if (cursor + 4 > self.source.len) return LexicalError.InvalidEscapeSequence;
            for (self.source[cursor .. cursor + 4]) |byte| {
                const digit: u32 = std.fmt.charToDigit(byte, 16) catch return LexicalError.InvalidEscapeSequence;
                value = value * 16 + digit;
            }
            cursor += 4;
        }

        if (value > 0x10FFFF or (value >= 0xD800 and value <= 0xDFFF)) return LexicalError.InvalidEscapeSequence;
        return .{ .value = @intCast(value), .byte_len = cursor - index, .escaped = true };
    }

    fn identifierCodePointAtCurrent(self: *const Scanner) LexicalError!DecodedCodePoint {
        if (self.peekIs('\\')) return self.decodeIdentifierEscapeAt(self.index);
        return self.decodeCodePointAt(self.index);
    }

    fn isIdentifierStart(code_point: u21) bool {
        return code_point == '$' or code_point == '_' or unicode_identifiers.isIdStart(code_point);
    }

    fn isIdentifierContinue(code_point: u21) bool {
        return isIdentifierStart(code_point) or code_point == 0x200C or code_point == 0x200D or unicode_identifiers.isIdContinue(code_point);
    }

    fn isIdentifierStartAtCurrent(self: *const Scanner) LexicalError!bool {
        const decoded = try self.identifierCodePointAtCurrent();
        return isIdentifierStart(decoded.value);
    }

    fn scanIdentifier(self: *Scanner, start: TokenStart) LexicalError!Token {
        var has_escape = false;
        while (!self.isAtEnd()) {
            const decoded = try self.identifierCodePointAtCurrent();
            if (!isIdentifierContinue(decoded.value)) break;
            has_escape = has_escape or decoded.escaped;
            self.advanceN(decoded.byte_len);
        }

        const lexeme = self.source[start.index..self.index];
        const kind = if (has_escape) TokenType.Identifier else tokens.classifyIdentifier(lexeme);

        return self.makeToken(start, kind, .{ .has_escape = has_escape });
    }

    fn scanPrivateIdentifier(self: *Scanner, start: TokenStart) LexicalError!Token {
        // #
        _ = self.advance();

        var has_escape = false;
        while (!self.isAtEnd()) {
            const decoded = try self.identifierCodePointAtCurrent();
            if (!isIdentifierContinue(decoded.value)) break;
            has_escape = has_escape or decoded.escaped;
            self.advanceN(decoded.byte_len);
        }

        return self.makeToken(start, .PrivateIdentifier, .{ .has_escape = has_escape });
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

            try self.requireNumericBoundary();
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

                        try self.requireNumericBoundary();

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

                        try self.requireNumericBoundary();

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

                        try self.requireNumericBoundary();

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

        try self.requireNumericBoundary();

        return self.makeToken(start, if (is_bigint) .BigIntLiteral else .NumberLiteral, .{});
    }

    fn requireNumericBoundary(self: *Scanner) LexicalError!void {
        const c = self.peek() orelse return;
        if (tokens.isAsciiIdentifierPart(c) or c >= 0x80) {
            self.consumeNumericErrorTail();
            return LexicalError.InvalidNumberFormat;
        }
    }

    fn consumeNumericErrorTail(self: *Scanner) void {
        while (self.peek()) |c| {
            if (!(tokens.isAsciiIdentifierPart(c) or c >= 0x80)) break;
            _ = self.advance();
        }
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
                    // Backslash at EOF inside a string is an incomplete escape sequence.
                    flags.unterminated = true;
                    return LexicalError.InvalidEscapeSequence;
                }

                // Validate escape sequence inline. Only well-known JS/TS escapes accepted: backslash, quoted char, control chars, xNN (2 hex), uNNNN (4 hex v1). Anything else surfaces InvalidEscapeSequence rather than silently kept.
                const esc = self.peek().?;
                switch (esc) {
                    'n', 't', 'r', 'a', 'b', 'f', 'v' => {},
                    '\x27' => {}, // escaped single quote
                    '"' => {}, // escaped double-quote
                    '`' => {}, // escaped backtick
                    '\\' => {}, // escaped backslash itself
                    '\x30' => { // escape code 0: invalid when followed by another digit.
                        if (!self.isAtEnd() and self.peek().? >= '0' and self.peek().? <= '9') return LexicalError.InvalidEscapeSequence;
                    },
                    '\x78' => { // \xNN — require exactly 2 hex digits following 'x'.
                        const p1 = self.index + 1;
                        const p2 = self.index + 2;
                        if (p1 >= self.source.len) return LexicalError.InvalidEscapeSequence;
                        if (p2 >= self.source.len) return LexicalError.InvalidEscapeSequence;
                        if (!tokens.isHexDigit(self.source[p1])) return LexicalError.InvalidEscapeSequence;
                        if (!tokens.isHexDigit(self.source[p2])) return LexicalError.InvalidEscapeSequence;
                    },
                    '\x75' => { // \uNNNN — require exactly 4 hex digits following 'u' (v1 form).
                        var i: usize = 1;
                        while (i <= 4) : (i += 1) {
                            const pos = self.index + i;
                            if (pos >= self.source.len or !tokens.isHexDigit(self.source[pos])) return LexicalError.InvalidEscapeSequence;
                        }
                    },
                    else => {
                        if (std.ascii.isDigit(esc)) return LexicalError.InvalidEscapeSequence;
                        return LexicalError.InvalidEscapeSequence;
                    },
                }
                continue;
            }

            _ = self.advance();
        }

        flags.unterminated = true;
        return LexicalError.UnterminatedString;
    }

    //#endregion

    //#region Template Literals

    fn scanTemplateStart(self: *Scanner, start: TokenStart) LexicalError!Token {
        _ = self.advance(); // opening backtick
        return self.scanTemplateChunk(start, true);
    }

    fn scanTemplateContinuation(self: *Scanner, start: TokenStart) LexicalError!Token {
        _ = self.advance(); // interpolation-closing brace
        return self.scanTemplateChunk(start, false);
    }

    fn scanTemplateChunk(self: *Scanner, start: TokenStart, initial: bool) LexicalError!Token {
        var flags = TokenFlags{};

        while (!self.isAtEnd()) {
            const c = self.peek().?;

            if (c == '`') {
                _ = self.advance();
                if (!initial) self.template_depth -= 1;
                return self.makeToken(start, if (initial) .NoSubstitutionTemplate else .TemplateTail, flags);
            }

            if (c == '$' and self.peekN(1) == '{') {
                self.advanceN(2);
                if (initial) {
                    if (self.template_depth == self.template_brace_depths.len) return LexicalError.UnknownCharacter;
                    self.template_brace_depths[self.template_depth] = 0;
                    self.template_depth += 1;
                }
                return self.makeToken(start, if (initial) .TemplateHead else .TemplateMiddle, flags);
            }

            if (tokens.isLineTerminator(c)) {
                // Allow CR/LF inside a template when there is no closing backtick.
                // Unterminated diagnostic belongs to the line/phase policy; here we accept
                // it so single-line CLI output does not break on multi-line strings in source text.
                _ = self.advance();
                continue;
            }

            if (c == '\\') {
                flags.has_escape = true;
                _ = self.advance();

                if (self.isAtEnd()) {
                    // Backslash at EOF inside a template is an incomplete escape.
                    flags.unterminated = true;
                    return LexicalError.InvalidEscapeSequence;
                }

                // Same escape-sequence validation as string literals. In templates the backtick and dollar-sign
                // are also accepted because they delimit literal content and interpolation expressions; any other
                // unknown character after a backslash surfaces InvalidEscapeSequence rather than silently kept.
                const esc = self.peek().?;
                const escape_len: usize = switch (esc) {
                    'n', 't', 'r', 'a', 'b', 'f', 'v' => 1,
                    '\x27', '"', '`', '$', '\\', '\x30' => 1,
                    '\x78' => blk: { // \xNN — require exactly 2 hex digits following 'x'.
                        const p1 = self.index + 1;
                        const p2 = self.index + 2;
                        if (p1 >= self.source.len or !tokens.isHexDigit(self.source[p1])) return LexicalError.InvalidEscapeSequence;
                        if (p2 >= self.source.len or !tokens.isHexDigit(self.source[p2])) return LexicalError.InvalidEscapeSequence;
                        break :blk 3;
                    },
                    '\x75' => blk: { // \uNNNN — require exactly 4 hex digits following 'u' (v1 form).
                        var i: usize = 1;
                        while (i <= 4) : (i += 1) {
                            const pos = self.index + i;
                            if (pos >= self.source.len or !tokens.isHexDigit(self.source[pos])) return LexicalError.InvalidEscapeSequence;
                        }
                        break :blk 5;
                    },
                    else => return LexicalError.InvalidEscapeSequence,
                };
                self.advanceN(escape_len);
                continue;
            }

            _ = self.advance();
        }

        flags.unterminated = true;
        return LexicalError.UnterminatedTemplateString;
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

fn allowsRegExpAfter(kind: TokenType) bool {
    return switch (kind) {
        .Identifier,
        .PrivateIdentifier,
        .NumberLiteral,
        .BigIntLiteral,
        .StringLiteral,
        .RegExpLiteral,
        .TrueLiteral,
        .FalseLiteral,
        .NullLiteral,
        .NoSubstitutionTemplate,
        .TemplateTail,
        .Keyword_this,
        .Keyword_super,
        .RParen,
        .RBracket,
        .RBrace,
        .PlusPlus,
        .MinusMinus,
        => false,
        else => true,
    };
}

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

    if (!std.unicode.utf8ValidateSlice(source)) {
        while (!scanner.isAtEnd()) {
            const decoded = scanner.decodeCodePointAt(scanner.index) catch {
                const start = scanner.markStart();
                _ = scanner.advance();
                try diagnostic_list.append(allocator, .{
                    .severity = .@"error",
                    .code = .invalid_utf8,
                    .phase = .scanner,
                    .message = "invalid UTF-8 source text",
                    .span = scanner.makeSpan(start),
                });
                const eof_start = scanner.markStart();
                try token_list.append(allocator, scanner.makeToken(eof_start, .EOF, .{}));
                return .{
                    .tokens = try token_list.toOwnedSlice(allocator),
                    .comments = try comment_list.toOwnedSlice(allocator),
                    .diagnostics = try diagnostic_list.toOwnedSlice(allocator),
                };
            };
            scanner.advanceN(decoded.byte_len);
        }
        unreachable;
    }

    var saw_eof = false;
    while (true) {
        const token = scanner.nextToken() catch |err| {
            const start = scanner.last_token_start orelse scanner.markStart();
            try diagnostic_list.append(allocator, .{
                .severity = .@"error",
                .code = diagnostics.lexicalErrorCode(err),
                .phase = .scanner,
                .message = diagnostics.lexicalErrorMessage(err),
                .span = scanner.makeSpan(start),
            });

            if (scanner.index == start.index) {
                if (!scanner.isAtEnd()) {
                    _ = scanner.advance();
                } else {
                    break;
                }
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

test "scanner accepts ECMAScript Unicode identifiers" {
    const sources = [_][]const u8{
        "const café = 1;",
        "const 名称 = 2;",
        "const _value = 3;",
        "const $value = 4;",
    };
    for (sources) |source| {
        try expectKinds(source, &.{
            .Keyword_const,
            .Identifier,
            .Equal,
            .NumberLiteral,
            .Semicolon,
        });
    }
}

test "scanner accepts escaped identifier code points" {
    var scanner = Scanner.init("const \\u0061 = \\u{540D};", .{});
    try std.testing.expectEqual(TokenType.Keyword_const, (try scanner.nextToken()).kind);
    const ascii_escape = try scanner.nextToken();
    try std.testing.expectEqual(TokenType.Identifier, ascii_escape.kind);
    try std.testing.expect(ascii_escape.flags.has_escape);
    _ = try scanner.nextToken();
    const unicode_escape = try scanner.nextToken();
    try std.testing.expectEqual(TokenType.Identifier, unicode_escape.kind);
    try std.testing.expect(unicode_escape.flags.has_escape);
}

test "scanner applies Unicode continue rules without normalization" {
    var scanner = Scanner.init("cafe\u{0301} café a\u{200C}b", .{});
    const decomposed = try scanner.nextToken();
    const composed = try scanner.nextToken();
    const joiner = try scanner.nextToken();

    try std.testing.expectEqual(TokenType.Identifier, decomposed.kind);
    try std.testing.expectEqual(TokenType.Identifier, composed.kind);
    try std.testing.expectEqual(TokenType.Identifier, joiner.kind);
    try std.testing.expect(!std.mem.eql(u8, decomposed.lexeme, composed.lexeme));
}

test "scanner rejects invalid identifier starts and escapes" {
    var combining_start = Scanner.init("\u{0301}name", .{});
    try std.testing.expectError(LexicalError.UnknownCharacter, combining_start.nextToken());

    var escaped_combining_start = Scanner.init("\\u{301}name", .{});
    try std.testing.expectError(LexicalError.UnknownCharacter, escaped_combining_start.nextToken());

    var invalid_scalar = Scanner.init("\\u{110000}", .{});
    try std.testing.expectError(LexicalError.InvalidEscapeSequence, invalid_scalar.nextToken());
}

test "scanner rejects valid Unicode outside ID_Start" {
    var scanner = Scanner.init("const 😀 = 1;", .{});
    _ = try scanner.nextToken();
    try std.testing.expectError(LexicalError.UnknownCharacter, scanner.nextToken());
}

test "scanAll diagnoses invalid UTF-8 without panic" {
    const source = [_]u8{ 'c', 'o', 'n', 's', 't', ' ', 0xE2, 0x82 };
    const result = try scanAll(std.testing.allocator, &source, false);
    defer std.testing.allocator.free(result.tokens);
    defer std.testing.allocator.free(result.comments);
    defer std.testing.allocator.free(result.diagnostics);

    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqual(diagnostics.DiagnosticCode.invalid_utf8, result.diagnostics[0].code);
    try std.testing.expectEqual(@as(u32, 6), result.diagnostics[0].span.start);
    try std.testing.expectEqual(TokenType.EOF, result.tokens[result.tokens.len - 1].kind);
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

test "scanner preserves valid numeric literal metadata" {
    const source = "0xFF 0b1010 0o755 1_000_000 1.2e-3 123n 0xFFn";
    const expected_lexemes = [_][]const u8{
        "0xFF", "0b1010", "0o755", "1_000_000", "1.2e-3", "123n", "0xFFn",
    };
    const expected_kinds = [_]TokenType{
        .NumberLiteral, .NumberLiteral, .NumberLiteral, .NumberLiteral,
        .NumberLiteral, .BigIntLiteral, .BigIntLiteral,
    };
    var scanner = Scanner.init(source, .{});

    var previous_end: u32 = 0;
    for (expected_lexemes, expected_kinds) |lexeme, kind| {
        const token = try scanner.nextToken();
        try std.testing.expectEqual(kind, token.kind);
        try std.testing.expectEqualStrings(lexeme, token.lexeme);
        try std.testing.expectEqual(@as(u32, @intCast(lexeme.len)), token.span.end - token.span.start);
        try std.testing.expect(token.span.start >= previous_end);
        previous_end = token.span.end;
    }
    try std.testing.expectEqual(TokenType.EOF, (try scanner.nextToken()).kind);
}

test "scanAll reports stable diagnostics for malformed numeric literals" {
    const invalid = [_][]const u8{ "1__0", "1_", "0x", "0b2", "1e", "1e+" };

    for (invalid) |source| {
        const result = try scanAll(std.testing.allocator, source, false);
        defer std.testing.allocator.free(result.tokens);
        defer std.testing.allocator.free(result.comments);
        defer std.testing.allocator.free(result.diagnostics);

        try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
        try std.testing.expectEqual(diagnostics.DiagnosticCode.invalid_number, result.diagnostics[0].code);
        try std.testing.expectEqual(@as(u32, 0), result.diagnostics[0].span.start);
        try std.testing.expectEqual(@as(u32, @intCast(source.len)), result.diagnostics[0].span.end);
        try std.testing.expectEqual(@as(usize, 1), result.tokens.len);
        try std.testing.expectEqual(TokenType.EOF, result.tokens[0].kind);
    }
}

test "malformed numeric recovery preserves following tokens" {
    const result = try scanAll(std.testing.allocator, "0b2; 7", false);
    defer std.testing.allocator.free(result.tokens);
    defer std.testing.allocator.free(result.comments);
    defer std.testing.allocator.free(result.diagnostics);

    try std.testing.expectEqual(@as(usize, 1), result.diagnostics.len);
    try std.testing.expectEqual(@as(u32, 3), result.diagnostics[0].span.end);
    try std.testing.expectEqualSlices(TokenType, &.{ .Semicolon, .NumberLiteral, .EOF }, &.{
        result.tokens[0].kind, result.tokens[1].kind, result.tokens[2].kind,
    });
    try std.testing.expectEqualStrings("7", result.tokens[1].lexeme);
}

test "scanner tokenizes huge numeric literals without arithmetic overflow" {
    const huge_decimal = "99999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999999";
    var scanner = Scanner.init(huge_decimal ++ " " ++ huge_decimal ++ "n", .{});

    const number = try scanner.nextToken();
    const bigint = try scanner.nextToken();
    try std.testing.expectEqual(TokenType.NumberLiteral, number.kind);
    try std.testing.expectEqual(TokenType.BigIntLiteral, bigint.kind);
    try std.testing.expectEqual(huge_decimal.len, number.lexeme.len);
    try std.testing.expectEqual(huge_decimal.len + 1, bigint.lexeme.len);
}

test "scanner accepts valid escape sequences" {
    // \n (backslash + n) — lexer should not error.
    {
        const src = "const s = \"a\\nb\";";
        var scanner = Scanner.init(src, .{});
        _ = try scanner.nextToken(); // Keyword_const
        _ = try scanner.nextToken(); // Identifier
        _ = try scanner.nextToken(); // Equal
        const tok = try scanner.nextToken(); // StringLiteral — would fail with InvalidEscapeSequence if validation were broken.
        try std.testing.expectEqual(TokenType.StringLiteral, tok.kind);
        // Lexeme is raw source slice including surrounding quotes.
        try std.testing.expect(tok.lexeme.len == 6);
        try std.testing.expect(tok.lexeme[0] == '"');
        try std.testing.expect(tok.lexeme[tok.lexeme.len - 1] == '"');
    }
    // \\ (escaped backslash) — valid escape.
    {
        const src = "const s = \"a\\\\b\";";
        var scanner = Scanner.init(src, .{});
        _ = try scanner.nextToken();
        _ = try scanner.nextToken();
        _ = try scanner.nextToken();
        const tok = try scanner.nextToken();
        try std.testing.expectEqual(TokenType.StringLiteral, tok.kind);
        try std.testing.expect(tok.lexeme.len == 6); // lexeme includes surrounding quotes
    }
    // \x1b (valid two-hex-digit escape) — lexer should not error.
    {
        const src = "const s = \"a\\x1bb\";";
        var scanner = Scanner.init(src, .{});
        _ = try scanner.nextToken();
        _ = try scanner.nextToken();
        _ = try scanner.nextToken();
        const tok = try scanner.nextToken();
        try std.testing.expectEqual(TokenType.StringLiteral, tok.kind);
        try std.testing.expect(tok.lexeme.len == 8);
    }
    // \u0041 (valid four-hex-digit escape) — lexer should not error.
    {
        const src = "const s = \"a\\u0041b\";";
        var scanner = Scanner.init(src, .{});
        _ = try scanner.nextToken();
        _ = try scanner.nextToken();
        _ = try scanner.nextToken();
        const tok = try scanner.nextToken();
        try std.testing.expectEqual(TokenType.StringLiteral, tok.kind);
    }
}

test "scanner rejects invalid escape sequences" {
    // \x with only 1 hex digit provided: should fail with InvalidEscapeSequence.
    {
        const src = "const s = \"\\x1\";";
        var scanner = Scanner.init(src, .{});
        _ = try scanner.nextToken(); // Keyword_const
        _ = try scanner.nextToken(); // Identifier
        _ = try scanner.nextToken(); // Equal
        const tok = scanner.nextToken();
        try std.testing.expectError(LexicalError.InvalidEscapeSequence, tok);
    }
    // \x with non-hex letters: should fail.
    {
        const src = "const s = \"\\xZZ\";";
        var scanner = Scanner.init(src, .{});
        _ = try scanner.nextToken(); // Keyword_const
        _ = try scanner.nextToken(); // Identifier
        _ = try scanner.nextToken(); // Equal
        const tok = scanner.nextToken();
        try std.testing.expectError(LexicalError.InvalidEscapeSequence, tok);
    }
    // \u with only 1 hex digit (instead of required 4): should fail.
    {
        const src = "const s = \"\\u0\";";
        var scanner = Scanner.init(src, .{});
        _ = try scanner.nextToken(); // Keyword_const
        _ = try scanner.nextToken(); // Identifier
        _ = try scanner.nextToken(); // Equal
        const tok = scanner.nextToken();
        try std.testing.expectError(LexicalError.InvalidEscapeSequence, tok);
    }
}

test "scanner rejects trailing backslash before EOF" {
    // Backslash as last source character inside an open string.
    const src = "const s = \"hello\\";
    var scanner = Scanner.init(src, .{});
    _ = try scanner.nextToken(); // Keyword_const
    _ = try scanner.nextToken(); // Identifier
    _ = try scanner.nextToken(); // Equal
    const tok = scanner.nextToken();
    try std.testing.expectError(LexicalError.InvalidEscapeSequence, tok);
}

test "template accepts valid escapes" {
    var scanner = Scanner.init("const t = `a\\nb`;", .{});
    _ = try scanner.nextToken(); // Keyword_const
    _ = try scanner.nextToken(); // Identifier
    _ = try scanner.nextToken(); // Equal
    const tok = try scanner.nextToken(); // NoSubstitutionTemplate — would fail with InvalidEscapeSequence if broken.
    try std.testing.expectEqual(TokenType.NoSubstitutionTemplate, tok.kind);
    try std.testing.expectEqualStrings("`a\\nb`", tok.lexeme);
    try std.testing.expect(tok.flags.has_escape);
}

test "scanner preserves raw tagged template segment lexemes" {
    var scanner = Scanner.init("tag`<p>${name}</p>`", .{});
    _ = try scanner.nextToken();
    const head = try scanner.nextToken();
    _ = try scanner.nextToken();
    const tail = try scanner.nextToken();

    try std.testing.expectEqual(TokenType.TemplateHead, head.kind);
    try std.testing.expectEqualStrings("`<p>${", head.lexeme);
    try std.testing.expectEqual(TokenType.TemplateTail, tail.kind);
    try std.testing.expectEqualStrings("}</p>`", tail.lexeme);
}

test "template rejects invalid escape sequences" {
    // \x inside template: should fail LexicalError.InvalidEscapeSequence.
    var scanner = Scanner.init("const t = `\\x`;", .{});
    _ = try scanner.nextToken(); // Keyword_const
    _ = try scanner.nextToken(); // Identifier
    _ = try scanner.nextToken(); // Equal
    const tok = scanner.nextToken();
    try std.testing.expectError(LexicalError.InvalidEscapeSequence, tok);
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
