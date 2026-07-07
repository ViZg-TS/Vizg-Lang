const std = @import("std");

//#region Token core

pub const TokenType = enum {
    Invalid,

    // Identifiers / names
    Identifier,
    PrivateIdentifier,

    // Literals
    NumberLiteral,
    BigIntLiteral,
    StringLiteral,
    RegExpLiteral,
    TrueLiteral,
    FalseLiteral,
    NullLiteral,

    // Template literals
    NoSubstitutionTemplate, // `...`
    TemplateHead, // `...${
    TemplateMiddle, // }...${
    TemplateTail, // }...`

    // Comments / trivia
    Shebang, // #! at start of file
    LineComment, // // ...
    BlockComment, // /* ... */

    // Hard ECMAScript keywords
    Keyword_await,
    Keyword_break,
    Keyword_case,
    Keyword_catch,
    Keyword_class,
    Keyword_const,
    Keyword_continue,
    Keyword_debugger,
    Keyword_default,
    Keyword_delete,
    Keyword_do,
    Keyword_else,
    Keyword_enum,
    Keyword_export,
    Keyword_extends,
    Keyword_finally,
    Keyword_for,
    Keyword_function,
    Keyword_if,
    Keyword_import,
    Keyword_in,
    Keyword_instanceof,
    Keyword_let,
    Keyword_new,
    Keyword_return,
    Keyword_super,
    Keyword_switch,
    Keyword_this,
    Keyword_throw,
    Keyword_try,
    Keyword_typeof,
    Keyword_var,
    Keyword_void,
    Keyword_while,
    Keyword_with,
    Keyword_yield,

    // Punctuators / operators
    Ampersand, // &
    AmpersandAmpersand, // &&
    AmpersandAmpersandEqual, // &&=
    AmpersandEqual, // &=

    Asterisk, // *
    AsteriskAsterisk, // **
    AsteriskAsteriskEqual, // **=
    AsteriskEqual, // *=

    At, // @
    Backtick, // `

    Bar, // |
    BarBar, // ||
    BarBarEqual, // ||=
    BarEqual, // |=
    BarGreaterThan, // |>

    Caret, // ^
    CaretEqual, // ^=

    Colon, // :
    Comma, // ,
    Dot, // .
    Spread, // ...
    Semicolon, // ;

    Equal, // =
    EqualsEquals, // ==
    EqualsEqualsEquals, // ===
    EqualsGreaterThan, // =>

    Exclamation, // !
    ExclamationEquals, // !=
    ExclamationEqualsEquals, // !==

    GreaterThan, // >
    GreaterThanEquals, // >=
    GreaterThanGreaterThan, // >>
    GreaterThanGreaterThanEqual, // >>=
    GreaterThanGreaterThanGreaterThan, // >>>
    GreaterThanGreaterThanGreaterThanEqual, // >>>=

    Hash, // #

    LessThan, // <
    LessThanEquals, // <=
    LessThanLessThan, // <<
    LessThanLessThanEqual, // <<=
    LessThanSlash, // </

    LBrace, // {
    LBracket, // [
    LParen, // (

    Minus, // -
    MinusEqual, // -=
    MinusMinus, // --

    Percent, // %
    PercentEqual, // %=

    Plus, // +
    PlusEqual, // +=
    PlusPlus, // ++

    Question, // ?
    QuestionDot, // ?.
    QuestionQuestion, // ??
    QuestionQuestionEqual, // ??=

    RBrace, // }
    RBracket, // ]
    RParen, // )

    Slash, // /
    SlashEqual, // /=

    Tilde, // ~

    EOL,
    EOF,
};

pub const Span = struct {
    start: u32,
    end: u32,
    line: u32,
    column: u32,

    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }
};

pub const TokenFlags = packed struct {
    has_leading_line_break: bool = false,
    has_escape: bool = false,
    unterminated: bool = false,
    synthetic: bool = false,
};

pub const Token = struct {
    kind: TokenType,
    span: Span,
    lexeme: []const u8,
    flags: TokenFlags = .{},

    pub fn init(kind: TokenType, lexeme: []const u8, span: Span) Token {
        return .{
            .kind = kind,
            .span = span,
            .lexeme = lexeme,
            .flags = .{},
        };
    }

    pub fn initWithFlags(kind: TokenType, lexeme: []const u8, span: Span, flags: TokenFlags) Token {
        return .{
            .kind = kind,
            .span = span,
            .lexeme = lexeme,
            .flags = flags,
        };
    }

    pub fn contextualKeyword(self: Token) ?ContextualKeyword {
        if (self.kind != .Identifier) return null;
        return findContextualKeyword(self.lexeme);
    }
};

pub const LexicalError = error{
    UnknownCharacter,
    UnterminatedComment,
    UnterminatedString,
    UnterminatedTemplateString,
    InvalidNumberFormat,
    InvalidExponent,
    InvalidNumericSeparator,
    InvalidEscapeSequence,
    InvalidRegExp,
    UnexpectedEndOfFile,
};

//#endregion

//#region Contextual keywords

pub const ContextualKeyword = enum {
    Contextual_abstract,
    Contextual_accessor,
    Contextual_any,
    Contextual_as,
    Contextual_assert,
    Contextual_asserts,
    Contextual_async,
    Contextual_bigint,
    Contextual_boolean,
    Contextual_constructor,
    Contextual_declare,
    Contextual_from,
    Contextual_get,
    Contextual_global,
    Contextual_implements,
    Contextual_infer,
    Contextual_interface,
    Contextual_intrinsic,
    Contextual_is,
    Contextual_keyof,
    Contextual_module,
    Contextual_namespace,
    Contextual_never,
    Contextual_number,
    Contextual_object,
    Contextual_of,
    Contextual_out,
    Contextual_override,
    Contextual_package,
    Contextual_private,
    Contextual_protected,
    Contextual_public,
    Contextual_readonly,
    Contextual_satisfies,
    Contextual_set,
    Contextual_static,
    Contextual_string,
    Contextual_symbol,
    Contextual_type,
    Contextual_undefined,
    Contextual_unique,
    Contextual_unknown,
    Contextual_using,
};

pub const ContextualKeywordEntry = struct {
    text: []const u8,
    keyword: ContextualKeyword,
};

pub const contextual_keyword_entries = [_]ContextualKeywordEntry{
    .{ .text = "abstract", .keyword = .Contextual_abstract },
    .{ .text = "accessor", .keyword = .Contextual_accessor },
    .{ .text = "any", .keyword = .Contextual_any },
    .{ .text = "as", .keyword = .Contextual_as },
    .{ .text = "assert", .keyword = .Contextual_assert },
    .{ .text = "asserts", .keyword = .Contextual_asserts },
    .{ .text = "async", .keyword = .Contextual_async },
    .{ .text = "bigint", .keyword = .Contextual_bigint },
    .{ .text = "boolean", .keyword = .Contextual_boolean },
    .{ .text = "constructor", .keyword = .Contextual_constructor },
    .{ .text = "declare", .keyword = .Contextual_declare },
    .{ .text = "from", .keyword = .Contextual_from },
    .{ .text = "get", .keyword = .Contextual_get },
    .{ .text = "global", .keyword = .Contextual_global },
    .{ .text = "implements", .keyword = .Contextual_implements },
    .{ .text = "infer", .keyword = .Contextual_infer },
    .{ .text = "interface", .keyword = .Contextual_interface },
    .{ .text = "intrinsic", .keyword = .Contextual_intrinsic },
    .{ .text = "is", .keyword = .Contextual_is },
    .{ .text = "keyof", .keyword = .Contextual_keyof },
    .{ .text = "module", .keyword = .Contextual_module },
    .{ .text = "namespace", .keyword = .Contextual_namespace },
    .{ .text = "never", .keyword = .Contextual_never },
    .{ .text = "number", .keyword = .Contextual_number },
    .{ .text = "object", .keyword = .Contextual_object },
    .{ .text = "of", .keyword = .Contextual_of },
    .{ .text = "out", .keyword = .Contextual_out },
    .{ .text = "override", .keyword = .Contextual_override },
    .{ .text = "package", .keyword = .Contextual_package },
    .{ .text = "private", .keyword = .Contextual_private },
    .{ .text = "protected", .keyword = .Contextual_protected },
    .{ .text = "public", .keyword = .Contextual_public },
    .{ .text = "readonly", .keyword = .Contextual_readonly },
    .{ .text = "satisfies", .keyword = .Contextual_satisfies },
    .{ .text = "set", .keyword = .Contextual_set },
    .{ .text = "static", .keyword = .Contextual_static },
    .{ .text = "string", .keyword = .Contextual_string },
    .{ .text = "symbol", .keyword = .Contextual_symbol },
    .{ .text = "type", .keyword = .Contextual_type },
    .{ .text = "undefined", .keyword = .Contextual_undefined },
    .{ .text = "unique", .keyword = .Contextual_unique },
    .{ .text = "unknown", .keyword = .Contextual_unknown },
    .{ .text = "using", .keyword = .Contextual_using },
};

pub fn findContextualKeyword(text: []const u8) ?ContextualKeyword {
    for (contextual_keyword_entries) |entry| {
        if (std.mem.eql(u8, text, entry.text)) {
            return entry.keyword;
        }
    }

    return null;
}

//#endregion

//#region Keywords / literals

pub const KeywordEntry = struct {
    text: []const u8,
    token: TokenType,
};

pub const keyword_entries = [_]KeywordEntry{
    .{ .text = "await", .token = .Keyword_await },
    .{ .text = "break", .token = .Keyword_break },
    .{ .text = "case", .token = .Keyword_case },
    .{ .text = "catch", .token = .Keyword_catch },
    .{ .text = "class", .token = .Keyword_class },
    .{ .text = "const", .token = .Keyword_const },
    .{ .text = "continue", .token = .Keyword_continue },
    .{ .text = "debugger", .token = .Keyword_debugger },
    .{ .text = "default", .token = .Keyword_default },
    .{ .text = "delete", .token = .Keyword_delete },
    .{ .text = "do", .token = .Keyword_do },
    .{ .text = "else", .token = .Keyword_else },
    .{ .text = "enum", .token = .Keyword_enum },
    .{ .text = "export", .token = .Keyword_export },
    .{ .text = "extends", .token = .Keyword_extends },
    .{ .text = "finally", .token = .Keyword_finally },
    .{ .text = "for", .token = .Keyword_for },
    .{ .text = "function", .token = .Keyword_function },
    .{ .text = "if", .token = .Keyword_if },
    .{ .text = "import", .token = .Keyword_import },
    .{ .text = "in", .token = .Keyword_in },
    .{ .text = "instanceof", .token = .Keyword_instanceof },
    .{ .text = "let", .token = .Keyword_let },
    .{ .text = "new", .token = .Keyword_new },
    .{ .text = "return", .token = .Keyword_return },
    .{ .text = "super", .token = .Keyword_super },
    .{ .text = "switch", .token = .Keyword_switch },
    .{ .text = "this", .token = .Keyword_this },
    .{ .text = "throw", .token = .Keyword_throw },
    .{ .text = "try", .token = .Keyword_try },
    .{ .text = "typeof", .token = .Keyword_typeof },
    .{ .text = "var", .token = .Keyword_var },
    .{ .text = "void", .token = .Keyword_void },
    .{ .text = "while", .token = .Keyword_while },
    .{ .text = "with", .token = .Keyword_with },
    .{ .text = "yield", .token = .Keyword_yield },
};

pub fn findKeyword(text: []const u8) ?TokenType {
    for (keyword_entries) |entry| {
        if (std.mem.eql(u8, text, entry.text)) {
            return entry.token;
        }
    }

    return null;
}

pub fn findLiteralWord(text: []const u8) ?TokenType {
    if (std.mem.eql(u8, text, "true")) return .TrueLiteral;
    if (std.mem.eql(u8, text, "false")) return .FalseLiteral;
    if (std.mem.eql(u8, text, "null")) return .NullLiteral;

    return null;
}

pub fn classifyIdentifier(text: []const u8) TokenType {
    if (findLiteralWord(text)) |literal| return literal;
    if (findKeyword(text)) |keyword| return keyword;

    return .Identifier;
}

//#endregion

//#region Punctuators

pub const PunctuatorEntry = struct {
    text: []const u8,
    token: TokenType,
};

pub const PunctuatorMatch = struct {
    kind: TokenType,
    len: u8,
};

/// Ordered by descending length.
/// Do not reorder casually. The scanner relies on longest-match behavior.
pub const punctuator_entries = [_]PunctuatorEntry{
    .{ .text = ">>>=", .token = .GreaterThanGreaterThanGreaterThanEqual },

    .{ .text = "===", .token = .EqualsEqualsEquals },
    .{ .text = "!==", .token = .ExclamationEqualsEquals },
    .{ .text = ">>>", .token = .GreaterThanGreaterThanGreaterThan },
    .{ .text = "<<=", .token = .LessThanLessThanEqual },
    .{ .text = ">>=", .token = .GreaterThanGreaterThanEqual },
    .{ .text = "&&=", .token = .AmpersandAmpersandEqual },
    .{ .text = "||=", .token = .BarBarEqual },
    .{ .text = "??=", .token = .QuestionQuestionEqual },
    .{ .text = "**=", .token = .AsteriskAsteriskEqual },
    .{ .text = "...", .token = .Spread },

    .{ .text = "=>", .token = .EqualsGreaterThan },
    .{ .text = "==", .token = .EqualsEquals },
    .{ .text = "!=", .token = .ExclamationEquals },
    .{ .text = ">=", .token = .GreaterThanEquals },
    .{ .text = "<=", .token = .LessThanEquals },
    .{ .text = "++", .token = .PlusPlus },
    .{ .text = "--", .token = .MinusMinus },
    .{ .text = "+=", .token = .PlusEqual },
    .{ .text = "-=", .token = .MinusEqual },
    .{ .text = "*=", .token = .AsteriskEqual },
    .{ .text = "/=", .token = .SlashEqual },
    .{ .text = "%=", .token = .PercentEqual },
    .{ .text = "&&", .token = .AmpersandAmpersand },
    .{ .text = "||", .token = .BarBar },
    .{ .text = "??", .token = .QuestionQuestion },
    .{ .text = "?.", .token = .QuestionDot },
    .{ .text = "**", .token = .AsteriskAsterisk },
    .{ .text = "<<", .token = .LessThanLessThan },
    .{ .text = ">>", .token = .GreaterThanGreaterThan },
    .{ .text = "</", .token = .LessThanSlash },
    .{ .text = "|>", .token = .BarGreaterThan },
    .{ .text = "&=", .token = .AmpersandEqual },
    .{ .text = "|=", .token = .BarEqual },
    .{ .text = "^=", .token = .CaretEqual },

    .{ .text = "(", .token = .LParen },
    .{ .text = ")", .token = .RParen },
    .{ .text = "{", .token = .LBrace },
    .{ .text = "}", .token = .RBrace },
    .{ .text = "[", .token = .LBracket },
    .{ .text = "]", .token = .RBracket },
    .{ .text = ":", .token = .Colon },
    .{ .text = ";", .token = .Semicolon },
    .{ .text = ",", .token = .Comma },
    .{ .text = ".", .token = .Dot },
    .{ .text = "&", .token = .Ampersand },
    .{ .text = "*", .token = .Asterisk },
    .{ .text = "|", .token = .Bar },
    .{ .text = "^", .token = .Caret },
    .{ .text = "=", .token = .Equal },
    .{ .text = "!", .token = .Exclamation },
    .{ .text = ">", .token = .GreaterThan },
    .{ .text = "<", .token = .LessThan },
    .{ .text = "#", .token = .Hash },
    .{ .text = "-", .token = .Minus },
    .{ .text = "%", .token = .Percent },
    .{ .text = "?", .token = .Question },
    .{ .text = "/", .token = .Slash },
    .{ .text = "~", .token = .Tilde },
    .{ .text = "+", .token = .Plus },
    .{ .text = "`", .token = .Backtick },
    .{ .text = "@", .token = .At },
};

pub fn matchPunctuator(source: []const u8) ?PunctuatorMatch {
    for (punctuator_entries) |entry| {
        if (std.mem.startsWith(u8, source, entry.text)) {
            return .{
                .kind = entry.token,
                .len = @intCast(entry.text.len),
            };
        }
    }

    return null;
}

//#endregion

//#region RegExp metadata

pub const RegExpFlag = enum {
    has_indices, // d
    global, // g
    ignore_case, // i
    multiline, // m
    dot_all, // s
    unicode, // u
    unicode_sets, // v
    sticky, // y
};

pub const RegExpFlags = packed struct {
    has_indices: bool = false,
    global: bool = false,
    ignore_case: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    unicode: bool = false,
    unicode_sets: bool = false,
    sticky: bool = false,

    pub fn get(self: RegExpFlags, flag: RegExpFlag) bool {
        return switch (flag) {
            .has_indices => self.has_indices,
            .global => self.global,
            .ignore_case => self.ignore_case,
            .multiline => self.multiline,
            .dot_all => self.dot_all,
            .unicode => self.unicode,
            .unicode_sets => self.unicode_sets,
            .sticky => self.sticky,
        };
    }

    pub fn set(self: *RegExpFlags, flag: RegExpFlag) void {
        switch (flag) {
            .has_indices => self.has_indices = true,
            .global => self.global = true,
            .ignore_case => self.ignore_case = true,
            .multiline => self.multiline = true,
            .dot_all => self.dot_all = true,
            .unicode => self.unicode = true,
            .unicode_sets => self.unicode_sets = true,
            .sticky => self.sticky = true,
        }
    }
};

pub const RegExpValue = struct {
    pattern: []const u8,
    flags: RegExpFlags,
};

pub fn regexpFlagFromChar(c: u8) ?RegExpFlag {
    return switch (c) {
        'd' => .has_indices,
        'g' => .global,
        'i' => .ignore_case,
        'm' => .multiline,
        's' => .dot_all,
        'u' => .unicode,
        'v' => .unicode_sets,
        'y' => .sticky,
        else => null,
    };
}

//#endregion

//#region Scanner-related policy

pub const TriviaPolicy = enum {
    skip,
    emit_comments,
};

//#endregion

//#region Character helpers

pub fn isAsciiIdentifierStart(c: u8) bool {
    return isAsciiAlpha(c) or c == '_' or c == '$';
}

pub fn isAsciiIdentifierPart(c: u8) bool {
    return isAsciiIdentifierStart(c) or isDecimalDigit(c);
}

pub fn isAsciiAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

pub fn isDecimalDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub fn isBinaryDigit(c: u8) bool {
    return c == '0' or c == '1';
}

pub fn isOctalDigit(c: u8) bool {
    return c >= '0' and c <= '7';
}

pub fn isHexDigit(c: u8) bool {
    return isDecimalDigit(c) or
        (c >= 'a' and c <= 'f') or
        (c >= 'A' and c <= 'F');
}

pub fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == 0x0B or c == 0x0C;
}

pub fn isLineTerminator(c: u8) bool {
    return c == '\n' or c == '\r';
}

pub fn isQuote(c: u8) bool {
    return c == '"' or c == 0x27;
}

pub fn isIdentifierLikeToken(kind: TokenType) bool {
    return kind == .Identifier or kind == .PrivateIdentifier;
}

pub fn isLiteralToken(kind: TokenType) bool {
    return switch (kind) {
        .NumberLiteral,
        .BigIntLiteral,
        .StringLiteral,
        .RegExpLiteral,
        .TrueLiteral,
        .FalseLiteral,
        .NullLiteral,
        .NoSubstitutionTemplate,
        => true,
        else => false,
    };
}

pub fn isCommentToken(kind: TokenType) bool {
    return switch (kind) {
        .Shebang,
        .LineComment,
        .BlockComment,
        => true,
        else => false,
    };
}

//#endregion

//#region Tests

test "classifyIdentifier distinguishes keywords, literals, contextual words, and identifiers" {
    try std.testing.expectEqual(TokenType.Keyword_return, classifyIdentifier("return"));
    try std.testing.expectEqual(TokenType.Keyword_class, classifyIdentifier("class"));

    try std.testing.expectEqual(TokenType.TrueLiteral, classifyIdentifier("true"));
    try std.testing.expectEqual(TokenType.FalseLiteral, classifyIdentifier("false"));
    try std.testing.expectEqual(TokenType.NullLiteral, classifyIdentifier("null"));

    try std.testing.expectEqual(TokenType.Identifier, classifyIdentifier("require"));
    try std.testing.expectEqual(TokenType.Identifier, classifyIdentifier("undefined"));
    try std.testing.expectEqual(TokenType.Identifier, classifyIdentifier("async"));

    try std.testing.expect(findContextualKeyword("async") != null);
    try std.testing.expect(findContextualKeyword("undefined") != null);
    try std.testing.expect(findContextualKeyword("require") == null);
}

test "matchPunctuator uses longest match" {
    {
        const matched = matchPunctuator("...") orelse unreachable;
        try std.testing.expectEqual(TokenType.Spread, matched.kind);
        try std.testing.expectEqual(@as(u8, 3), matched.len);
    }

    {
        const matched = matchPunctuator(">>>=") orelse unreachable;
        try std.testing.expectEqual(TokenType.GreaterThanGreaterThanGreaterThanEqual, matched.kind);
        try std.testing.expectEqual(@as(u8, 4), matched.len);
    }

    {
        const matched = matchPunctuator("=>") orelse unreachable;
        try std.testing.expectEqual(TokenType.EqualsGreaterThan, matched.kind);
        try std.testing.expectEqual(@as(u8, 2), matched.len);
    }

    {
        const matched = matchPunctuator("?.") orelse unreachable;
        try std.testing.expectEqual(TokenType.QuestionDot, matched.kind);
        try std.testing.expectEqual(@as(u8, 2), matched.len);
    }

    {
        const matched = matchPunctuator("??=") orelse unreachable;
        try std.testing.expectEqual(TokenType.QuestionQuestionEqual, matched.kind);
        try std.testing.expectEqual(@as(u8, 3), matched.len);
    }
}

test "character helpers" {
    try std.testing.expect(isAsciiIdentifierStart('_'));
    try std.testing.expect(isAsciiIdentifierStart('$'));
    try std.testing.expect(isAsciiIdentifierStart('a'));
    try std.testing.expect(isAsciiIdentifierStart('Z'));

    try std.testing.expect(!isAsciiIdentifierStart('1'));
    try std.testing.expect(isAsciiIdentifierPart('1'));

    try std.testing.expect(isWhitespace(' '));
    try std.testing.expect(isWhitespace('\t'));
    try std.testing.expect(isWhitespace(0x0B));
    try std.testing.expect(isWhitespace(0x0C));

    try std.testing.expect(isLineTerminator('\n'));
    try std.testing.expect(isLineTerminator('\r'));

    try std.testing.expect(isHexDigit('f'));
    try std.testing.expect(isHexDigit('F'));
    try std.testing.expect(isHexDigit('9'));
    try std.testing.expect(!isHexDigit('g'));
}

test "regexp flags" {
    var flags = RegExpFlags{};

    const global_flag = regexpFlagFromChar('g') orelse unreachable;
    const unicode_flag = regexpFlagFromChar('u') orelse unreachable;

    try std.testing.expect(!flags.get(.global));
    try std.testing.expect(!flags.get(.unicode));

    flags.set(global_flag);
    flags.set(unicode_flag);

    try std.testing.expect(flags.get(.global));
    try std.testing.expect(flags.get(.unicode));
    try std.testing.expect(regexpFlagFromChar('x') == null);
}

//#endregion
