//! The formatter: a parsed file back to text, in the one canonical format.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Format
//! - One declaration a line, and at most one blank line between two; none at the start or end.
//! - `name = value`, `a + b`, `a / b`, `-x`, `name: value`, `[a, b]`, `a..b`, `f(a, b)`.
//! - Nothing is lined up, so renaming one line never moves another.
//! - A call or a list whose last item has a trailing comma, or with a comment among its items, is
//!   written one item a line, four spaces in, each with its comma. Any other stays on one line.
//!   There is no automatic wrapping, as in `zig fmt`.
//! - A call's named arguments follow its entry's order in the table of primitives. A comment
//!   among them moves with the argument after it, and one at the end of an argument's line stays
//!   on it.
//! - Comments keep their text, and a comment after code is one space after it.
//! - Literals keep their spelling: `0.50` stays `0.50`.
//!
//! ## 2. Comments Come From the Tokens
//! The tree has no comments. Every item knows its first and last token, so the comments before a
//! declaration, after it on its line, and between a call's items are the comment tokens in those
//! gaps. A comment anywhere else, such as between the operands of a sum in parentheses, has no
//! place in the format, so `format` refuses the file rather than lose it.
//!
//! ## 3. Round Trip
//! A canonical file formats to its own bytes, and formatting is idempotent, which the tests and
//! the fuzz test of `lang.zig` check.
//!
//! ## 4. TigerStyle Invariants
//! - Output goes to the caller's buffer; one that is too small is an error, not a cut.
//! - The recursion follows the tree, whose depth the parser bounds.

const std = @import("std");
const assert = std.debug.assert;
const parse_module = @import("parse.zig");
const Tree = parse_module.Tree;
const Tag = parse_module.Tag;
const schema = @import("schema.zig");
const params_max = schema.params_max;

pub const Error = error{
    /// The buffer is too small for the formatted file.
    NoSpace,
    /// A comment that the format has no place for (section 2).
    CommentPlacement,
};

const indent_width = 4;
/// Items of one call or list the formatter orders at once.
const items_max = 256;

const Formatter = struct {
    tree: *const Tree,
    writer: std.Io.Writer,
    comments_written: u32 = 0,

    fn write(formatter: *Formatter, bytes: []const u8) Error!void {
        formatter.writer.writeAll(bytes) catch return error.NoSpace;
    }

    fn newline(formatter: *Formatter, indent: u32) Error!void {
        try formatter.write("\n");
        for (0..indent) |_| try formatter.write(" ");
    }

    fn comment(formatter: *Formatter, token: u32) Error!void {
        const text = std.mem.trimEnd(u8, formatter.tree.token_text(token), " \t\r");
        try formatter.write(text);
        formatter.comments_written += 1;
    }

    fn tag_of(formatter: *const Formatter, token: u32) parse_module.TokenTag {
        return formatter.tree.tokens[token].tag;
    }

    fn declaration(formatter: *Formatter, index: u32) Error!void {
        const tree = formatter.tree;
        const item = tree.item(index);
        const name = tree.token_text(item.token);
        switch (item.tag) {
            .seed => {
                try formatter.write("seed ");
                try formatter.write(name);
            },
            .start => {
                try formatter.write("start ");
                try formatter.write(name);
            },
            .cue => {
                try formatter.write("cue ");
                try formatter.write(name);
                try formatter.write(" = ");
                try formatter.value(item.a, 0, .signal);
            },
            .cue_series => {
                try formatter.write("cue ");
                try formatter.write(name);
                try formatter.write(" = ");
                try formatter.value(item.a, 0, .signal);
                try formatter.write("..");
                try formatter.value(tree.extra[item.b], 0, .signal);
                try formatter.write(" every ");
                try formatter.value(tree.extra[item.b + 1], 0, .signal);
            },
            .track => {
                try formatter.write("track ");
                try formatter.write(name);
                try formatter.write(" = ");
                try formatter.value(item.a, 0, .signal);
                try formatter.write(" in ");
                try formatter.value(item.b, 0, .signal);
            },
            .use => {
                try formatter.write("use ");
                try formatter.write(name);
            },
            .module => {
                try formatter.write("module ");
                try formatter.write(name);
                try formatter.write("(");
                for (tree.children(item.a), 0..) |child, at| {
                    if (at > 0) try formatter.write(", ");
                    const param = tree.item(child);
                    try formatter.write(tree.token_text(param.token));
                    if (param.a != 0) {
                        try formatter.write(": ");
                        try formatter.value(param.a - 1, 0, .signal);
                    }
                }
                try formatter.write(")");
                if (item.c != 0) {
                    try formatter.write(" in ");
                    try formatter.value(item.c - 1, 0, .signal);
                }
                try formatter.write(" = ");
                try formatter.value(item.b, 0, .signal);
            },
            .bind, .feed => {
                try formatter.write(name);
                try formatter.write(if (item.tag == .bind) " = " else " <- ");
                try formatter.value(item.a, 0, .signal);
            },
            else => unreachable,
        }
    }

    fn value(formatter: *Formatter, index: u32, indent: u32, role: schema.Role) Error!void {
        const tree = formatter.tree;
        const item = tree.item(index);
        switch (item.tag) {
            .literal => {
                if (item.a == 1) try formatter.write("-");
                try formatter.write(tree.token_text(item.token));
            },
            .name => try formatter.write(tree.token_text(item.token)),
            .call => try formatter.items(index, indent, role),
            .list => try formatter.items(index, indent, .signal),
            .named => {
                const name = tree.token_text(item.token);
                try formatter.write(name);
                try formatter.write(": ");
                const inner: schema.Role = if (std.mem.eql(u8, name, "by")) .mover else .signal;
                try formatter.value(item.a, indent, inner);
            },
            .goal => {
                try formatter.value(item.a, indent, .signal);
                try formatter.write(": ");
                try formatter.value(item.b, indent, .signal);
            },
            .range => {
                try formatter.value(item.a, indent, .signal);
                try formatter.write("..");
                try formatter.value(item.b, indent, .signal);
            },
            .add, .subtract, .multiply, .divide => {
                try formatter.value(item.a, indent, .signal);
                try formatter.write(switch (item.tag) {
                    .add => " + ",
                    .subtract => " - ",
                    .multiply => " * ",
                    else => " / ",
                });
                try formatter.value(item.b, indent, .signal);
            },
            .negate => {
                try formatter.write("-");
                try formatter.value(item.a, indent, .signal);
            },
            .output => {
                try formatter.value(item.a, indent, .signal);
                try formatter.write(".");
                try formatter.write(tree.token_text(item.token));
            },
            .element => {
                try formatter.value(item.a, indent, .signal);
                try formatter.write("[");
                try formatter.write(tree.token_text(item.token));
                try formatter.write("]");
            },
            .paren => {
                try formatter.write("(");
                try formatter.value(item.a, indent, .signal);
                try formatter.write(")");
            },
            else => unreachable,
        }
    }

    /// A call or a list: its items in order (section 1), on one line or one a line.
    fn items(formatter: *Formatter, index: u32, indent: u32, role: schema.Role) Error!void {
        const tree = formatter.tree;
        const item = tree.item(index);
        const children = tree.children(index);
        if (children.len > items_max) return error.CommentPlacement;
        var order_buffer: [items_max]u32 = undefined;
        const order = order_buffer[0..children.len];
        for (order, 0..) |*slot, at| slot.* = @intCast(at);
        if (item.tag == .call) order_arguments(tree, item, children, order, role);
        const open: u32 = if (item.tag == .call) item.token + 1 else item.token;
        const close = item.last;
        if (item.tag == .call) try formatter.write(tree.token_text(item.token));
        try formatter.write(if (item.tag == .call) "(" else "[");
        var before_close = close - 1;
        while (formatter.tag_of(before_close) == .newline or formatter.tag_of(before_close) == .comment) before_close -= 1;
        const trailing_comma = children.len > 0 and formatter.tag_of(before_close) == .comma;
        const multiline = trailing_comma or formatter.has_direct_comment(open, close, children);
        if (!multiline) {
            for (order, 0..) |at, position| {
                if (position > 0) try formatter.write(", ");
                try formatter.value(children[at], indent, role);
            }
            try formatter.write(if (item.tag == .call) ")" else "]");
            return;
        }
        const inner = indent + indent_width;
        for (order) |at| {
            const child = tree.item(children[at]);
            const gap_start = if (at == 0) open + 1 else tree.item(children[at - 1]).last + 1;
            try formatter.leading_comments(gap_start, child.first, inner);
            try formatter.newline(inner);
            try formatter.value(children[at], inner, role);
            try formatter.write(",");
            if (formatter.trailing_comment(child.last + 1, close)) |token| {
                try formatter.write(" ");
                try formatter.comment(token);
            }
        }
        const last_child = tree.item(children[children.len - 1]);
        try formatter.leading_comments(last_child.last + 1, close, inner);
        try formatter.newline(indent);
        try formatter.write(if (item.tag == .call) ")" else "]");
    }

    /// Whether a comment sits among the items of a call or a list, outside every item.
    fn has_direct_comment(formatter: *const Formatter, open: u32, close: u32, children: []const u32) bool {
        var token = open + 1;
        var child: usize = 0;
        while (token < close) {
            if (child < children.len and token == formatter.tree.item(children[child]).first) {
                token = formatter.tree.item(children[child]).last + 1;
                child += 1;
                continue;
            }
            if (formatter.tag_of(token) == .comment) return true;
            token += 1;
        }
        return false;
    }

    /// The comment on the same line after an item, past its comma, if there is one.
    fn trailing_comment(formatter: *const Formatter, from: u32, close: u32) ?u32 {
        var token = from;
        while (token < close) : (token += 1) {
            switch (formatter.tag_of(token)) {
                .comma => continue,
                .comment => return token,
                else => return null,
            }
        }
        return null;
    }

    /// The comments in `[from, to)` that start their own lines, each on a line at `indent`.
    fn leading_comments(formatter: *Formatter, from: u32, to: u32, indent: u32) Error!void {
        var seen_newline = false;
        var token = from;
        while (token < to) : (token += 1) {
            switch (formatter.tag_of(token)) {
                .newline => seen_newline = true,
                .comment => if (seen_newline) {
                    try formatter.newline(indent);
                    try formatter.comment(token);
                },
                else => {},
            }
        }
    }
};

/// Orders a call's arguments: positional ones as written, then named ones by their entry (section
/// 1), and names the entry does not have last, as written.
fn order_arguments(tree: *const Tree, call: parse_module.Item, children: []const u32, order: []u32, role: schema.Role) void {
    const name = tree.token_text(call.token);
    const entry = schema.find(name, role) orelse schema.find(name, .signal) orelse
        schema.find(name, .mover) orelse return;
    const rank = struct {
        fn of(t: *const Tree, e: *const schema.Entry, child: u32, position: usize) u32 {
            const it = t.item(child);
            if (it.tag != .named) return @intCast(position);
            const index = e.param(t.token_text(it.token)) orelse return 100_000 + @as(u32, @intCast(position));
            return 1_000 + index;
        }
    }.of;
    if (order.len < 2) return;
    // An insertion sort, stable, over at most `items_max` items.
    for (1..order.len) |i| {
        const moving = order[i];
        const moving_rank = rank(tree, entry, children[moving], moving);
        var j = i;
        while (j > 0 and rank(tree, entry, children[order[j - 1]], order[j - 1]) > moving_rank) : (j -= 1) {
            order[j] = order[j - 1];
        }
        order[j] = moving;
    }
}

/// Formats `tree`, which parsed with no error, into `out`.
pub fn format(tree: *const Tree, out: []u8) Error![]const u8 {
    assert(tree.complete);
    var formatter: Formatter = .{ .tree = tree, .writer = .fixed(out) };
    var written_any = false;
    var cursor: u32 = 0;
    var comments_total: u32 = 0;
    for (tree.tokens) |token| comments_total += @intFromBool(token.tag == .comment);
    const eof: u32 = @intCast(tree.tokens.len - 1);
    for (0..tree.declarations.len + 1) |position| {
        const end = if (position < tree.declarations.len) tree.item(tree.declarations[position]).first else eof;
        var newlines: u32 = 0;
        var token = cursor;
        while (token < end) : (token += 1) {
            switch (formatter.tag_of(token)) {
                .newline => newlines += 1,
                .comment => {
                    if (written_any and newlines == 0) {
                        try formatter.write(" ");
                    } else if (written_any) {
                        try formatter.write(if (newlines >= 2) "\n\n" else "\n");
                    }
                    try formatter.comment(token);
                    written_any = true;
                    newlines = 0;
                },
                else => return error.CommentPlacement,
            }
        }
        if (position == tree.declarations.len) break;
        if (written_any) try formatter.write(if (newlines >= 2) "\n\n" else "\n");
        const index = tree.declarations[position];
        try formatter.declaration(index);
        written_any = true;
        cursor = tree.item(index).last + 1;
    }
    if (written_any) try formatter.write("\n");
    if (formatter.comments_written != comments_total) return error.CommentPlacement;
    return formatter.writer.buffered();
}

const testing = std.testing;

fn format_text(source: []const u8, out: []u8) ![]const u8 {
    const Static = struct {
        var fixture: parse_module.Fixture = undefined;
    };
    const tree = Static.fixture.run(source);
    try testing.expectEqual(@as(u32, 0), Static.fixture.diagnostics.total());
    return format(&tree, out);
}

// Locks the round trip of section 3 on a canonical file with every declaration and form.
test "a canonical file formats to its own bytes" {
    const canonical =
        \\# Play's signals.
        \\seed 7
        \\
        \\cue c0 = 0s
        \\cue bar = 0s..600s every 2s # 301 cues
        \\track glide_v = 1 in 0.25..4
        \\
        \\moves = [c1: 1, c3: -0.5]
        \\x = a + b * -0.8 - -c
        \\v = b.velocity
        \\glide_a = follow(
        \\    [0..1],
        \\    from: 0.5,
        \\    by: newtonian(speed: glide_v, accel: 16, decel: 16),
        \\    # a comment moves with the argument after it
        \\    pause: 0s..500ms,
        \\    seed: 9, # nine
        \\)
        \\s = spring(
        \\    moves,
        \\    time: 0.5s,
        \\)
        \\fb <- chase(fb, time: 0.5s)
        \\
    ;
    var out: [1024]u8 = undefined;
    try testing.expectEqualStrings(canonical, try format_text(canonical, &out));
}

test "a module and a use line format to their canonical text" {
    const canonical =
        \\use std
        \\module heavy(goal, time: 0.9s) in 0..2 = spring(goal, time: time, overshoot: 0.1)
        \\module breathe(base, amount) = base * (1 + amount * wave(sine, 0.2hz))
        \\out = heavy([c1: 1])
        \\
    ;
    var out: [1024]u8 = undefined;
    try testing.expectEqualStrings(canonical, try format_text(canonical, &out));
    var messy: [1024]u8 = undefined;
    try testing.expectEqualStrings(canonical, try format_text(
        \\use   std
        \\module heavy( goal,time:0.9s ) in 0..2=spring(goal,time:time,overshoot:0.1)
        \\module breathe(base,amount)=base*(1+amount*wave(sine,0.2hz))
        \\out=heavy([c1:1])
        \\
    , &messy));
}

// Locks the rules of section 1 on a messy file: spacing, blank lines, the order of named
// arguments, and a call that loses its trailing comma joining one line.
test "a messy file formats to the canonical one" {
    var out: [1024]u8 = undefined;
    const formatted = try format_text(
        \\
        \\
        \\seed   7
        \\s=spring(moves,overshoot:0.2,time:0.5s)   #   kept as written
        \\
        \\
        \\
        \\f = follow([0..1], seed: 2, by: spring(overshoot: 0.1, time: 1s), from: 0.5)
        \\l = [
        \\    1,
        \\    2
        \\]
        \\
    , &out);
    try testing.expectEqualStrings(
        \\seed 7
        \\s = spring(moves, time: 0.5s, overshoot: 0.2) #   kept as written
        \\
        \\f = follow([0..1], from: 0.5, by: spring(time: 1s, overshoot: 0.1), seed: 2)
        \\l = [1, 2]
        \\
    , formatted);
    var again: [1024]u8 = undefined;
    try testing.expectEqualStrings(formatted, try format_text(formatted, &again));
}

// Locks `/` in section 1 (step 30): `a/b` formats to `a / b`, a negative divisor keeps its sign
// on the literal, and the result formats to itself.
test "a quotient formats with a space on each side" {
    var out: [256]u8 = undefined;
    const formatted = try format_text("x = a/b\ny = (a+1)/-4/2*c\n", &out);
    try testing.expectEqualStrings("x = a / b\ny = (a + 1) / -4 / 2 * c\n", formatted);
    var again: [256]u8 = undefined;
    try testing.expectEqualStrings(formatted, try format_text(formatted, &again));
}

// Locks the refusals: a comment with no place, and a buffer too small.
test "a comment between operands, or a small buffer, is refused" {
    var out: [1024]u8 = undefined;
    try testing.expectError(error.CommentPlacement, format_text("x = (a # here\n + b)\n", &out));
    var small: [4]u8 = undefined;
    try testing.expectError(error.NoSpace, format_text("x = wave(sine, 1hz)\n", &small));
}
