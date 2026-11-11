//! Division by a number (step 30) against the products it stands for: `x / c` builds the nodes
//! `x * (1 / c)` builds, so a quotient adds nothing a product does not have.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Equality
//! Two files are compiled, one that divides and one that multiplies by the reciprocal written as
//! a literal, and their nodes are compared with `std.meta.eql`, field by field, as `modules.zig`
//! compares a module with the graph written by hand. A reciprocal written with `{d}` is the
//! shortest text that reads back to the same bits, so the literal is the checker's constant.
//! Where only the values can say it, per lane, they are read and compared bit for bit.
//!
//! ## 2. Errors
//! Each refusal has a case with its code, its message, its hint, and the text under its span, so
//! a message that regresses to a crash, a wrong code, or a builder refusal fails here.

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
    .cues = 8,
    .goals = 16,
    .regions = 8,
    .tracks = 4,
    .track_samples = 4,
    .modules = 8,
};
const Compiled = weft.lang.Compiled(limits);

var dividing: Compiled = undefined;
var multiplying: Compiled = undefined;
var failing: Compiled = undefined;
var slab: [limits.slab]f64 = undefined;

const prelude = "seed 3\ncue c0 = 0s\ncue c1 = 1s\n";

fn report(compiled: *const Compiled, source: []const u8, err: anyerror) anyerror {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (compiled.errors()) |found| found.render(source, "test", &writer) catch {};
    std.debug.print("{s}", .{writer.buffered()});
    return err;
}

/// Compiles both files and checks they are the same program, node for node, with the same `out`.
fn expect_same(quotient: []const u8, product: []const u8) !void {
    dividing.compile(quotient) catch |err| return report(&dividing, quotient, err);
    multiplying.compile(product) catch |err| return report(&multiplying, product, err);
    const a = dividing.program;
    const b = multiplying.program;
    try testing.expectEqual(b.nodes.len, a.nodes.len);
    for (b.nodes, a.nodes, 0..) |expected, actual, at| {
        if (!std.meta.eql(expected, actual)) {
            std.debug.print("node {d}:\n  {any}\n  {any}\n", .{ at, expected, actual });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(b.slab_count, a.slab_count);
    try testing.expectEqual(multiplying.signal("out").?, dividing.signal("out").?);
}

// Locks section 1: `x / 4` is `x * 0.25` node for node, as `lang.zig` locks `a - b` as
// `a + -b`; so are a negative divisor, one in parentheses, and a module's parameter bound to a
// number, and `x / 3` is the product with 1 / 3, 0.3333333333333333, not with a rounder number.
test "a quotient by a number is the product with its reciprocal" {
    try expect_same(
        prelude ++ "x = wave(sine, 1hz)\nout = x / 4\n",
        prelude ++ "x = wave(sine, 1hz)\nout = x * 0.25\n",
    );
    try expect_same(
        prelude ++ "x = wave(sine, 1hz)\nout = x / -4 + x / (8)\n",
        prelude ++ "x = wave(sine, 1hz)\nout = x * -0.25 + x * 0.125\n",
    );
    try expect_same(
        prelude ++ "module scale(v, by) = v / by\nx = wave(sine, 1hz)\nout = scale(x, 4) + scale(x, by: -4)\n",
        prelude ++ "x = wave(sine, 1hz)\nout = x * 0.25 + x * -0.25\n",
    );
    try expect_same(
        prelude ++ "x = wave(sine, 1hz)\nout = x / 3\n",
        prelude ++ "x = wave(sine, 1hz)\nout = x * 0.3333333333333333\n",
    );
    try testing.expectEqual(1.0 / 3.0, dividing.program.nodes[dividing.program.nodes.len - 2].op.constant);
}

// Locks section 1 for folding and order: two numbers fold to their quotient in f64, not to a
// product with a reciprocal (`3 / 10` is 0.3, where `3 * 0.1` is 0.30000000000000004), and
// `x / 3 / 2` is two products, left to right.
test "two numbers fold to their quotient, and a chain divides left to right" {
    dividing.compile(prelude ++ "two = 6 / 3\ntenths = 3 / 10\nout = two\n") catch |err| return report(&dividing, "", err);
    const nodes = dividing.program.nodes;
    try testing.expectEqual(@as(usize, 2), nodes.len);
    try testing.expectEqual(@as(f64, 2), nodes[dividing.signal("two").?.index].op.constant);
    try testing.expectEqual(@as(f64, 0.3), nodes[dividing.signal("tenths").?.index].op.constant);
    try expect_same(
        prelude ++ "x = wave(sine, 1hz)\nout = x / 3 / 2\n",
        prelude ++ "x = wave(sine, 1hz)\nout = x * 0.3333333333333333 * 0.5\n",
    );
}

// Locks section 1 per component and per lane: a vector divides each component, the nodes of
// `v * 0.25`; and a region divides each lane, inside it (lane i / 4) and outside it (a region's
// signal / 8), every lane's value i / 4 and i / 8 exactly.
test "a vector and a region of lanes divide per component and per lane" {
    try expect_same(
        prelude ++ "v = vec2(wave(sine, 1hz), tween(from: 0, to: 1, at: c0, over: 1s))\nout = v / 4\n",
        prelude ++ "v = vec2(wave(sine, 1hz), tween(from: 0, to: 1, at: c0, over: 1s))\nout = v * 0.25\n",
    );
    try expect_same(
        prelude ++ "tint = srgb(1, 0.5, 0) * wave(sine, 1hz)\nout = tint / 2\n",
        prelude ++ "tint = srgb(1, 0.5, 0) * wave(sine, 1hz)\nout = tint * 0.5\n",
    );
    try expect_same(
        prelude ++ "out = lanes(4, lane / 4)\n",
        prelude ++ "out = lanes(4, lane * 0.25)\n",
    );
    const source = prelude ++ "quarters = lanes(4, lane / 4)\nindex = lanes(4, lane)\neighths = index / 8\n";
    dividing.compile(source) catch |err| return report(&dividing, source, err);
    var state = weft.State.init(dividing.program, slab[0..dividing.program.slab_count]);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqualSlices(f64, &.{ 0, 0.25, 0.5, 0.75 }, state.values(dividing.signal("quarters").?));
    try testing.expectEqualSlices(f64, &.{ 0, 0.125, 0.25, 0.375 }, state.values(dividing.signal("eighths").?));
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

// Locks section 2: a signal, a track, a module's parameter bound to a signal, zero, a number
// whose reciprocal is not finite, a time, and a vector are each refused once, at the divisor.
test "a divisor that is not a number with a finite reciprocal is refused" {
    const signal_message = "a divisor is a number, fixed when the program is built";
    const signal_hint = "to scale by a signal, multiply by one";
    const cases = [_]Expected{
        .{
            .source = "x = wave(sine, 1hz)\ny = 1 / x\n",
            .code = .not_live,
            .message = signal_message,
            .hint = signal_hint,
            .span = "x",
        },
        .{
            .source = "track t = 1 in 1..2\ny = wave(sine, 1hz) / t\n",
            .code = .not_live,
            .message = signal_message,
            .hint = signal_hint,
            .span = "t",
        },
        .{
            .source = "y = lanes(4, wave(sine, 1hz) / (lane + 1))\n",
            .code = .not_live,
            .message = signal_message,
            .hint = signal_hint,
            .span = "(lane + 1)",
        },
        .{
            .source = "module scale(v, by) = v / by\ny = scale(1, wave(sine, 1hz))\n",
            .code = .not_live,
            .message = signal_message,
            .hint = signal_hint,
            .span = "by",
        },
        .{
            .source = "y = wave(sine, 1hz) / 0\n",
            .code = .out_of_range,
            .message = "there is no division by 0",
            .hint = "a divisor is a number other than 0",
            .span = "0",
        },
        .{
            .source = "y = 1 / (1 - 1)\n",
            .code = .out_of_range,
            .message = "there is no division by 0",
            .hint = "a divisor is a number other than 0",
            .span = "(1 - 1)",
        },
        .{
            .source = "y = wave(sine, 1hz) / 1e-310\n",
            .code = .out_of_range,
            .message = "1 / 1e-310 is past what a number holds",
            .hint = "divide by a number further from 0",
            .span = "1e-310",
        },
        .{
            .source = "y = wave(sine, 1hz) / 2s\n",
            .code = .wrong_type,
            .message = "a divisor is a number, and this is a time",
            .hint = "drop the unit",
            .span = "2s",
        },
        .{
            .source = "module per(v, by: 2s) = v / by\ny = per(1)\n",
            .code = .wrong_type,
            .message = "a divisor is a number, and this is a time",
            .hint = "drop the unit",
            .span = "by",
        },
        .{
            .source = "y = wave(sine, 1hz) / vec2(1, 2)\n",
            .code = .wrong_shape,
            .message = "a divisor is a number, and this is a vec2",
            .hint = "divide by a number, or take a component, such as `.x`",
            .span = "vec2(1, 2)",
        },
    };
    for (cases) |case| try expect_one(case);
}
