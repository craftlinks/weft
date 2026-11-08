//! Weft's language for Patchwork's editor: the token classes `signals.weft` is coloured by, from
//! Weft's own tokenizer, one line at a time (step 15).
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. One Tokenizer
//! The editor asks for a line's tokens one at a time (`patchwork.editor.language`, section 2);
//! this file asks Weft's tokenizer (`weft.lang.token.next`) and names each token's class, so the
//! colours and the compiler can never disagree about where a token ends. No Weft token crosses a
//! line, since a comment ends at its line's end and there are no strings, so the state is only
//! `normal`.
//!
//! ## 2. Classes
//! ```text
//! keyword      seed, start, cue, track, module, use first on a line; in and every anywhere
//! call         a name right before `(`, a primitive or a module
//! name         any other name: a declaration, a cue, a parameter, a word
//! number       a number, a time, or a frequency, with its unit
//! operator     = <- + - * ..
//! punctuation  ( ) [ ] , : .
//! comment      # to the end of the line
//! invalid      a byte that starts no token, a whole UTF-8 sequence, or a number with a bad unit
//! ```
//!
//! ## 3. TigerStyle Invariants
//! - Each token is at least one byte, and a scan never leaves its line.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const weft = @import("weft");
const token = weft.lang.token;

pub const State = enum(u8) { normal };

pub const Class = enum(u8) {
    keyword,
    call,
    name,
    number,
    operator,
    punctuation,
    comment,
    invalid,
};

pub const Token = patchwork.editor.Token(Class);

pub const palette: [8][4]f32 = .{
    .{ 0.78, 0.60, 0.95, 1 },
    .{ 0.47, 0.72, 0.98, 1 },
    .{ 0.86, 0.88, 0.92, 1 },
    .{ 0.96, 0.70, 0.42, 1 },
    .{ 0.62, 0.84, 0.86, 1 },
    .{ 0.56, 0.60, 0.68, 1 },
    .{ 0.48, 0.54, 0.60, 1 },
    .{ 0.95, 0.42, 0.42, 1 },
};

const line_keywords = [_][]const u8{ "seed", "start", "cue", "track", "module", "use" };

/// The next token of `line` at or after `at.*`, which advances past it; null at the line's end.
pub fn next(line: []const u8, at: *u32, state: *State) ?Token {
    assert(at.* <= line.len);
    assert(state.* == .normal);
    var index = at.*;
    while (index < line.len and line[index] <= ' ') index += 1;
    at.* = index;
    if (index == line.len) return null;
    const found = token.next(line, index);
    var end = found.start + found.len;
    if (found.tag == .invalid and line[index] >= 0x80) {
        while (end < line.len and line[end] & 0xc0 == 0x80) end += 1;
    }
    assert(end > index and end <= line.len);
    at.* = end;
    return .{ .start = index, .end = end, .class = class_of(line, index, end, found.tag) };
}

fn class_of(line: []const u8, start: u32, end: u32, tag: token.Tag) Class {
    return switch (tag) {
        .name => name: {
            const word = line[start..end];
            if (std.mem.eql(u8, word, "in") or std.mem.eql(u8, word, "every")) break :name .keyword;
            if (first_on_line(line, start)) {
                for (line_keywords) |keyword| {
                    if (std.mem.eql(u8, word, keyword)) break :name .keyword;
                }
            }
            var after = end;
            while (after < line.len and line[after] == ' ') after += 1;
            break :name if (after < line.len and line[after] == '(') .call else .name;
        },
        .number, .time, .frequency => .number,
        .equal, .feed, .plus, .minus, .star, .dot_dot => .operator,
        .comma, .colon, .dot, .l_paren, .r_paren, .l_bracket, .r_bracket => .punctuation,
        .comment => .comment,
        .bad_unit, .invalid => .invalid,
        .newline, .eof => unreachable,
    };
}

fn first_on_line(line: []const u8, start: u32) bool {
    for (line[0..start]) |byte| if (byte != ' ') return false;
    return true;
}

const testing = std.testing;

/// The classes of `line`'s tokens, in order.
fn classes(line: []const u8, out: []Class) []const Class {
    var at: u32 = 0;
    var state: State = .normal;
    var count: usize = 0;
    while (next(line, &at, &state)) |found| : (count += 1) out[count] = found.class;
    return out[0..count];
}

// Locks section 2 on lines of `signals.weft`: keywords first on a line, calls before `(`, names,
// numbers with their units, operators, punctuation, and a comment to the end of the line.
test "each token of a line has its class" {
    var out: [32]Class = undefined;
    try testing.expectEqualSlices(Class, &.{ .keyword, .name, .operator, .number, .keyword, .number, .operator, .number }, classes("track pulse_hz = 0.3 in 0.075..1.2", &out));
    try testing.expectEqualSlices(Class, &.{ .name, .operator, .call, .punctuation, .name, .punctuation, .number, .punctuation, .name, .punctuation, .number, .punctuation, .comment }, classes("noise = noise(smooth, 1hz, seed: 1) # a comment", &out));
    try testing.expectEqualSlices(Class, &.{ .keyword, .operator, .name, .comment }, classes("cue = c0 #… ×", &out));
    try testing.expectEqualSlices(Class, &.{ .name, .invalid, .invalid, .invalid }, classes("x × ? 3zz", &out));
}
