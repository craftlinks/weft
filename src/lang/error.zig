//! Diagnostics: an error on a span of the source, with a reason and, where one exists, a hint.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What an Error Holds
//! A `Diagnostic` is a code, a span of the source, a message, and a hint. The code is for tests
//! and tools, which match on it, and the message and hint are for people and agents, who read
//! them. Both texts live in the diagnostic, in fixed arrays, so a list of them needs no allocator
//! and outlives nothing. `render` prints one the way Zig prints its own:
//! ```text
//! signals.weft:14:22: error: chase has no parameter `tme`
//!     chase = chase(noise, tme: chase_s)
//!                          ^^^
//!     hint: did you mean `time`?
//! ```
//!
//! ## 2. Suggestions
//! `nearest` finds the candidate closest to a misspelt name by edit distance, and gives it only
//! when it is close: at most two edits, and fewer than the name's own length, so `x` does not
//! suggest `wave`.
//!
//! ## 3. TigerStyle Invariants
//! - A full list counts what it drops; nothing is written past it.
//! - A text that does not fit is cut at its array and ends with `...`.
//! - Edit distance runs on names of at most `name_len_max` bytes, in a fixed row.

const std = @import("std");
const assert = std.debug.assert;

pub const message_len_max = 120;
pub const hint_len_max = 96;
/// Longer names are never suggested, so the distance's row is fixed.
pub const name_len_max = 48;

pub const Code = enum(u8) {
    // Tokens and syntax.
    invalid_character,
    bad_unit,
    unexpected_token,
    expected_declaration,
    expected_value,
    too_deep,
    // Names and order.
    reserved_name,
    duplicate_name,
    unknown_name,
    used_before_declared,
    unknown_call,
    // Arguments.
    unknown_parameter,
    duplicate_argument,
    missing_argument,
    positional_after_named,
    too_many_positional,
    wrong_type,
    not_live,
    unknown_word,
    unknown_output,
    // Modules and libraries.
    not_a_parameter,
    module_cycle,
    unknown_library,
    // Values.
    not_whole_flicks,
    out_of_range,
    // Declarations.
    duplicate_setting,
    cue_out_of_order,
    bad_series,
    not_a_delay,
    delay_fed_twice,
    delay_not_fed,
    no_start_cue,
    // The back end and the limits.
    refused,
    limit,
};

pub const Diagnostic = struct {
    code: Code,
    start: u32,
    len: u32,
    message: [message_len_max]u8,
    message_len: u8,
    hint: [hint_len_max]u8,
    hint_len: u8,

    pub fn message_text(diagnostic: *const Diagnostic) []const u8 {
        return diagnostic.message[0..diagnostic.message_len];
    }

    pub fn hint_text(diagnostic: *const Diagnostic) []const u8 {
        return diagnostic.hint[0..diagnostic.hint_len];
    }

    /// Prints the diagnostic as section 1 shows, for a file called `name`.
    pub fn render(
        diagnostic: *const Diagnostic,
        source: []const u8,
        name: []const u8,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const place = locate(source, diagnostic.start);
        try writer.print("{s}:{d}:{d}: error: {s}\n", .{
            name,
            place.line,
            place.column,
            diagnostic.message_text(),
        });
        const line = source[place.line_start..place.line_end];
        try writer.print("    {s}\n    ", .{line});
        const column: u32 = place.column - 1;
        for (0..column) |_| try writer.writeByte(' ');
        const room = place.line_end - diagnostic.start;
        const carets = @max(1, @min(diagnostic.len, room));
        for (0..carets) |_| try writer.writeByte('^');
        try writer.writeByte('\n');
        if (diagnostic.hint_len > 0) try writer.print("    hint: {s}\n", .{diagnostic.hint_text()});
    }
};

pub const Place = struct {
    /// From 1.
    line: u32,
    /// From 1, in bytes.
    column: u32,
    line_start: u32,
    line_end: u32,
};

/// The line and column of byte `at`.
pub fn locate(source: []const u8, at: u32) Place {
    assert(at <= source.len);
    var line: u32 = 1;
    var line_start: u32 = 0;
    for (source[0..at], 0..) |byte, index| {
        if (byte == '\n') {
            line += 1;
            line_start = @intCast(index + 1);
        }
    }
    var line_end = at;
    while (line_end < source.len and source[line_end] != '\n') line_end += 1;
    return .{ .line = line, .column = at - line_start + 1, .line_start = line_start, .line_end = line_end };
}

/// A bounded list of diagnostics over caller memory.
pub const List = struct {
    entries: []Diagnostic,
    count: u32,
    /// Errors past the end of `entries`, counted and not kept.
    dropped: u32,

    pub fn init(entries: []Diagnostic) List {
        return .{ .entries = entries, .count = 0, .dropped = 0 };
    }

    pub fn items(list: *const List) []const Diagnostic {
        return list.entries[0..list.count];
    }

    pub fn total(list: *const List) u32 {
        return list.count + list.dropped;
    }

    /// Adds an error on `start` and `len` with a formatted message, and returns it so a caller
    /// can add a hint. A full list counts it and returns null.
    pub fn add(
        list: *List,
        code: Code,
        start: u32,
        len: u32,
        comptime format: []const u8,
        args: anytype,
    ) ?*Diagnostic {
        assert(list.count <= list.entries.len);
        if (list.count == list.entries.len) {
            list.dropped += 1;
            return null;
        }
        const diagnostic = &list.entries[list.count];
        list.count += 1;
        diagnostic.* = .{
            .code = code,
            .start = start,
            .len = len,
            .message = undefined,
            .message_len = 0,
            .hint = undefined,
            .hint_len = 0,
        };
        diagnostic.message_len = @intCast(print_cut(&diagnostic.message, format, args).len);
        return diagnostic;
    }
};

/// Sets the hint of `diagnostic`, if there is one.
pub fn hint(diagnostic: ?*Diagnostic, comptime format: []const u8, args: anytype) void {
    const target = diagnostic orelse return;
    target.hint_len = @intCast(print_cut(&target.hint, format, args).len);
}

/// Prints into `buffer`, cut with `...` where it does not fit.
fn print_cut(buffer: []u8, comptime format: []const u8, args: anytype) []const u8 {
    assert(buffer.len > 3);
    var writer: std.Io.Writer = .fixed(buffer);
    writer.print(format, args) catch {
        @memcpy(buffer[buffer.len - 3 ..], "...");
        return buffer;
    };
    return writer.buffered();
}

/// The candidate nearest to `name` by edit distance, if it is close enough (section 2).
pub fn nearest(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    if (name.len > name_len_max) return null;
    var best: ?[]const u8 = null;
    var best_distance: u32 = std.math.maxInt(u32);
    for (candidates) |candidate| {
        if (candidate.len > name_len_max) continue;
        if (std.mem.eql(u8, candidate, name)) continue;
        const distance = edit_distance(name, candidate);
        if (distance < best_distance) {
            best = candidate;
            best_distance = distance;
        }
    }
    if (best_distance > 2 or best_distance >= name.len) return null;
    return best;
}

/// The Levenshtein distance between two names of at most `name_len_max` bytes.
pub fn edit_distance(a: []const u8, b: []const u8) u32 {
    assert(a.len <= name_len_max);
    assert(b.len <= name_len_max);
    var row: [name_len_max + 1]u32 = undefined;
    for (0..b.len + 1) |j| row[j] = @intCast(j);
    for (a, 0..) |byte_a, i| {
        var diagonal = row[0];
        row[0] = @intCast(i + 1);
        for (b, 0..) |byte_b, j| {
            const above = row[j + 1];
            const cost: u32 = if (byte_a == byte_b) 0 else 1;
            row[j + 1] = @min(@min(above + 1, row[j] + 1), diagonal + cost);
            diagonal = above;
        }
    }
    return row[b.len];
}

const testing = std.testing;

// Locks the rendered form of section 1, with its caret under the span and its hint.
test "a diagnostic renders with its line, caret, and hint" {
    const source = "noise = noise(smooth, 1hz)\nchase = chase(noise, tme: 1s)\n";
    var entries: [2]Diagnostic = undefined;
    var list = List.init(&entries);
    const diagnostic = list.add(.unknown_parameter, 48, 3, "chase has no parameter `{s}`", .{"tme"});
    hint(diagnostic, "did you mean `{s}`?", .{"time"});
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try list.items()[0].render(source, "signals.weft", &writer);
    try testing.expectEqualStrings(
        \\signals.weft:2:22: error: chase has no parameter `tme`
        \\    chase = chase(noise, tme: 1s)
        \\                         ^^^
        \\    hint: did you mean `time`?
        \\
    , writer.buffered());
}

// Locks the bound: a full list counts the rest, and a long message is cut with `...`.
test "a full list counts what it drops" {
    var entries: [1]Diagnostic = undefined;
    var list = List.init(&entries);
    const long: [200]u8 = @splat('a');
    _ = list.add(.unknown_name, 0, 1, "{s}", .{&long});
    try testing.expect(std.mem.endsWith(u8, list.items()[0].message_text(), "..."));
    try testing.expectEqual(null, list.add(.unknown_name, 0, 1, "second", .{}));
    try testing.expectEqual(@as(u32, 2), list.total());
}

// Locks the suggestion rule of section 2.
test "the nearest name is suggested only when it is close" {
    const names = [_][]const u8{ "time", "overshoot", "from" };
    try testing.expectEqualStrings("time", nearest("tme", &names).?);
    try testing.expectEqualStrings("overshoot", nearest("overshot", &names).?);
    try testing.expectEqual(null, nearest("x", &names));
    try testing.expectEqual(null, nearest("velocity", &names));
    try testing.expectEqual(@as(u32, 3), edit_distance("kitten", "sitting"));
}
