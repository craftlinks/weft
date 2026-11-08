//! Modules (step 13) against the graphs written by hand: an instance is the graph its body would
//! make, node for node, so a module adds nothing a hand-written file does not have.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Equality
//! Two files are compiled, one with modules and one written out, and their nodes are compared
//! with `std.meta.eql`, field by field, as `lang.zig` compares the catalog. A module whose body is
//! seeded cannot equal a hand-written file, since its seeds come from the instance, so those are
//! checked by their samples instead: two instances differ, and an instance does not change when
//! another line is added.
//!
//! ## 2. Errors
//! Each error a module can raise has a case with its code, so a message that regresses to a crash
//! or a wrong code fails here. The fuzz test in `lang.zig` covers the bytes in between.

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
    .libraries = 2,
};
const Compiled = weft.lang.Compiled(limits);

var with_modules: Compiled = undefined;
var by_hand: Compiled = undefined;
var failing: Compiled = undefined;

const std_library: []const weft.lang.Source = &.{.{ .name = "std", .text = weft.lang.std_library }};
const prelude = "cue c0 = 0s\ncue c1 = 2s\nmoves = [c1: 1]\n";

/// Compiles `modules` (with the standard library) and `hand`, and checks they are the same
/// program with the same `out`.
fn expect_same(modules: []const u8, hand: []const u8) !void {
    with_modules.compile_with(std_library, modules) catch |err| return report(&with_modules, modules, err);
    by_hand.compile(hand) catch |err| return report(&by_hand, hand, err);
    const a = with_modules.program;
    const b = by_hand.program;
    try testing.expectEqual(b.nodes.len, a.nodes.len);
    for (b.nodes, a.nodes, 0..) |expected, actual, at| {
        if (!std.meta.eql(expected, actual)) {
            std.debug.print("node {d}:\n  {any}\n  {any}\n", .{ at, expected, actual });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(by_hand.signal("out").?, with_modules.signal("out").?);
}

fn report(compiled: *const Compiled, source: []const u8, err: anyerror) anyerror {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (compiled.errors()) |found| found.render(source, "test", &writer) catch {};
    std.debug.print("{s}", .{writer.buffered()});
    return err;
}

/// The first diagnostic of a file that must not compile.
fn first_error(libraries: []const weft.lang.Source, source: []const u8) !weft.lang.Diagnostic {
    failing.compile_with(libraries, source) catch {
        const errors = failing.errors();
        try testing.expect(errors.len > 0);
        return errors[0];
    };
    return error.TestUnexpectedResult;
}

// Locks section 1: a library module, the same module declared in the file below its use, and
// the graph written out are one program.
test "a module's instance equals the graph written by hand" {
    const hand = prelude ++ "out = spring(moves, time: 0.25s)\n";
    try expect_same("use std\n" ++ prelude ++ "out = snappy(moves)\n", hand);
    try expect_same(prelude ++ "out = snappy_1(moves)\nmodule snappy_1(goal) = spring(goal, time: 0.25s)\n", hand);
}

// Locks a default, the default overridden by name, and every module of the standard library.
test "defaults, named arguments, and the standard library expand as written" {
    try expect_same("use std\n" ++ prelude ++ "out = heavy(moves)\n", prelude ++ "out = spring(moves, time: 0.9s, overshoot: 0.1)\n");
    try expect_same("use std\n" ++ prelude ++ "out = heavy(moves, time: 0.5s)\n", prelude ++ "out = spring(moves, time: 0.5s, overshoot: 0.1)\n");
    try expect_same("use std\nout = breathe(1, 0.1)\n", "out = 1 * (1 + 0.1 * wave(sine, 0.2hz))\n");
    try expect_same("use std\nout = bob(2)\n", "out = 2 + 0.1 * wave(sine, 1hz)\n");
}

// Locks section 6: a module inside its own argument is not a cycle, a module whose body is a
// mover goes in `by:`, and a bounce's outputs pass through a module bound to a name.
test "nesting, movers, and outputs through a module" {
    try expect_same(
        "module twice(x) = x * 2\nout = twice(twice(wave(sine, 1hz)))\n",
        "out = wave(sine, 1hz) * 2 * 2\n",
    );
    try expect_same(
        "cue c0 = 0s\nmodule wobble(t: 0.3s) = spring(time: t)\nout = follow([0..1], by: wobble(), seed: 3)\n",
        "cue c0 = 0s\nout = follow([0..1], by: spring(time: 0.3s), seed: 3)\n",
    );
    try expect_same(
        "cue c0 = 0s\nmodule hop(s, at) = bounce(0..1, speed: s, at: at)\nb = hop(0.7, c0)\nout = b.velocity * 2\n",
        "cue c0 = 0s\nb = bounce(0..1, speed: 0.7, at: c0)\nout = b.velocity * 2\n",
    );
}

// Locks section 6: the path of a cycle, from the first call to the module that repeats.
test "a module cycle is refused with the path through it" {
    const found = try first_error(&.{}, "module a(x) = b(x)\nmodule b(x) = a(x)\nout = a(1)\n");
    try testing.expectEqual(diagnostic.Code.module_cycle, found.code);
    try testing.expectEqualStrings("the cycle is a -> b -> a; break it with a parameter or a primitive", found.hint_text());
}

// Locks each module error's code, including the two the fuzz test found: a default that names
// its own parameter, and an argument to a module with none.
test "module errors name the parameter, the argument, or the library" {
    const Failing = struct { source: []const u8, code: diagnostic.Code };
    const cases = [_]Failing{
        .{ .source = "module m(x) = x * 2\nout = m()\n", .code = .missing_argument },
        .{ .source = "module m(x) = x * 2\nout = m(1, y: 2)\n", .code = .unknown_parameter },
        .{ .source = "module m(x) = x * 2\nout = m(1, x: 2)\n", .code = .duplicate_argument },
        .{ .source = "module m() = 1\nout = m(1)\n", .code = .too_many_positional },
        .{ .source = "module m(x: x) = x\nout = m()\n", .code = .wrong_type },
        .{ .source = "cue c0 = 0s\nmodule m(x) = x + c0\nout = m(1)\n", .code = .not_a_parameter },
        .{ .source = "use nope\nout = 1\n", .code = .unknown_library },
        .{ .source = "module wave(x) = x\nout = 1\n", .code = .reserved_name },
        .{ .source = "module m(x) = x\nmodule m(y) = y\nout = 1\n", .code = .duplicate_name },
        .{ .source = "module twice(x) in 0..1 = x * 2\nout = twice(1)\n", .code = .out_of_range },
    };
    for (cases) |case| {
        errdefer std.debug.print("case: {s}\n", .{case.source});
        const found = try first_error(&.{}, case.source);
        try testing.expectEqual(case.code, found.code);
    }
}

// Locks section 6: an error inside a library's body is reported on the file's call, not at a
// byte offset into the library's text.
test "a library's errors are reported at the file's call site" {
    const source = "use bad\nout = f(1)\n";
    const found = try first_error(&.{.{ .name = "bad", .text = "module f(x) = x + nope\n" }}, source);
    try testing.expectEqual(diagnostic.Code.not_a_parameter, found.code);
    try testing.expectEqual(@as(u32, @intCast(std.mem.indexOf(u8, source, "f(1)").?)), found.start);
}

// Locks the declared range: kept, the program builds; broken, the error names the module.
test "a declared range is checked after the build" {
    try with_modules.compile("module half(x) in -1..1 = x * 0.5\nout = half(1)\n");
    const found = try first_error(&.{}, "module twice(x) in 0..1 = x * 2\nout = twice(1)\n");
    try testing.expectEqualStrings("twice's output reaches 2..2, outside its declared 0..1", found.message_text());
}

// Locks section 6's seeds: two instances of one seeded module differ, and an instance keeps its
// samples when another declaration is added above it.
test "each instance has its own seeds, which other lines do not move" {
    const jitter = "module jitter(a) = a * noise(smooth, 1hz)\n";
    try with_modules.compile(jitter ++ "x = jitter(1)\ny = jitter(1)\n");
    try by_hand.compile(jitter ++ "w = wave(sine, 1hz) + jitter(1)\ny = jitter(1)\n");
    var slab_a: [limits.slab]f64 = undefined;
    var slab_b: [limits.slab]f64 = undefined;
    var a = weft.State.init(with_modules.program, slab_a[0..with_modules.program.slab_count]);
    var b = weft.State.init(by_hand.program, slab_b[0..by_hand.program.slab_count]);
    var differ = false;
    for (0..32) |index| {
        const time: weft.Time = .{ .flicks = @as(i64, @intCast(index)) * 52_920_000 };
        a.eval(time);
        b.eval(time);
        const x = a.value(with_modules.signal("x").?);
        const y = a.value(with_modules.signal("y").?);
        if (x != y) differ = true;
        try testing.expectEqual(y, b.value(by_hand.signal("y").?));
    }
    try testing.expect(differ);
}

// Locks the canonical format of the standard library: it formats to its own bytes.
test "the standard library is canonical" {
    var syntax: weft.lang.Syntax(limits) = undefined;
    try testing.expect(syntax.parse_source(weft.lang.std_library));
    var out: [4096]u8 = undefined;
    try testing.expectEqualStrings(weft.lang.std_library, try syntax.format_into(&out));
}

// Locks section 6's sharing: a parameter used twice is one signal, so a seeded argument is one
// noise, not two, and the module builds the nodes `n + n` builds over a named `n`.
test "a parameter used twice is one signal" {
    try expect_same(
        "module twice_sum(x) = x + x\nout = twice_sum(noise(smooth, 1hz, seed: 4))\n",
        "n = noise(smooth, 1hz, seed: 4)\nout = n + n\n",
    );
}
