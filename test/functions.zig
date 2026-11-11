//! `abs`, `min`, and `max` in the language (step 26), and `std`'s `clamp`: what they build, what
//! they fold to, their shapes and lanes, their ranges, and their errors.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Equality
//! `clamp` is a module, so a file that calls it is compiled beside the file written out, and
//! their nodes are compared with `std.meta.eql`, field by field, as `modules.zig` compares any
//! module with its hand-written graph. The catalog's own graphs of these calls are compared with
//! the builder in `lang.zig`, and their samples are locked by the regress golden.
//!
//! ## 2. Folding
//! A call given only numbers is a constant (`check.zig`, section 3): one node, whose bits are
//! read back, so a signed zero folds as its node would compute it.
//!
//! ## 3. Errors
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
    .libraries = 1,
};
const Compiled = weft.lang.Compiled(limits);

var with_module: Compiled = undefined;
var by_hand: Compiled = undefined;
var failing: Compiled = undefined;
var slab: [limits.slab]f64 = undefined;

const std_library: []const weft.lang.Source = &.{.{ .name = "std", .text = weft.lang.std_library }};

fn report(compiled: *const Compiled, source: []const u8, err: anyerror) anyerror {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (compiled.errors()) |found| found.render(source, "test", &writer) catch {};
    std.debug.print("{s}", .{writer.buffered()});
    return err;
}

fn compile(compiled: *Compiled, source: []const u8) !void {
    compiled.compile_with(std_library, source) catch |err| return report(compiled, source, err);
}

/// Compiles both files and checks they are the same program, node for node, with the same `out`.
fn expect_same(module: []const u8, hand: []const u8) !void {
    try compile(&with_module, module);
    try compile(&by_hand, hand);
    const a = with_module.program;
    const b = by_hand.program;
    try testing.expectEqual(b.nodes.len, a.nodes.len);
    for (b.nodes, a.nodes, 0..) |expected, actual, at| {
        if (!std.meta.eql(expected, actual)) {
            std.debug.print("node {d}:\n  {any}\n  {any}\n", .{ at, expected, actual });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(by_hand.signal("out").?, with_module.signal("out").?);
}

/// The values of the signal `name` of `compiled` at time 0.
fn values_at_zero(compiled: *const Compiled, name: []const u8) ![]const f64 {
    var state = weft.State.init(compiled.program, slab[0..compiled.program.slab_count]);
    state.eval(.{ .flicks = 0 });
    const id = compiled.signal(name) orelse return error.TestUnexpectedResult;
    return state.values(id);
}

fn range_of(compiled: *const Compiled, name: []const u8) weft.Range {
    var ranges: [limits.nodes]weft.Range = undefined;
    compiled.program.ranges(&ranges);
    return ranges[compiled.signal(name).?.index];
}

fn bits(value: f64) u64 {
    return @bitCast(value);
}

// Locks section 1: `clamp(x, low, high)` is `min(max(x, low), high)` node for node, by position
// and by name, with a signal for a bound as well as a number.
test "std's clamp is min of max, node for node" {
    try expect_same(
        "use std\nx = wave(sine, 1hz)\nout = clamp(x * 3, -1, 0.25)\n",
        "x = wave(sine, 1hz)\nout = min(max(x * 3, -1), 0.25)\n",
    );
    try expect_same(
        "use std\nx = wave(sine, 1hz)\nout = clamp(x, high: wave(saw, 2hz), low: -0.5)\n",
        "x = wave(sine, 1hz)\nout = min(max(x, -0.5), wave(saw, 2hz))\n",
    );
}

// Locks section 2: numbers fold to one constant each, the core's own answer: |-2| is 2, min(1,
// -0.5) is -0.5, max(-0, 0) is +0 and min(0, -0) is -0, |-0| is +0, and a clamp of numbers,
// clamp(3, 0, 1), is 1, with no node of its own. A call that reads a signal is a node.
test "abs, min, and max of numbers fold to a constant" {
    const source =
        \\use std
        \\a = abs(-2)
        \\b = min(1, -0.5)
        \\c = max(-0, 0)
        \\d = min(0, -0)
        \\e = abs(-0)
        \\f = clamp(3, 0, 1)
        \\
    ;
    try compile(&with_module, source);
    try testing.expectEqual(@as(usize, 6), with_module.program.nodes.len);
    const expected = [_]struct { []const u8, f64 }{
        .{ "a", 2 }, .{ "b", -0.5 }, .{ "c", 0 }, .{ "d", -0.0 }, .{ "e", 0 }, .{ "f", 1 },
    };
    for (expected) |pair| {
        const node = with_module.program.nodes[with_module.signal(pair[0]).?.index];
        errdefer std.debug.print("{s}: {any}\n", .{ pair[0], node.op });
        try testing.expectEqual(bits(pair[1]), bits(node.op.constant));
    }
    try compile(&with_module, "x = wave(sine, 1hz)\nout = max(x, 0)\n");
    try testing.expectEqual(@as(usize, 3), with_module.program.nodes.len);
}

// Locks the shapes of `schema.zig`, section 3c: abs of a vec2 is a vec2, (1, 0.5) from (-1, 0.5);
// min with a number broadcasts, (-1, 0.25); max of two colours is a colour, per component; and
// a colour with a number, as `+` takes one. Each is one node over its operands.
test "abs, min, and max work per component on vectors and colours" {
    const source =
        \\a = abs(vec2(-1, 0.5))
        \\m = min(vec2(-1, 0.5), 0.25)
        \\c = max(oklab(0.5, -0.1, 0.2), oklab(0.6, -0.2, 0.1))
        \\k = min(oklab(0.5, -0.1, 0.2), 0)
        \\
    ;
    try compile(&with_module, source);
    try testing.expectEqualSlices(f64, &.{ 1, 0.5 }, try values_at_zero(&with_module, "a"));
    try testing.expectEqualSlices(f64, &.{ -1, 0.25 }, try values_at_zero(&with_module, "m"));
    try testing.expectEqualSlices(f64, &.{ 0.6, -0.1, 0.2 }, try values_at_zero(&with_module, "c"));
    try testing.expectEqualSlices(f64, &.{ 0, -0.1, 0 }, try values_at_zero(&with_module, "k"));
    const program = with_module.program;
    try testing.expectEqual(@as(u32, 2), program.nodes[with_module.signal("a").?.index].extent.components);
    try testing.expectEqual(@as(u32, 3), program.nodes[with_module.signal("c").?.index].extent.components);
}

// Locks the lane rule `inputs`: in four lanes, |lane - 1.5| is 1.5, 0.5, 0.5, 1.5; and max of
// a region and a one-lane name is the region's lanes, 1, 1, 2, 3, the name broadcast.
test "abs, min, and max take the lanes of what they read" {
    const source =
        \\one = 1
        \\d = lanes(4, abs(lane - 1.5))
        \\index = lanes(4, lane)
        \\f = max(index, one)
        \\
    ;
    try compile(&with_module, source);
    try testing.expectEqualSlices(f64, &.{ 1.5, 0.5, 0.5, 1.5 }, try values_at_zero(&with_module, "d"));
    try testing.expectEqualSlices(f64, &.{ 1, 1, 2, 3 }, try values_at_zero(&with_module, "f"));
}

// Locks the ranges `check` and `sample` report through the language: |wave| is [0, 1],
// min(wave, 0.5) is [-1, 0.5], max(2 wave, triangle) is [-1, 2], a clamp of 3 wave to
// [-1, 0.25] is [-1, 0.25] exactly, and a clamp whose low is above its high is its high.
test "the ranges of abs, min, max, and clamp are exact" {
    const source =
        \\use std
        \\w = wave(sine, 1hz)
        \\a = abs(w)
        \\m = min(w, 0.5)
        \\x = max(w * 2, wave(triangle, 0.5hz))
        \\c = clamp(w * 3, -1, 0.25)
        \\h = clamp(w, 0.75, 0.5)
        \\
    ;
    try compile(&with_module, source);
    try testing.expectEqual(weft.Range{ .low = 0, .high = 1 }, range_of(&with_module, "a"));
    try testing.expectEqual(weft.Range{ .low = -1, .high = 0.5 }, range_of(&with_module, "m"));
    try testing.expectEqual(weft.Range{ .low = -1, .high = 2 }, range_of(&with_module, "x"));
    try testing.expectEqual(weft.Range{ .low = -1, .high = 0.25 }, range_of(&with_module, "c"));
    try testing.expectEqual(weft.Range{ .low = 0.5, .high = 0.5 }, range_of(&with_module, "h"));
    try testing.expectEqualSlices(f64, &.{0.5}, try values_at_zero(&with_module, "h"));
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
    failing.compile_with(std_library, case.source) catch {
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

// Locks section 3: two vectors of different sizes, a colour with a vector, two lane counts above
// 1, a time, and a missing argument are each refused once, by the checker, as `+` refuses them.
test "abs, min, and max refuse what does not fit, as arithmetic does" {
    const cases = [_]Expected{
        .{
            .source = "x = min(vec2(1, 2), vec3(1, 2, 3))\n",
            .code = .wrong_shape,
            .message = "a vec2 and a vec3 do not go together",
            .hint = "make them one size, or take a component such as `.x`",
            .span = "min(vec2(1, 2), vec3(1, 2, 3))",
        },
        .{
            .source = "x = max(srgb(1, 0, 0), vec3(1, 2, 3))\n",
            .code = .wrong_shape,
            .message = "a colour and a vec3 do not go together",
            .hint = "a colour's components are `.l .a .b`; take one to mix it with a vector",
            .span = "max(srgb(1, 0, 0), vec3(1, 2, 3))",
        },
        .{
            .source = "a = lanes(3, lane)\nb = lanes(4, lane)\nx = min(a, b)\n",
            .code = .wrong_lanes,
            .message = "3 lanes and 4 lanes do not go together",
            .hint = "lanes meet where their counts are equal, or where one side has one lane",
            .span = "min(a, b)",
        },
        .{
            .source = "x = abs(2s)\n",
            .code = .wrong_type,
            .message = "a time is not a signal",
            .hint = "a signal here is a name, a call, arithmetic, or a plain number",
            .span = "2s",
        },
        .{
            .source = "x = min(wave(sine, 1hz))\n",
            .code = .missing_argument,
            .message = "min needs `b`",
            .hint = "add `b: a signal`",
            .span = "min",
        },
        .{
            .source = "use std\nx = clamp(wave(sine, 1hz), 0)\n",
            .code = .missing_argument,
            .message = "clamp needs `high`",
            .hint = "add `high: …`",
            .span = "clamp(wave(sine, 1hz), 0)",
        },
    };
    for (cases) |case| try expect_one(case);
}
