//! Sharing (step 50): a number or a pure call written twice is built once, so the readable way to
//! write a file costs no more nodes than the one with names bound by hand.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What Is Shared
//! The back end looks each pure node up before it builds it (`src/graph.zig`, section 10): a
//! constant of the same bits, a sum, product, `min`, `max`, function, `map`, `pick`, or `pack` of
//! the same nodes, and a `wave`, `tween`, `lane`, or `spread` of the same fields in the same
//! region. Each test gives a file, its node count and slab, and which names are one node.
//!
//! ## 2. What Is Never Shared
//! A seeded, simulated, live, or event-firing node is its declaration's own, so two lines written
//! alike are two nodes and two sources of events. A recompile still carries a simulated node
//! when a line before it shares differently, since `twins` pairs only the nodes that keep state.

const std = @import("std");
const testing = std.testing;
const weft = @import("weft");
const jig = @import("jig");
const weft_text = @import("weft_text");

const limits: weft_text.Limits = .{
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
};
const Compiled = weft_text.Compiled(limits);
const checkpoint_seconds = 8;

var compiled: Compiled = undefined;
var other: Compiled = undefined;

const Reader = struct {
    slab: [limits.slab]f64,
    checkpoints: [checkpoint_seconds * limits.slab]f64,
    state: weft.State,

    fn start(reader: *Reader, program: weft.Program) void {
        const size = program.slab_count;
        const checkpoints = reader.checkpoints[0 .. checkpoint_seconds * size];
        reader.state = .init_with_checkpoints(program, reader.slab[0..size], checkpoints);
    }
};

var old_reader: Reader = undefined;
var carried: Reader = undefined;
var fresh: Reader = undefined;

fn seconds(count: f64) weft.Time {
    const per_second: f64 = @floatFromInt(weft.time.flicks_per_second);
    return .{ .flicks = @intFromFloat(@round(count * per_second)) };
}

fn bits(value: f64) u64 {
    return @bitCast(value);
}

/// Compiles `source` into `into`, printing its errors if it does not compile.
fn compile(into: *Compiled, source: []const u8) !void {
    into.compile(source) catch |err| {
        var buffer: [2048]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        for (into.errors()) |found| found.render(source, "test", &writer) catch {};
        std.debug.print("{s}", .{writer.buffered()});
        return err;
    };
}

/// Compiles `source` and checks its node count and slab.
fn expect_counts(source: []const u8, nodes: usize, slab: u32) !void {
    try compile(&compiled, source);
    try testing.expectEqual(nodes, compiled.program.nodes.len);
    try testing.expectEqual(slab, compiled.program.slab_count);
}

/// The node of the signal `name`.
fn node_of(name: []const u8) weft.Node {
    return compiled.program.nodes[compiled.signal(name).?.index];
}

// Locks a number written twice: `w * 2` and `w * 2 + 2` are 4 nodes, the wave, 2, the product,
// and the sum, where they were 6; `b`'s sum adds `a`'s product to the 2 that `a` multiplies by.
test "a number and a product written twice are one node each" {
    try expect_counts("w = wave(sine, 1hz)\na = w * 2\nb = w * 2 + 2\n", 4, 4);
    const sum = node_of("b").op.add;
    try testing.expectEqual(compiled.signal("a").?, sum.left);
    try testing.expectEqual(node_of("a").op.multiply.right, sum.right);
    try testing.expectEqual(bits(2), bits(compiled.program.nodes[sum.right.index].op.constant));
}

// Locks equal bits, not equal values: 0 and -0 are two constants, so `w + 0` and `w + -0` are 5
// nodes, and the constants' bits are +0 and -0.
test "0 and -0 are two constants" {
    try expect_counts("w = wave(sine, 1hz)\na = w + 0\nb = w + -0\n", 5, 5);
    const a = compiled.program.nodes[node_of("a").op.add.right.index].op.constant;
    const b = compiled.program.nodes[node_of("b").op.add.right.index].op.constant;
    try testing.expectEqual(bits(0), bits(a));
    try testing.expectEqual(bits(-0.0), bits(b));
}

// Locks a module used twice on one input: `m(w)` twice is one instance's 4 nodes, and `m(a)` adds
// only its product and sum, so 7 nodes where they were 13; `a` and `b` are one node.
test "a module used twice on one input is built once" {
    const source = "module m(x) = x * 2 + 1\nw = wave(sine, 1hz)\na = m(w)\nb = m(w)\nc = m(a)\n";
    try expect_counts(source, 7, 7);
    try testing.expectEqual(compiled.signal("a").?, compiled.signal("b").?);
    try testing.expect(compiled.signal("c").?.index != compiled.signal("a").?.index);
}

// Locks packs: `vec2(40, 6)` twice is one pack of the 40 and the 6, and `vec2(6, 40)` a pack of
// its own over the same two, 4 nodes and a slab of 6. `srgb(1, 0.5, 0)` twice is one pack of three
// constants, and `a.l + b.l` one sum of its lightness with itself: 5 nodes, a slab of 7.
test "a vector or a colour written twice is one pack" {
    try expect_counts("a = vec2(40, 6)\nb = vec2(40, 6)\nc = vec2(6, 40)\n", 4, 6);
    try testing.expectEqual(compiled.signal("a").?, compiled.signal("b").?);
    try testing.expect(compiled.signal("c").?.index != compiled.signal("a").?.index);
    try expect_counts("a = srgb(1, 0.5, 0)\nb = srgb(1, 0.5, 0)\nc = a.l + b.l\n", 5, 7);
    try testing.expectEqual(compiled.signal("a").?, compiled.signal("b").?);
    const sum = node_of("c").op.add;
    try testing.expectEqual(sum.left, sum.right);
}

// Locks the calls of a value: two `wave(sine, 1hz)` are one, and so are two `abs`, two `min` of
// one input and 0.5, and two `map`s of the same ranges; `max` shares the 0.5; `pow(w, 2)` and
// `pow(w, 3)` are two. 9 nodes: the waves, the saw, `abs`, 0.5, `min`, `max`, `map`, and the pows.
test "a function, min, max, or map of the same input is one node" {
    const source = "w = wave(sine, 1hz)\nv = wave(sine, 1hz)\nu = wave(saw, 1hz)\na = abs(w)\n" ++
        "b = abs(v)\nc = min(w, 0.5)\nd = min(v, 0.5)\ne = max(w, 0.5)\n" ++
        "f = map(w, from: -1..1, to: 0..1)\ng = map(v, from: -1..1, to: 0..1)\nh = pow(w, 2)\n" ++
        "i = pow(w, 3)\n";
    try expect_counts(source, 9, 9);
    const pairs = [_][2][]const u8{ .{ "w", "v" }, .{ "a", "b" }, .{ "c", "d" }, .{ "f", "g" } };
    for (pairs) |pair| {
        errdefer std.debug.print("{s} and {s}\n", .{ pair[0], pair[1] });
        try testing.expectEqual(compiled.signal(pair[0]).?, compiled.signal(pair[1]).?);
    }
    try testing.expect(compiled.signal("h").?.index != compiled.signal("i").?.index);
    try testing.expect(compiled.signal("u").?.index != compiled.signal("w").?.index);
}

// Locks that sharing is binding by hand: `w * 2` and `w * 2 + 2` build, node for node, the nodes
// of a file that binds the 2 as `two` and writes `b` as `a + two`.
test "sharing builds the nodes a file bound by hand builds" {
    try compile(&compiled, "w = wave(sine, 1hz)\na = w * 2\nb = w * 2 + 2\n");
    try compile(&other, "w = wave(sine, 1hz)\ntwo = 2\na = w * two\nb = a + two\n");
    try testing.expectEqual(other.program.nodes.len, compiled.program.nodes.len);
    for (other.program.nodes, compiled.program.nodes, 0..) |expected, actual, at| {
        errdefer std.debug.print("node {d}:\n  {any}\n  {any}\n", .{ at, expected, actual });
        try testing.expect(std.meta.eql(expected, actual));
    }
    for ([_][]const u8{ "w", "a", "b" }) |name| {
        try testing.expectEqual(other.signal(name).?, compiled.signal(name).?);
    }
}

// Locks a tween written twice: one node, and a tween over 2 s its own, so 2 nodes; `a` and `b`
// read 0, 0.5, and 1 at 0 s, 0.5 s, and 1 s.
test "a tween written twice is one node" {
    const source = "cue c0 = 0s\na = tween(from: 0, to: 1, at: c0, over: 1s)\n" ++
        "b = tween(from: 0, to: 1, at: c0, over: 1s)\n" ++
        "c = tween(from: 0, to: 1, at: c0, over: 2s)\n";
    try expect_counts(source, 2, 2);
    try testing.expectEqual(compiled.signal("a").?, compiled.signal("b").?);
    fresh.start(compiled.program);
    const expected = [_][2]f64{ .{ 0, 0 }, .{ 0.5, 0.5 }, .{ 1, 1 } };
    for (expected) |pair| {
        fresh.state.eval(seconds(pair[0]));
        try testing.expectEqual(bits(pair[1]), bits(fresh.state.value(compiled.signal("a").?)));
        try testing.expectEqual(bits(pair[1]), bits(fresh.state.value(compiled.signal("b").?)));
    }
}

// Locks regions: a staggered wave in two regions of 4 is one node of 4 lanes, and in a region of
// 5 one of its own, 2 nodes and a slab of 9. `lane * 2` in two regions of 4 is one lane and one
// product, and in a region of 5 a lane and a product of its own over the one 2: 5 nodes, a slab
// of 4 + 1 + 4 + 5 + 5 = 19.
test "a per-lane source is shared only in a region of its count" {
    const waves = "a = lanes(4, wave(sine, 1hz, stagger: 10ms))\n" ++
        "b = lanes(4, wave(sine, 1hz, stagger: 10ms))\n" ++
        "d = lanes(5, wave(sine, 1hz, stagger: 10ms))\n";
    try expect_counts(waves, 2, 9);
    try testing.expectEqual(compiled.signal("a").?, compiled.signal("b").?);
    try testing.expectEqual(@as(u32, 5), node_of("d").extent.lanes);
    const products = "a = lanes(4, lane * 2)\nb = lanes(4, lane * 2)\nc = lanes(5, lane * 2)\n";
    try expect_counts(products, 5, 19);
    try testing.expectEqual(compiled.signal("a").?, compiled.signal("b").?);
    try testing.expectEqual(node_of("a").op.multiply.right, node_of("c").op.multiply.right);
    try testing.expect(node_of("a").op.multiply.left.index != node_of("c").op.multiply.left.index);
}

// Locks the region as part of the key where the node has one lane: `e`'s wave, built in a region
// of 4 with no stagger, is one lane, spread to 4; `f`'s wave outside a region is its own; `g` is
// `e`. 3 nodes, a slab of 1 + 4 + 1 = 6.
test "a source built in a region is not the one built outside it" {
    const source = "e = lanes(4, wave(sine, 1hz))\nf = wave(sine, 1hz)\n" ++
        "g = lanes(4, wave(sine, 1hz))\n";
    try expect_counts(source, 3, 6);
    try testing.expectEqual(compiled.signal("e").?, compiled.signal("g").?);
    const spread = node_of("e").op.spread;
    try testing.expect(spread.index != compiled.signal("f").?.index);
    try testing.expectEqual(@as(u32, 1), compiled.program.nodes[spread.index].extent.lanes);
}

/// Compiles both files, reads `old_text`'s program to 2 s, and carries that reader into a reader
/// of `new_text`'s. Returns what `carry` returned.
fn carry(old_text: []const u8, new_text: []const u8) !bool {
    try compile(&other, old_text);
    try compile(&compiled, new_text);
    old_reader.start(other.program);
    var at: f64 = 0;
    while (at <= 2) : (at += 0.25) old_reader.state.eval(seconds(at));
    carried.start(compiled.program);
    fresh.start(compiled.program);
    return compiled.carry(&carried.state, &other, &old_reader.state);
}

// Locks `twins` (decision 7): in `old`, `b`'s `w * 2` is `a`'s, so `b` builds only its chase, 4
// nodes; in `new`, `a` is `w * 3`, so `b` builds 2, a product, and its chase, 6 nodes. `b` is
// unchanged, so the reader carries both ways, and `b` at 2.5 s from the carried state has the bits
// it has from a fresh reader.
test "a recompile carries a simulated node whose pure inputs are shared differently" {
    const old = "cue c0 = 0s\nw = wave(sine, 1hz)\na = w * 2\nb = chase(w * 2, time: 1s)\n";
    const new = "cue c0 = 0s\nw = wave(sine, 1hz)\na = w * 3\nb = chase(w * 2, time: 1s)\n";
    const texts = [_][2][]const u8{ .{ old, new }, .{ new, old } };
    const node_counts = [_][2]usize{ .{ 4, 6 }, .{ 6, 4 } };
    for (texts, node_counts) |pair, counts| {
        try testing.expect(try carry(pair[0], pair[1]));
        try testing.expectEqual(counts[0], other.program.nodes.len);
        try testing.expectEqual(counts[1], compiled.program.nodes.len);
        const b = compiled.signal("b").?;
        carried.state.eval(seconds(2.5));
        fresh.state.eval(seconds(2.5));
        try testing.expectEqual(bits(fresh.state.value(b)), bits(carried.state.value(b)));
        try testing.expect(carried.state.steps_run < fresh.state.steps_run);
    }
}

// Locks what is never shared: two bounces, noises, cues, springs, chases, and inputs written alike
// are two nodes each, with the wave 15 nodes and a slab of 29; a bounce's events come from its own
// node, so `a`'s and `b`'s sources differ.
test "a seeded, simulated, live, or event-firing node is never shared" {
    const source = "cue c0 = 0s\ncue c1 = 1s\na = bounce(0..1, speed: 0.5, at: c0)\n" ++
        "b = bounce(0..1, speed: 0.5, at: c0)\nn = noise(smooth, 1hz)\nm = noise(smooth, 1hz)\n" ++
        "p = cues(c0)\nq = cues(c0)\ns = spring([c1: 1], time: 0.5s)\n" ++
        "t = spring([c1: 1], time: 0.5s)\n" ++
        "w = wave(sine, 1hz)\nx = chase(w, time: 1s)\ny = chase(w, time: 1s)\n" ++
        "i = input(0..1, initial: 0)\nj = input(0..1, initial: 0)\n";
    try expect_counts(source, 15, 29);
    const pairs = [_][2][]const u8{
        .{ "a", "b" }, .{ "n", "m" }, .{ "p", "q" }, .{ "s", "t" }, .{ "x", "y" }, .{ "i", "j" },
    };
    for (pairs) |pair| {
        errdefer std.debug.print("{s} and {s}\n", .{ pair[0], pair[1] });
        try testing.expect(compiled.signal(pair[0]).?.index != compiled.signal(pair[1]).?.index);
    }
    var a_out: [weft.graph.components_max]weft.Id = undefined;
    var b_out: [weft.graph.components_max]weft.Id = undefined;
    const a_sources = compiled.event_sources("a", &a_out);
    const b_sources = compiled.event_sources("b", &b_out);
    try testing.expectEqual(@as(usize, 1), a_sources.len);
    try testing.expectEqual(@as(usize, 1), b_sources.len);
    try testing.expect(a_sources[0].index != b_sources[0].index);
}

const eight_limits: weft_text.Limits = .{
    .tokens = 1024,
    .tree = 1024,
    .names = 64,
    .nodes = 8,
    .slab = 1024,
    .cues = 8,
    .goals = 8,
    .regions = 4,
    .tracks = 2,
    .track_samples = 4,
};
var eight: weft_text.Compiled(eight_limits) = undefined;
var lent_nodes: [32]weft.Node = undefined;
var lent_shared: [2 * lent_nodes.len]weft_text.back_end.Shared = undefined;

/// Nine bindings of a wave and eight sums of 1, which share the 1: 10 nodes.
const nine = "a = wave(sine, 1hz)\nb = a + 1\nc = b + 1\nd = c + 1\ne = d + 1\nf = e + 1\n" ++
    "g = f + 1\nh = g + 1\ni = h + 1\n";

/// `count` lines `aK = wave(sine, 1hz) + K`, the wave shared and each K its own, then `last = 64`:
/// 3 + 2 * (count - 1) + 1 nodes, every one of them in the sharing table.
fn distinct_numbers(comptime count: u32) []const u8 {
    comptime var text: []const u8 = "";
    inline for (1..count + 1) |k| {
        text = text ++ std.fmt.comptimePrint("a{d} = wave(sine, 1hz) + {d}\n", .{ k, k });
    }
    return text ++ "last = 64\n";
}

// Locks that the count pass shares too: `nine` past 8 nodes is counted at 10 nodes and a slab of
// 10. 31 lines of distinct numbers and one more are exactly the 64 nodes of a `.nodes = 64`
// `Compiled`, every node in the table at once; a 32nd line is past it.
test "the count shares, and a full node array fills the table" {
    try testing.expectError(error.Invalid, eight.compile(nine));
    const counted = eight.count_program(.{ .nodes = &lent_nodes, .shared = &lent_shared });
    try testing.expect(counted == .program);
    try testing.expectEqual(@as(usize, 10), counted.program.nodes.len);
    try testing.expectEqual(@as(u32, 10), counted.program.slab_count);

    try expect_counts(distinct_numbers(31), 64, 64);
    try testing.expectError(error.Invalid, compiled.compile(distinct_numbers(32)));
    try testing.expectEqual(jig.diagnostic.Code.limit, compiled.errors()[0].code);
}
