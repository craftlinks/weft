//! The tokenizer: source bytes to a bounded array of tokens, each a tag and a span.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Tokens Are Spans
//! A token holds no text, only where its text is: `start` and `len` into the source. So the token
//! array is the whole lexical view of a file, comments included, and the formatter reads comments
//! and blank lines from it rather than from the tree (`format.zig`).
//!
//! ## 2. Literals Carry Their Unit
//! A number is digits, an optional fraction, and an optional exponent. Letters right after it are
//! its unit, and the unit decides the tag: `2s` and `500ms` are times, `0.5hz` a frequency, `0.5`
//! a number. Any other letters make a `bad_unit` token, so `2sec` is one error with a suggestion,
//! not a number followed by a name. A `.` only continues a number when a digit follows it, so
//! `0..1` is a number, `..`, and a number.
//!
//! ## 3. Keywords Are Names
//! `seed`, `start`, `cue`, and `track` are names here. The parser gives them their meaning at the
//! start of a line, and `in` and `every` only in their place in a declaration, so `ease: in` stays
//! a word.
//!
//! ## 4. TigerStyle Invariants
//! - One pass over the source, at most one token per byte, and the last token is always `eof`.
//! - A full token array stops the pass and says so; nothing is written past it.

const std = @import("std");
const assert = std.debug.assert;

pub const Tag = enum(u8) {
    name,
    number,
    time,
    frequency,
    /// A number followed by letters that are not a unit.
    bad_unit,
    equal,
    /// `<-`, which feeds a delay.
    feed,
    comma,
    colon,
    dot,
    dot_dot,
    plus,
    minus,
    star,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    newline,
    /// From `#` to the end of the line, without the newline.
    comment,
    /// A byte that starts no token.
    invalid,
    eof,
};

pub const Token = struct {
    tag: Tag,
    start: u32,
    len: u32,

    pub fn text(token: Token, source: []const u8) []const u8 {
        return source[token.start..][0..token.len];
    }
};

/// The units a literal can carry, and the tag each gives.
pub const Unit = enum { none, s, ms, hz };

/// The unit of a literal token: the letters at its end.
pub fn unit_of(token: Token, source: []const u8) Unit {
    const bytes = token.text(source);
    if (std.mem.endsWith(u8, bytes, "ms")) return .ms;
    if (std.mem.endsWith(u8, bytes, "hz")) return .hz;
    if (std.mem.endsWith(u8, bytes, "s")) return .s;
    return .none;
}

/// The digits of a literal token, without its unit.
pub fn digits_of(token: Token, source: []const u8) []const u8 {
    const bytes = token.text(source);
    const unit_len: usize = switch (unit_of(token, source)) {
        .none => 0,
        .s => 1,
        .ms, .hz => 2,
    };
    if (token.tag == .bad_unit) {
        var end: usize = 0;
        while (end < bytes.len and !std.ascii.isAlphabetic(bytes[end])) end += 1;
        return bytes[0..end];
    }
    return bytes[0 .. bytes.len - unit_len];
}

pub const Result = struct {
    count: u32,
    /// The array was full before the source ended. The last token is still `eof`.
    full: bool,
};

/// Fills `out` with the tokens of `source`, ending with `eof`.
pub fn tokenize(source: []const u8, out: []Token) Result {
    assert(out.len >= 1);
    assert(source.len < std.math.maxInt(u32));
    var count: u32 = 0;
    var index: u32 = 0;
    const end: u32 = @intCast(source.len);
    while (index < end) {
        const byte = source[index];
        if (byte == ' ' or byte == '\t' or byte == '\r') {
            index += 1;
            continue;
        }
        if (count + 1 >= out.len) {
            out[count] = .{ .tag = .eof, .start = index, .len = 0 };
            return .{ .count = count + 1, .full = true };
        }
        const token = next(source, index);
        assert(token.len > 0);
        assert(token.start == index);
        out[count] = token;
        count += 1;
        index += token.len;
    }
    out[count] = .{ .tag = .eof, .start = end, .len = 0 };
    return .{ .count = count + 1, .full = false };
}

fn next(source: []const u8, start: u32) Token {
    const byte = source[start];
    const rest = source[start..];
    const one: Tag = switch (byte) {
        '\n' => .newline,
        '=' => .equal,
        ',' => .comma,
        ':' => .colon,
        '+' => .plus,
        '*' => .star,
        '(' => .l_paren,
        ')' => .r_paren,
        '[' => .l_bracket,
        ']' => .r_bracket,
        else => .invalid,
    };
    if (one != .invalid) return .{ .tag = one, .start = start, .len = 1 };
    if (byte == '-') return .{ .tag = .minus, .start = start, .len = 1 };
    if (byte == '<') {
        if (rest.len > 1 and rest[1] == '-') return .{ .tag = .feed, .start = start, .len = 2 };
        return .{ .tag = .invalid, .start = start, .len = 1 };
    }
    if (byte == '.') {
        if (rest.len > 1 and rest[1] == '.') return .{ .tag = .dot_dot, .start = start, .len = 2 };
        return .{ .tag = .dot, .start = start, .len = 1 };
    }
    if (byte == '#') {
        var len: u32 = 1;
        while (len < rest.len and rest[len] != '\n') len += 1;
        return .{ .tag = .comment, .start = start, .len = len };
    }
    if (std.ascii.isAlphabetic(byte) or byte == '_') {
        var len: u32 = 1;
        while (len < rest.len and is_name_byte(rest[len])) len += 1;
        return .{ .tag = .name, .start = start, .len = len };
    }
    if (std.ascii.isDigit(byte)) return literal(rest, start);
    // A byte that starts no token: one byte, or a whole UTF-8 sequence, so an error points at a
    // character and not at half of one.
    var len: u32 = 1;
    while (len < rest.len and len < 4 and (rest[len] & 0xc0) == 0x80) len += 1;
    return .{ .tag = .invalid, .start = start, .len = len };
}

fn is_name_byte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn literal(rest: []const u8, start: u32) Token {
    var len: u32 = digits(rest, 0);
    if (len + 1 < rest.len and rest[len] == '.' and std.ascii.isDigit(rest[len + 1])) {
        len = digits(rest, len + 1);
    }
    if (len < rest.len and (rest[len] == 'e' or rest[len] == 'E')) {
        var at = len + 1;
        if (at < rest.len and (rest[at] == '+' or rest[at] == '-')) at += 1;
        if (at < rest.len and std.ascii.isDigit(rest[at])) len = digits(rest, at);
    }
    const number_len = len;
    while (len < rest.len and is_name_byte(rest[len])) len += 1;
    const unit = rest[number_len..len];
    const tag: Tag = if (unit.len == 0)
        .number
    else if (std.mem.eql(u8, unit, "s") or std.mem.eql(u8, unit, "ms"))
        .time
    else if (std.mem.eql(u8, unit, "hz"))
        .frequency
    else
        .bad_unit;
    return .{ .tag = tag, .start = start, .len = len };
}

fn digits(rest: []const u8, from: u32) u32 {
    var len = from;
    while (len < rest.len and std.ascii.isDigit(rest[len])) len += 1;
    return len;
}

const testing = std.testing;

fn tags_of(source: []const u8, out: []Tag) []const Tag {
    var tokens: [64]Token = undefined;
    const result = tokenize(source, &tokens);
    assert(!result.full);
    for (tokens[0..result.count], 0..) |token, index| out[index] = token.tag;
    return out[0..result.count];
}

// Locks each literal's tag by its unit, and that `..` between numbers is not a fraction.
test "a literal's unit decides its tag" {
    var tags: [64]Tag = undefined;
    try testing.expectEqualSlices(Tag, &.{ .time, .time, .frequency, .number, .bad_unit, .eof }, tags_of(
        "2s 500ms 0.5hz 1.5e3 2sec",
        &tags,
    ));
    try testing.expectEqualSlices(Tag, &.{ .number, .dot_dot, .minus, .number, .eof }, tags_of(
        "0..-1",
        &tags,
    ));
    try testing.expectEqualSlices(Tag, &.{ .time, .dot_dot, .time, .eof }, tags_of(
        "0s..500ms",
        &tags,
    ));
}

// Locks the punctuation, a comment that stops at the newline, and an invalid byte.
test "punctuation, comments, and invalid bytes" {
    var tags: [64]Tag = undefined;
    try testing.expectEqualSlices(Tag, &.{
        .name, .feed, .name, .l_paren, .r_paren, .comment, .newline, .invalid, .name, .eof,
    }, tags_of("fb <- f() # note\n$x", &tags));
    var tokens: [8]Token = undefined;
    const result = tokenize("a # é", &tokens);
    try testing.expectEqualStrings("# é", tokens[1].text("a # é"));
    try testing.expectEqual(@as(u32, 3), result.count);
}

// Locks the bound: a full array ends with `eof` and says it is full.
test "a full token array stops at eof" {
    var tokens: [3]Token = undefined;
    const result = tokenize("a b c d", &tokens);
    try testing.expect(result.full);
    try testing.expectEqual(@as(u32, 3), result.count);
    try testing.expectEqual(Tag.eof, tokens[2].tag);
}

// Locks `digits_of` and `unit_of` on each kind of literal.
test "a literal splits into digits and a unit" {
    const source = "2.5ms 7hz 3 4sec";
    var tokens: [8]Token = undefined;
    _ = tokenize(source, &tokens);
    try testing.expectEqualStrings("2.5", digits_of(tokens[0], source));
    try testing.expectEqual(Unit.ms, unit_of(tokens[0], source));
    try testing.expectEqualStrings("7", digits_of(tokens[1], source));
    try testing.expectEqual(Unit.hz, unit_of(tokens[1], source));
    try testing.expectEqual(Unit.none, unit_of(tokens[2], source));
    try testing.expectEqualStrings("4", digits_of(tokens[3], source));
}
