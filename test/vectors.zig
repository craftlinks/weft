//! Vectors and colour (step 16) against the scalar files they stand for: a `vec2` spring is two
//! scalar springs side by side, bit for bit, and a colour is its OKLab components.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Equality
//! The back end builds a vector motion as one scalar node a component, then packs them
//! (`graph.zig` of the language, section 6). So each test compiles a file with vectors and the
//! same file written per component, reads both at the same times, and compares the bits: every
//! component of the vector against its scalar twin.
//!
//! ## 2. Errors
//! Each shape error has a case with its code and the place it points at, so a message that
//! regresses to a crash, a wrong code, or a builder refusal fails here.

const std = @import("std");
const testing = std.testing;
const weft = @import("weft");
const diagnostic = weft.lang.diagnostic;
const colour = weft.colour;

const limits: weft.lang.Limits = .{
    .tokens = 1024,
    .tree = 512,
    .names = 64,
    .nodes = 96,
    .slab = 256,
    .cues = 8,
    .goals = 32,
    .regions = 8,
    .tracks = 4,
    .track_samples = 4,
    .modules = 8,
};
const Compiled = weft.lang.Compiled(limits);

var vectors: Compiled = undefined;
var scalars: Compiled = undefined;
var failing: Compiled = undefined;
var vector_slab: [limits.slab]f64 = undefined;
var scalar_slab: [limits.slab]f64 = undefined;

const prelude = "seed 5\ncue c0 = 0s\ncue c1 = 1s\ncue c2 = 2.5s\n";

fn seconds(count: f64) weft.Time {
    return .{ .flicks = @intFromFloat(@round(count * @as(f64, @floatFromInt(weft.time.flicks_per_second)))) };
}

fn report(compiled: *const Compiled, source: []const u8, err: anyerror) anyerror {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (compiled.errors()) |found| found.render(source, "test", &writer) catch {};
    std.debug.print("{s}", .{writer.buffered()});
    return err;
}

/// A vector signal and the scalar signals of its components, by name.
const Pair = struct { vector: []const u8, components: []const []const u8 };

/// Compiles both files and reads every pair at each time forwards, then backwards: each
/// component of the vector has the bits of its scalar twin.
fn expect_same(vector_text: []const u8, scalar_text: []const u8, pairs: []const Pair) !void {
    vectors.compile(vector_text) catch |err| return report(&vectors, vector_text, err);
    scalars.compile(scalar_text) catch |err| return report(&scalars, scalar_text, err);
    var a = weft.State.init(vectors.program, vector_slab[0..vectors.program.slab_count]);
    var b = weft.State.init(scalars.program, scalar_slab[0..scalars.program.slab_count]);
    const times = [_]f64{ 0, 0.1, 0.5, 0.99, 1, 1.25, 2, 2.5, 3, 4.75, 6, 2.2, 0.3 };
    for (times) |at| {
        a.eval(seconds(at));
        b.eval(seconds(at));
        for (pairs) |pair| {
            const read = a.values(vectors.signal(pair.vector).?);
            try testing.expectEqual(pair.components.len, read.len);
            for (pair.components, read) |name, value| {
                const expected = b.value(scalars.signal(name).?);
                if (@as(u64, @bitCast(expected)) != @as(u64, @bitCast(value))) {
                    std.debug.print("{s} against {s} at {d} s: {d} and {d}\n", .{ pair.vector, name, at, value, expected });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

// Locks section 1 for springs and Newtonian moves: a vector path with a vector `from`, and one
// with a scalar `from` broadcast, read their scalar twins' bits.
test "a vector spring is its scalar springs side by side" {
    try expect_same(prelude ++
        \\p = spring([c0: vec2(0, 1), c1: vec2(1, -1), c2: vec2(0.25, 0.5)], from: vec2(0.5, 0), time: 0.5s, overshoot: 0.3)
        \\n = newtonian([c0: vec3(0, 1, 2), c1: vec3(2, 0, 1)], from: 1, speed: 2, accel: 4, decel: 3)
        \\
    , prelude ++
        \\px = spring([c0: 0, c1: 1, c2: 0.25], from: 0.5, time: 0.5s, overshoot: 0.3)
        \\py = spring([c0: 1, c1: -1, c2: 0.5], from: 0, time: 0.5s, overshoot: 0.3)
        \\nx = newtonian([c0: 0, c1: 2], from: 1, speed: 2, accel: 4, decel: 3)
        \\ny = newtonian([c0: 1, c1: 0], from: 1, speed: 2, accel: 4, decel: 3)
        \\nz = newtonian([c0: 2, c1: 1], from: 1, speed: 2, accel: 4, decel: 3)
        \\
    , &.{
        .{ .vector = "p", .components = &.{ "px", "py" } },
        .{ .vector = "n", .components = &.{ "nx", "ny", "nz" } },
    });
}

// Locks section 1 node for node: a vector spring is the scalar springs, then one pack, and a
// component of the pack is the picked input itself, with no node of its own.
test "a vector spring is its scalar springs' nodes and a pack" {
    const vector_text = prelude ++
        \\p = spring([c0: vec2(0, 1), c1: vec2(1, -1)], from: vec2(0.5, 0), time: 0.5s)
        \\py = p.y
        \\
    ;
    const scalar_text = prelude ++
        \\px = spring([c0: 0, c1: 1], from: 0.5, time: 0.5s)
        \\py = spring([c0: 1, c1: -1], from: 0, time: 0.5s)
        \\
    ;
    vectors.compile(vector_text) catch |err| return report(&vectors, vector_text, err);
    scalars.compile(scalar_text) catch |err| return report(&scalars, scalar_text, err);
    const nodes = vectors.program.nodes;
    try testing.expectEqual(scalars.program.nodes.len + 1, nodes.len);
    for (scalars.program.nodes, nodes[0..scalars.program.nodes.len]) |expected, actual| {
        try testing.expect(std.meta.eql(expected, actual));
    }
    try testing.expectEqual(weft.graph.Op.pack, std.meta.activeTag(nodes[nodes.len - 1].op));
    try testing.expectEqual(scalars.signal("py").?, vectors.signal("py").?);
}

// Locks section 1 for tweens, chases, maps, and arithmetic: a chained vector tween, a chase of
// packed noises, a map, and a scalar broadcast in a sum and a product.
test "vector tweens, chases, maps, and arithmetic are per component" {
    try expect_same(prelude ++
        \\first = tween(from: vec2(0, 1), to: vec2(1, 0), at: c0, over: 1s, ease: in_out)
        \\then = tween(from: vec2(1, 0), to: vec2(-1, 2), at: c1, over: 1s, after: first)
        \\noises = vec2(noise(smooth, 1hz, seed: 1), noise(smooth, 2hz, seed: 2))
        \\chased = chase(noises, time: 0.3s, overshoot: 0.2)
        \\mapped = map(chased, from: -1..1, to: 0..10)
        \\sum = then * 2 + noises.y - 0.5
        \\
    , prelude ++
        \\fx = tween(from: 0, to: 1, at: c0, over: 1s, ease: in_out)
        \\fy = tween(from: 1, to: 0, at: c0, over: 1s, ease: in_out)
        \\tx = tween(from: 1, to: -1, at: c1, over: 1s, after: fx)
        \\ty = tween(from: 0, to: 2, at: c1, over: 1s, after: fy)
        \\a = noise(smooth, 1hz, seed: 1)
        \\b = noise(smooth, 2hz, seed: 2)
        \\cx = chase(a, time: 0.3s, overshoot: 0.2)
        \\cy = chase(b, time: 0.3s, overshoot: 0.2)
        \\mx = map(cx, from: -1..1, to: 0..10)
        \\my = map(cy, from: -1..1, to: 0..10)
        \\sx = tx * 2 + b - 0.5
        \\sy = ty * 2 + b - 0.5
        \\
    , &.{
        .{ .vector = "then", .components = &.{ "tx", "ty" } },
        .{ .vector = "noises", .components = &.{ "a", "b" } },
        .{ .vector = "chased", .components = &.{ "cx", "cy" } },
        .{ .vector = "mapped", .components = &.{ "mx", "my" } },
        .{ .vector = "sum", .components = &.{ "sx", "sy" } },
    });
}

// Locks the components as outputs: `.x .y .z` of a vector and `.l .a .b` of a colour read the
// component, from a name, from a call, and through a module's parameter.
test "a component of a vector or a colour is a signal" {
    try expect_same(prelude ++
        \\module second(v) = v.y
        \\p = spring([c0: vec3(0, 1, 2), c1: vec3(3, 4, 5)], time: 0.5s)
        \\c = chase(oklab(0.5, 0.1, -0.1), time: 0.5s)
        \\parts = vec3(p.z, c.a, map(p, from: 0..1, to: 0..2).x)
        \\through = vec2(second(p), second(vec2(c.l, c.b)))
        \\
    , prelude ++
        \\pz = spring([c0: 2, c1: 5], time: 0.5s)
        \\px = spring([c0: 0, c1: 3], time: 0.5s)
        \\py = spring([c0: 1, c1: 4], time: 0.5s)
        \\ca = chase(0.1, time: 0.5s)
        \\cb = chase(-0.1, time: 0.5s)
        \\mx = map(px, from: 0..1, to: 0..2)
        \\
    , &.{
        .{ .vector = "parts", .components = &.{ "pz", "ca", "mx" } },
        .{ .vector = "through", .components = &.{ "py", "cb" } },
    });
}

// Locks the colour of section 8 of the checker: `srgb` is OKLab at compile time, a colour tween
// passes through OKLab's middle, and both ends come back to their sRGB.
test "a colour is OKLab, converted from sRGB at compile time" {
    const text = prelude ++
        \\orange = srgb(1, 0.5, 0)
        \\sweep = tween(from: srgb(1, 0.5, 0), to: srgb(0, 0.25, 1), at: c0, over: 2s)
        \\
    ;
    vectors.compile(text) catch |err| return report(&vectors, text, err);
    var state = weft.State.init(vectors.program, vector_slab[0..vectors.program.slab_count]);
    const from = colour.from_srgb(.{ 1, 0.5, 0 });
    const to = colour.from_srgb(.{ 0, 0.25, 1 });
    state.eval(seconds(0));
    try testing.expectEqualSlices(f64, &from, state.values(vectors.signal("orange").?));
    try testing.expectEqualSlices(f64, &from, state.values(vectors.signal("sweep").?));
    state.eval(seconds(1));
    const middle = state.values(vectors.signal("sweep").?);
    for (middle, from, to) |value, a, b| try testing.expectApproxEqAbs((a + b) / 2, value, 1e-12);
    state.eval(seconds(2));
    const drawn = colour.to_srgb(state.values(vectors.signal("sweep").?)[0..3].*);
    for (drawn, [_]f64{ 0, 0.25, 1 }) |value, expected| try testing.expectApproxEqAbs(expected, value, 1e-9);
}

/// The first diagnostic of a file that must not compile.
fn first_error(source: []const u8) !weft.lang.Diagnostic {
    failing.compile(source) catch {
        const errors = failing.errors();
        try testing.expect(errors.len > 0);
        return errors[0];
    };
    return error.TestUnexpectedResult;
}

const Case = struct { text: []const u8, code: diagnostic.Code, at: []const u8 };

// Locks section 2: each shape error has its code and points at what is wrong, never at the
// builder, so no shape reaches the back end unchecked.
test "a shape that does not fit is an error where it is written" {
    const cases = [_]Case{
        .{ .text = "a = vec2(1, 2) + vec3(1, 2, 3)\n", .code = .wrong_shape, .at = "vec2(1, 2) + vec3(1, 2, 3)" },
        .{ .text = "a = vec3(1, 2, 3) * oklab(0.5, 0, 0)\n", .code = .wrong_shape, .at = "vec3(1, 2, 3) * oklab(0.5, 0, 0)" },
        .{ .text = "a = chase(1, time: vec2(1, 2))\n", .code = .wrong_shape, .at = "vec2(1, 2)" },
        .{ .text = "a = follow([0..1], by: spring(time: vec2(1, 1)))\n", .code = .wrong_shape, .at = "vec2(1, 1)" },
        .{ .text = "a = oscillator(sine, rate: vec2(1, 2))\n", .code = .wrong_shape, .at = "vec2(1, 2)" },
        .{ .text = "fb = delay(0)\nfb <- vec2(1, 2)\n", .code = .wrong_shape, .at = "vec2(1, 2)" },
        .{ .text = "a = spring([c0: vec2(0, 1), c1: 2], time: 1s)\n", .code = .wrong_shape, .at = "2" },
        .{ .text = "a = spring([c0: vec2(0, 1)], from: vec3(0, 0, 0), time: 1s)\n", .code = .wrong_shape, .at = "spring([c0: vec2(0, 1)], from: vec3(0, 0, 0), time: 1s)" },
        .{ .text = "a = spring([c0: 1], from: vec2(0, 0), time: 1s)\n", .code = .wrong_shape, .at = "spring([c0: 1], from: vec2(0, 0), time: 1s)" },
        .{ .text = "a = newtonian([c0: 1], from: srgb(1, 1, 1), speed: 1, accel: 1, decel: 1)\n", .code = .wrong_shape, .at = "newtonian([c0: 1], from: srgb(1, 1, 1), speed: 1, accel: 1, decel: 1)" },
        .{ .text = "a = tween(from: vec2(0, 1), to: vec3(1, 1, 1), at: c0, over: 1s)\n", .code = .wrong_shape, .at = "tween(from: vec2(0, 1), to: vec3(1, 1, 1), at: c0, over: 1s)" },
        .{ .text = "a = tween(from: 0, to: 1, at: c0, over: 1s, after: oklab(1, 0, 0))\n", .code = .wrong_shape, .at = "tween(from: 0, to: 1, at: c0, over: 1s, after: oklab(1, 0, 0))" },
        .{ .text = "moves = [c0: vec2(0, 1)]\na = follow(moves)\n", .code = .wrong_type, .at = "moves" },
        .{ .text = "a = vec2(1, 2)\nb = a.z\n", .code = .unknown_output, .at = "z" },
        .{ .text = "a = oklab(0.5, 0, 0)\nb = a.x\n", .code = .unknown_output, .at = "x" },
        .{ .text = "a = srgb(1.5, 0, 0)\n", .code = .out_of_range, .at = "1.5" },
        .{ .text = "a = tween(from: srgb(0, 0, -1), to: 1, at: c0, over: 1s)\n", .code = .out_of_range, .at = "srgb(0, 0, -1)" },
    };
    for (cases) |case| {
        const text = try std.mem.concat(testing.allocator, u8, &.{ prelude, case.text });
        defer testing.allocator.free(text);
        const found = first_error(text) catch |err| {
            std.debug.print("compiled: {s}\n", .{case.text});
            return err;
        };
        const pointed = text[found.start..][0..found.len];
        if (found.code != case.code or !std.mem.eql(u8, pointed, case.at)) {
            std.debug.print("{s}: {s} at `{s}`: {s}\n", .{ case.text, @tagName(found.code), pointed, found.message_text() });
            return error.TestUnexpectedResult;
        }
    }
}

// Locks the carry of step 15 across vectors: a pure edit keeps the reader of a vector chase, a
// simulated node a component, which then reads what a fresh reader reads.
test "a file of vectors carries across a pure edit" {
    const chase = "p = chase(vec2(noise(smooth, 1hz, seed: 1), wave(sine, 0.5hz)), time: 0.3s, overshoot: 0.2)\n";
    const before = prelude ++ chase ++ "w = wave(sine, 1hz)\n";
    const after = prelude ++ "w = wave(sine, 2hz) * vec2(1, 2)\n" ++ chase;
    vectors.compile(before) catch |err| return report(&vectors, before, err);
    scalars.compile(after) catch |err| return report(&scalars, after, err);
    var old_state = weft.State.init(vectors.program, vector_slab[0..vectors.program.slab_count]);
    old_state.eval(seconds(3));
    var carried = weft.State.init(scalars.program, scalar_slab[0..scalars.program.slab_count]);
    try testing.expect(scalars.carry(&carried, &vectors, &old_state));
    var fresh_slab: [limits.slab]f64 = undefined;
    var fresh = weft.State.init(scalars.program, fresh_slab[0..scalars.program.slab_count]);
    for ([_]f64{ 3, 3.5, 1, 4 }) |at| {
        carried.eval(seconds(at));
        fresh.eval(seconds(at));
        for ([_][]const u8{ "p", "w" }) |name| {
            const id = scalars.signal(name).?;
            try testing.expectEqualSlices(f64, fresh.values(id), carried.values(id));
        }
    }
}
