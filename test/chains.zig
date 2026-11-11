//! A tween after a tween (step 31) against the chain written out: a `from` left out is the `to`
//! of the tween `after` names, so the file builds the program the longer text builds.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Equality
//! Two files are compiled, one that leaves `from` out where `after` names a tween and one that
//! writes every `from`, and their nodes are compared with `std.meta.eql`, field by field, as
//! `modules.zig` compares a module with the graph written by hand. The default is filled in by
//! the checker (`check.zig`, section 6b), so nothing in the program can tell the two apart.
//!
//! ## 2. Errors
//! Each refusal has a case with its code, its message, its hint, and the text under its span, and
//! each is one error: a name used before it is declared, or a cycle through `after`, is reported
//! where it is written and stops there, with no loop to follow.

const std = @import("std");
const testing = std.testing;
const weft = @import("weft");
const diagnostic = weft.lang.diagnostic;

const limits: weft.lang.Limits = .{
    .tokens = 1024,
    .tree = 512,
    .names = 64,
    .nodes = 64,
    .slab = 256,
    .cues = 16,
    .goals = 16,
    .regions = 8,
    .tracks = 4,
    .track_samples = 4,
    .modules = 8,
};
const Compiled = weft.lang.Compiled(limits);

var short: Compiled = undefined;
var long: Compiled = undefined;
var failing: Compiled = undefined;
var short_syntax: weft.lang.Syntax(.{}) = undefined;

const prelude = "cue b7 = 1s\ncue b7a = 3s\ncue b8a = 8s\ncue b9a = 15s\n";

fn report(compiled: *const Compiled, source: []const u8, err: anyerror) anyerror {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (compiled.errors()) |found| found.render(source, "test", &writer) catch {};
    std.debug.print("{s}", .{writer.buffered()});
    return err;
}

/// Compiles both files and checks they are the same program, node for node, with the same `out`.
fn expect_same(left_out: []const u8, written: []const u8) !void {
    short.compile(left_out) catch |err| return report(&short, left_out, err);
    long.compile(written) catch |err| return report(&long, written, err);
    const a = short.program;
    const b = long.program;
    try testing.expectEqual(b.nodes.len, a.nodes.len);
    for (b.nodes, a.nodes, 0..) |expected, actual, at| {
        if (!std.meta.eql(expected, actual)) {
            std.debug.print("node {d}:\n  {any}\n  {any}\n", .{ at, expected, actual });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(b.slab_count, a.slab_count);
    try testing.expectEqual(long.signal("out").?, short.signal("out").?);
}

// Locks section 1 on Tapestry's point: a chain of four with the last three `from`s left out,
// each after a tween whose own `from` was left out, builds the chain as written, node for node.
test "a chain of tweens says each value once" {
    try expect_same(prelude ++
        \\px_right = tween(from: 1, to: 2.2, at: b7, over: 2s, ease: in_out)
        \\px_left = tween(to: -2.6, at: b7a, over: 5s, ease: in_out, after: px_right)
        \\px_sweep = tween(to: 2.6, at: b8a, over: 6500ms, ease: in_out, after: px_left)
        \\out = tween(to: 1, at: b9a, over: 3s, ease: in_out, after: px_sweep)
        \\
    , prelude ++
        \\px_right = tween(from: 1, to: 2.2, at: b7, over: 2s, ease: in_out)
        \\px_left = tween(from: 2.2, to: -2.6, at: b7a, over: 5s, ease: in_out, after: px_right)
        \\px_sweep = tween(from: -2.6, to: 2.6, at: b8a, over: 6500ms, ease: in_out, after: px_left)
        \\out = tween(from: 2.6, to: 1, at: b9a, over: 3s, ease: in_out, after: px_sweep)
        \\
    );
    // Writing both stays legal, and a written `from` wins even where it differs: a jump.
    try expect_same(prelude ++
        \\a = tween(from: 0, to: 1, at: b7, over: 1s)
        \\out = tween(from: 5, to: 2, at: b7a, over: 1s, after: a)
        \\
    , prelude ++
        \\a = tween(from: 0, to: 1, at: b7, over: 1s)
        \\out = tween(from: 5, to: 2, at: b7a, over: 1s, after: (a))
        \\
    );
    const node = short.program.nodes[short.signal("out").?.index].op.tween;
    try testing.expectEqual(@as(f64, 5), node.from);
}

// Locks section 1 for shapes: a vector chain and a colour chain carry `to` over whole, as the
// written chains do.
test "a vector chain and a colour chain carry their ends whole" {
    try expect_same(prelude ++
        \\a = tween(from: vec2(0, 1), to: vec2(1, -1), at: b7, over: 1s)
        \\b = tween(to: vec2(2, 0.5), at: b7a, over: 1s, after: a)
        \\out = tween(to: 0, at: b8a, over: 1s, after: b)
        \\
    , prelude ++
        \\a = tween(from: vec2(0, 1), to: vec2(1, -1), at: b7, over: 1s)
        \\b = tween(from: vec2(1, -1), to: vec2(2, 0.5), at: b7a, over: 1s, after: a)
        \\out = tween(from: vec2(2, 0.5), to: 0, at: b8a, over: 1s, after: b)
        \\
    );
    try expect_same(prelude ++
        \\a = tween(from: srgb(1, 0, 0), to: srgb(0, 0, 1), at: b7, over: 1s)
        \\out = tween(to: oklab(0.7, 0.1, -0.1), at: b7a, over: 1s, after: a)
        \\
    , prelude ++
        \\a = tween(from: srgb(1, 0, 0), to: srgb(0, 0, 1), at: b7, over: 1s)
        \\out = tween(from: srgb(0, 0, 1), to: oklab(0.7, 0.1, -0.1), at: b7a, over: 1s, after: a)
        \\
    );
}

// Locks section 1 for the ways to name a tween: in parentheses, through a module's parameter,
// through two modules, and in a region of lanes, named from inside and outside it.
test "after names a tween through parentheses, a module, and a region" {
    try expect_same(prelude ++
        \\module then(to, at, after) = tween(to: to, at: at, over: 1s, after: after)
        \\module twice(to, at, after) = then(to, at, after)
        \\a = tween(from: 0, to: 1, at: b7, over: 1s)
        \\b = tween(to: 2, at: b7a, over: 1s, after: (a))
        \\c = then(3, b8a, b)
        \\out = twice(4, b9a, after: (c))
        \\
    , prelude ++
        \\a = tween(from: 0, to: 1, at: b7, over: 1s)
        \\b = tween(from: 1, to: 2, at: b7a, over: 1s, after: a)
        \\c = tween(from: 2, to: 3, at: b8a, over: 1s, after: b)
        \\out = tween(from: 3, to: 4, at: b9a, over: 1s, after: c)
        \\
    );
    try expect_same(prelude ++
        \\a = tween(from: 0, to: 1, at: b7, over: 1s)
        \\b = lanes(4, tween(to: 2, at: b7a, over: 1s, after: a, stagger: 10ms))
        \\out = lanes(4, tween(to: 0, at: b8a, over: 1s, after: b, stagger: 10ms))
        \\
    , prelude ++
        \\a = tween(from: 0, to: 1, at: b7, over: 1s)
        \\b = lanes(4, tween(from: 1, to: 2, at: b7a, over: 1s, after: a, stagger: 10ms))
        \\out = lanes(4, tween(from: 2, to: 0, at: b8a, over: 1s, after: b, stagger: 10ms))
        \\
    );
}

// Locks the canonical format: a left-out `from` stays left out, and `after` takes its place in
// the table's order.
test "the format keeps a left-out from left out" {
    const messy = "b = tween(after: a, over: 1s, to: 2, at: c1)\n";
    try testing.expect(short_syntax.parse_source(messy));
    var out: [256]u8 = undefined;
    const formatted = try short_syntax.format_into(&out);
    try testing.expectEqualStrings("b = tween(to: 2, at: c1, over: 1s, after: a)\n", formatted);
    try testing.expect(short_syntax.parse_source(formatted));
    var again: [256]u8 = undefined;
    try testing.expectEqualStrings(formatted, try short_syntax.format_into(&again));
}

const Expected = struct {
    source: []const u8,
    code: diagnostic.Code,
    message: []const u8,
    hint: []const u8 = "",
    /// The text under the error's span.
    span: []const u8,
};

fn expect_one(case: Expected) !void {
    errdefer std.debug.print("case: {s}\n", .{case.source});
    failing.compile(case.source) catch {
        const found = failing.errors();
        try testing.expectEqual(@as(usize, 1), found.len);
        try testing.expectEqual(case.code, found[0].code);
        try testing.expectEqualStrings(case.message, found[0].message_text());
        try testing.expectEqualStrings(case.hint, found[0].hint_text());
        try testing.expectEqualStrings(case.span, case.source[found[0].start..][0..found[0].len]);
        return;
    };
    return error.TestUnexpectedResult;
}

// Locks section 2: with no `after`, or an `after` that is not a name bound to a tween, `from` is
// required; a tween named before it is declared, or two that name each other, is one error at
// the name; and a chain's `to` of another shape is the shape error `from` and `to` always give.
test "from is required unless after names a tween" {
    const hint = "`from` may be left out only when `after` names a tween";
    const head = "cue c = 1s\na = tween(from: 0, to: 1, at: c, over: 1s)\n";
    const cases = [_]Expected{
        .{
            .source = "cue c = 1s\nb = tween(to: 1, at: c, over: 1s)\n",
            .code = .missing_argument,
            .message = "tween needs `from`",
            .hint = hint,
            .span = "tween",
        },
        .{
            .source = head ++ "b = tween(to: 2, at: c, over: 1s, after: a + a)\n",
            .code = .missing_argument,
            .message = "tween needs `from`, since `after` is not a name bound to a tween",
            .hint = hint,
            .span = "a + a",
        },
        .{
            .source = "cue c = 1s\ns = spring([c: 1], time: 1s)\nb = tween(to: 2, at: c, over: 1s, after: s)\n",
            .code = .missing_argument,
            .message = "tween needs `from`, since `after` is not a name bound to a tween",
            .hint = hint,
            .span = "s",
        },
        .{
            .source = head ++ "b = tween(to: 2, at: c, over: 1s, after: tween(from: 0, to: 1, at: c, over: 1s))\n",
            .code = .missing_argument,
            .message = "tween needs `from`, since `after` is not a name bound to a tween",
            .hint = hint,
            .span = "tween(from: 0, to: 1, at: c, over: 1s)",
        },
        .{
            .source = head ++ "same = a\nb = tween(to: 2, at: c, over: 1s, after: same)\n",
            .code = .missing_argument,
            .message = "tween needs `from`, since `after` is not a name bound to a tween",
            .hint = hint,
            .span = "same",
        },
        .{
            .source = head ++ "module then(to, at, after) = tween(to: to, at: at, over: 1s, after: after)\nb = then(2, c, a * 2)\n",
            .code = .missing_argument,
            .message = "tween needs `from`, since `after` is not a name bound to a tween",
            .hint = hint,
            .span = "after",
        },
        .{
            .source = "cue c = 1s\nb = tween(to: 2, at: c, over: 1s, after: a)\na = tween(from: 0, to: 1, at: c, over: 1s)\n",
            .code = .used_before_declared,
            .message = "`a` is used before it is declared, on line 3",
            .hint = "move it up, or go through a delay",
            .span = "a",
        },
        .{
            .source = "cue c = 1s\na = tween(to: 1, at: c, over: 1s, after: b)\nb = tween(to: 2, at: c, over: 1s, after: a)\n",
            .code = .used_before_declared,
            .message = "`b` is used before it is declared, on line 3",
            .hint = "move it up, or go through a delay",
            .span = "b",
        },
        .{
            .source = "cue c = 1s\na = tween(from: vec2(0, 1), to: vec2(1, 0), at: c, over: 1s)\nb = tween(to: vec3(1, 2, 3), at: c, over: 1s, after: a)\n",
            .code = .wrong_shape,
            .message = "`from` and `to` differ: a vec2 and a vec3",
            .span = "tween(to: vec3(1, 2, 3), at: c, over: 1s, after: a)",
        },
        .{
            .source = "cue c = 1s\na = tween(from: srgb(1, 0, 0), to: srgb(0, 1, 0), at: c, over: 1s)\nb = tween(to: 0.5, at: c, over: 1s, after: a)\n",
            .code = .wrong_shape,
            .message = "`from` and `to` differ: a colour and a number",
            .hint = "write the number as a colour, such as `oklab(0.5, 0, 0)`",
            .span = "tween(to: 0.5, at: c, over: 1s, after: a)",
        },
    };
    for (cases) |case| try expect_one(case);
}
