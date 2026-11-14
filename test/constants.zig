//! `pi` and `tau` (step 40) against the numbers written out: a file that names them builds the
//! nodes a file that writes `3.141592653589793` and `6.283185307179586` builds.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Equality
//! Two files are compiled, one with the names and one with the numbers written as literals, and
//! their nodes are compared with `std.meta.eql`, field by field, as `division.zig` compares a
//! quotient with its product. A literal written with `{d}` is the shortest text that reads back
//! to the same bits, so it is the checker's number. The places cover every kind of place a
//! number is due (`check.zig`, section 3b) and a signal.
//!
//! ## 2. Shadowing
//! A file's declaration of either name, and a module's parameter of it, is that name, so a file
//! that binds `tau` builds what it built before step 40, and a module body, which never sees the
//! file's names, reads the language's.
//!
//! ## 3. Errors
//! Each refusal has a case with its code, its message, its hint, and the text under its span, so
//! a fold that regresses to a crash, an infinity, or a new message fails here.

const std = @import("std");
const testing = std.testing;
const weft = @import("weft");
const diagnostic = weft.lang.diagnostic;

const limits: weft.lang.Limits = .{
    .tokens = 1024,
    .tree = 512,
    .names = 64,
    .nodes = 256,
    .slab = 2048,
    .cues = 8,
    .goals = 16,
    .regions = 8,
    .tracks = 4,
    .track_samples = 4,
    .modules = 8,
};
const Compiled = weft.lang.Compiled(limits);
const Syntax = weft.lang.Syntax(limits);

var named: Compiled = undefined;
var written: Compiled = undefined;
var failing: Compiled = undefined;
var syntax: Syntax = undefined;
var slab: [limits.slab]f64 = undefined;

const prelude = "seed 3\ncue c0 = 0s\ncue c1 = 1s\n";

fn report(compiled: *const Compiled, source: []const u8, err: anyerror) anyerror {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (compiled.errors()) |found| found.render(source, "test", &writer) catch {};
    std.debug.print("{s}", .{writer.buffered()});
    return err;
}

/// Compiles both files and checks they are the same program, node for node, with the same slab
/// and the same `out`.
fn expect_same(with_names: []const u8, with_numbers: []const u8) !void {
    errdefer std.debug.print("case: {s}\n", .{with_names});
    named.compile(with_names) catch |err| return report(&named, with_names, err);
    written.compile(with_numbers) catch |err| return report(&written, with_numbers, err);
    const a = named.program;
    const b = written.program;
    try testing.expectEqual(b.nodes.len, a.nodes.len);
    for (b.nodes, a.nodes, 0..) |expected, actual, at| {
        if (!std.meta.eql(expected, actual)) {
            std.debug.print("node {d}:\n  {any}\n  {any}\n", .{ at, expected, actual });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(b.slab_count, a.slab_count);
    try testing.expectEqual(written.signal("out").?, named.signal("out").?);
}

/// The value of `out` at `seconds`, from a fresh reader of `compiled`.
fn value_at(compiled: *const Compiled, seconds: i64) f64 {
    var state = weft.State.init(compiled.program, slab[0..compiled.program.slab_count]);
    state.eval(.{ .flicks = seconds * weft.time.flicks_per_second });
    return state.values(compiled.signal("out").?)[0];
}

// Locks section 1 where a number is due: a tween's ends, a lane count, a range's ends, a path's
// goals, a vector written in numbers, a bounce's walls and speed, a track's value and bounds, a
// number a signal may set (`overshoot`, fixed as its literal is), a module's argument and
// default; and where a signal goes, as a function's input and in a region's arithmetic.
test "pi and tau build the nodes their numbers build" {
    try expect_same(
        prelude ++ "out = tween(from: 0, to: 2 * pi, at: c0, over: 1s)\n",
        prelude ++ "out = tween(from: 0, to: 6.283185307179586, at: c0, over: 1s)\n",
    );
    try expect_same(
        prelude ++ "out = tween(from: -tau, to: (tau) / 2, at: c0, over: 1s)\n",
        prelude ++ "out = tween(from: -6.283185307179586, to: 3.141592653589793, at: c0, over: 1s)\n",
    );
    try expect_same(
        prelude ++ "out = lanes(97, lane * tau / 96)\n",
        prelude ++ "out = lanes(97, lane * 6.283185307179586 / 96)\n",
    );
    try expect_same(
        prelude ++ "out = lanes(2 * 2, lane)\n",
        prelude ++ "out = lanes(4, lane)\n",
    );
    try expect_same(
        prelude ++ "out = map(wave(sine, 1hz), -1..1, to: -pi..tau - pi / 2)\n",
        prelude ++ "out = map(wave(sine, 1hz), -1..1, to: -3.141592653589793..4.71238898038469)\n",
    );
    try expect_same(
        prelude ++ "out = spring([c0: pi, c1: -tau / 4], time: 1s)\n",
        prelude ++ "out = spring([c0: 3.141592653589793, c1: -1.5707963267948966], time: 1s)\n",
    );
    try expect_same(
        prelude ++ "out = tween(from: vec2(0, 0), to: vec2(tau, pi / 2), at: c0, over: 1s)\n",
        prelude ++ "out = tween(from: vec2(0, 0), to: vec2(6.283185307179586, 1.5707963267948966), at: c0, over: 1s)\n",
    );
    try expect_same(
        prelude ++ "b = bounce(-pi..pi, speed: tau, at: c0)\nout = b * 1\n",
        prelude ++ "b = bounce(-3.141592653589793..3.141592653589793, speed: 6.283185307179586, at: c0)\nout = b * 1\n",
    );
    try expect_same(
        prelude ++ "track t = pi in 0..tau\nout = t * 1\n",
        prelude ++ "track t = 3.141592653589793 in 0..6.283185307179586\nout = t * 1\n",
    );
    try expect_same(
        prelude ++ "out = chase(wave(sine, 1hz), time: 1s, overshoot: pi / 10)\n",
        prelude ++ "out = chase(wave(sine, 1hz), time: 1s, overshoot: 0.3141592653589793)\n",
    );
    try expect_same(
        prelude ++ "module go(to, at) = tween(from: 0, to: to, at: at, over: 1s)\nout = go(tau / 2, c0)\n",
        prelude ++ "out = tween(from: 0, to: 3.141592653589793, at: c0, over: 1s)\n",
    );
    try expect_same(
        prelude ++ "module turn(at, by: tau / 4) = tween(from: 0, to: by, at: at, over: 1s)\nout = turn(c0)\n",
        prelude ++ "out = tween(from: 0, to: 1.5707963267948966, at: c0, over: 1s)\n",
    );
    try expect_same(
        prelude ++ "x = wave(sine, 1hz)\nout = sin(x * tau) + cos(pi / 2) * x\n",
        prelude ++ "x = wave(sine, 1hz)\nout = sin(x * 6.283185307179586) + cos(1.5707963267948966) * x\n",
    );
}

// Locks section 1's bits: `2 * pi` is `tau` exactly and `tau / 2` is `pi`, as a signal's
// constant and as a tween's `to`; and `tau / 13` folds to the quotient, 0.483321946706122,
// not the product with 1 / 13, 0.48332194670612205, where a number is due as where a signal goes.
test "a fold is the f64 arithmetic, a quotient by a number its quotient" {
    named.compile(prelude ++ "two_pi = 2 * pi\nhalf = tau / 2\nout = tau / 13\n") catch |err| return report(&named, "", err);
    const nodes = named.program.nodes;
    try testing.expectEqual(std.math.tau, nodes[named.signal("two_pi").?.index].op.constant);
    try testing.expectEqual(std.math.pi, nodes[named.signal("half").?.index].op.constant);
    try testing.expectEqual(@as(f64, 0.483321946706122), nodes[named.signal("out").?.index].op.constant);
    try testing.expect(std.math.tau / 13.0 != std.math.tau * (1.0 / 13.0));
    const landing = prelude ++ "out = tween(from: 0, to: tau / 13, at: c0, over: 1s)\n";
    named.compile(landing) catch |err| return report(&named, landing, err);
    try testing.expectEqual(@as(f64, 0.483321946706122), value_at(&named, 1));
    const doubled = prelude ++ "out = tween(from: 0, to: 2 * pi, at: c0, over: 1s)\n";
    named.compile(doubled) catch |err| return report(&named, doubled, err);
    try testing.expectEqual(std.math.tau, value_at(&named, 1));
}

// Locks section 2: a file that binds `tau` builds what a binding of another name builds, so
// `lane * tau / 96` reads the binding as before step 40; a cue named `pi` is a cue; a module's
// parameter `pi` or `tau` is its argument; and a module body reads the language's `tau` when
// the file binds its own, since it never sees the file's names.
test "a declaration or a parameter of the name shadows the number" {
    try expect_same(
        prelude ++ "tau = 6.283185307179586\nout = lanes(97, lane * tau / 96)\n",
        prelude ++ "turn = 6.283185307179586\nout = lanes(97, lane * turn / 96)\n",
    );
    try expect_same(
        prelude ++ "cue pi = 2s\nout = tween(from: 0, to: 1, at: pi, over: 1s)\n",
        prelude ++ "cue c2 = 2s\nout = tween(from: 0, to: 1, at: c2, over: 1s)\n",
    );
    try expect_same(
        prelude ++ "module half(pi) = pi / 2\nout = half(3) + wave(sine, 1hz)\n",
        prelude ++ "out = 1.5 + wave(sine, 1hz)\n",
    );
    try expect_same(
        prelude ++ "module go(tau, at) = tween(from: 0, to: tau, at: at, over: 1s)\nout = go(1, c0)\n",
        prelude ++ "out = tween(from: 0, to: 1, at: c0, over: 1s)\n",
    );
    try expect_same(
        prelude ++ "tau = 5\nmodule turn(x) = x * tau\nout = turn(wave(sine, 1hz))\n",
        prelude ++ "tau = 5\nout = wave(sine, 1hz) * 6.283185307179586\n",
    );
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

// Locks section 3: where the file binds `tau`, `to: tau` is refused as a signal is, as before
// step 40; a name used above its declaration is refused so; a call does not fold where a number
// is due, even of numbers; a division by 0 and a result past f64 are refused, not infinities; a
// default that names its own parameter is not a number; and `pi` where a cue goes is a number.
test "what does not fold is refused, with the message it had" {
    const tween_hint = "write a number";
    const cases = [_]Expected{
        .{
            .source = prelude ++ "tau = 6.283185307179586\nout = tween(to: tau, at: c0, over: 1s, from: 0)\n",
            .code = .not_live,
            .message = "tween's `to` is fixed when it is built, so a signal cannot set it",
            .hint = tween_hint,
            .span = "tau",
        },
        .{
            .source = prelude ++ "out = pi * wave(sine, 1hz)\npi = 3\n",
            .code = .used_before_declared,
            .message = "`pi` is used before it is declared, on line 5",
            .hint = "move it up, or go through a delay",
            .span = "pi",
        },
        .{
            .source = prelude ++ "out = tween(from: 0, to: sin(pi), at: c0, over: 1s)\n",
            .code = .not_live,
            .message = "tween's `to` is fixed when it is built, so a signal cannot set it",
            .hint = tween_hint,
            .span = "sin(pi)",
        },
        .{
            .source = prelude ++ "out = map(wave(sine, 1hz), -1..1, to: 0..max(1, tau))\n",
            .code = .wrong_type,
            .message = "expected a range's end, found a call",
            .span = "max(1, tau)",
        },
        .{
            .source = prelude ++ "out = tween(from: 0, to: tau / (pi - pi), at: c0, over: 1s)\n",
            .code = .out_of_range,
            .message = "there is no division by 0",
            .hint = "a divisor is a number other than 0",
            .span = "(pi - pi)",
        },
        .{
            .source = prelude ++ "out = lanes(4 / 0, lane)\n",
            .code = .out_of_range,
            .message = "there is no division by 0",
            .hint = "a divisor is a number other than 0",
            .span = "0",
        },
        .{
            .source = prelude ++ "out = tween(from: 0, to: 1e300 * 1e300, at: c0, over: 1s)\n",
            .code = .out_of_range,
            .message = "`1e300 * 1e300` is past what a number holds",
            .hint = "a number is finite; keep it within about 1.8e308",
            .span = "1e300 * 1e300",
        },
        .{
            .source = prelude ++ "out = lanes(tau, lane)\n",
            .code = .out_of_range,
            .message = "`count` is a whole number from 0 to 2^32",
            .span = "tau",
        },
        .{
            .source = prelude ++ "module bad(pi: pi) = pi\nout = bad()\n",
            .code = .wrong_type,
            .message = "the default of `pi` in bad is not a literal",
            .hint = "a default is a number, a time, or a frequency, such as `0.25s`",
            .span = "module bad(pi: pi) = pi",
        },
        .{
            .source = prelude ++ "out = tween(from: 0, to: 1, at: pi, over: 1s)\n",
            .code = .wrong_type,
            .message = "`pi` is a number, and not a name this file declares",
            .hint = "a number goes where a number or a signal is due",
            .span = "pi",
        },
    };
    for (cases) |case| try expect_one(case);
}

// Locks the format: `pi` and `tau` are names, kept as written, and their arithmetic is spaced as
// any arithmetic is, never folded to digits.
test "the format leaves pi and tau as written" {
    const messy = "x=lanes(97,lane*tau/96)\ny = tween(from:-pi,to:2*pi,at:c0,over:1s)\n";
    try testing.expect(syntax.parse_source(messy));
    var out: [256]u8 = undefined;
    const formatted = try syntax.format_into(&out);
    try testing.expectEqualStrings(
        "x = lanes(97, lane * tau / 96)\ny = tween(from: -pi, to: 2 * pi, at: c0, over: 1s)\n",
        formatted,
    );
}
