//! Lanes in the language (step 17) against the core program they stand for: `lanes(n, …)` builds
//! what the builder builds in a region of n, value for value.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Equality
//! The core's own test builds a family of every op lanes change and checks lane i against lane i
//! built alone (`src/core/graph_test/lanes.zig`). Here a file of lanes is compiled and the same
//! program is built by hand through the builder, with the file's seeds, and every lane of every
//! signal is compared bit for bit. The rest of the file checks what only the language does:
//! broadcasts, a spread region, a module in a region, a region of delays, and the carry.
//!
//! ## 2. Errors
//! Each lane error has a case with its code and the place it points at, so a message that
//! regresses to a crash, a wrong code, or a builder refusal fails here.

const std = @import("std");
const testing = std.testing;
const weft = @import("weft");
const diagnostic = weft.lang.diagnostic;
const graph = weft.graph;

const limits: weft.lang.Limits = .{
    .tokens = 1024,
    .tree = 512,
    .names = 64,
    .nodes = 96,
    .slab = 1 << 15,
    .cues = 8,
    .goals = 32,
    .regions = 8,
    .tracks = 4,
    .track_samples = 4,
    .modules = 8,
};
const Compiled = weft.lang.Compiled(limits);

var compiled: Compiled = undefined;
var other: Compiled = undefined;
var failing: Compiled = undefined;
var slab: [limits.slab]f64 = undefined;
var other_slab: [limits.slab]f64 = undefined;
var hand_slab: [limits.slab]f64 = undefined;

const prelude = "seed 5\ncue c0 = 0s\ncue c1 = 1s\n";

fn seconds(count: f64) weft.Time {
    return .{ .flicks = @intFromFloat(@round(count * @as(f64, @floatFromInt(weft.time.flicks_per_second)))) };
}

fn ms(count: i64) weft.Time {
    return .{ .flicks = @divExact(weft.time.flicks_per_second, 1000) * count };
}

fn report(which: *const Compiled, source: []const u8, err: anyerror) anyerror {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (which.errors()) |found| found.render(source, "test", &writer) catch {};
    std.debug.print("{s}", .{writer.buffered()});
    return err;
}

const family =
    \\path = [c0: 1, c1: 0.2]
    \\index = lanes(1000, lane)
    \\height = lanes(1000, noise(smooth, 1.5hz, seed: 9))
    \\sway = lanes(1000, wave(sine, 0.7hz, stagger: 3ms))
    \\rise = lanes(1000, tween(from: 0, to: 1, at: c0, over: 0.5s, ease: in_out, stagger: 2ms))
    \\pull = lanes(1000, spring(path, time: 0.6s, overshoot: 0.3, stagger: 2ms))
    \\hop = lanes(1000, bounce(0..1, speed: 0.9, at: c0, stagger: 1ms))
    \\target = index * 0.001 + height
    \\follower = chase(target, time: 0.4s, overshoot: 0.2)
    \\
;

const names = [_][]const u8{ "index", "height", "sway", "rise", "pull", "hop", "target", "follower" };

// Locks section 1: the file of lanes and the builder's region of 1,000 give every lane of every
// signal the same bits, at times forwards and back, and the same events.
test "lanes in the language build what the builder builds in a region" {
    const text = prelude ++ family;
    compiled.compile(text) catch |err| return report(&compiled, text, err);

    var times: [2]weft.Time = undefined;
    var cues = weft.Cues.init(&times);
    const c0 = try cues.add(.{ .flicks = 0 });
    const c1 = try cues.add(seconds(1));
    var goal_entries: [2]weft.motion.Goal = undefined;
    var goals = weft.motion.Goals.init(&goal_entries);
    const path = try goals.add(&.{ .{ .cue = c0, .value = 1 }, .{ .cue = c1, .value = 0.2 } });
    var nodes: [16]graph.Node = undefined;
    var builder = graph.Builder.init(&nodes, .{ .slab_count_max = limits.slab, .cues = &cues, .goals = goals.table(), .seed = 5 });
    builder.lanes = 1000;
    var ids: [names.len]graph.Id = undefined;
    ids[0] = try builder.lane();
    ids[1] = try builder.noise(.{ .shape = .smooth, .hz = 1.5, .seed = 9 });
    ids[2] = try builder.wave(.{ .shape = .sine, .hz = 0.7, .stagger = ms(3) });
    ids[3] = try builder.tween(.{ .from = 0, .to = 1, .duration = ms(500), .ease = .in_out, .start = c0, .previous = null, .stagger = ms(2) });
    ids[4] = try builder.spring(.{ .from = 0, .goals = path, .time = ms(600), .overshoot = 0.3, .stagger = ms(2) });
    ids[5] = (try builder.bounce(.{ .low = 0, .high = 1, .speed = 0.9, .start = c0, .stagger = ms(1) })).position;
    builder.lanes = null;
    ids[6] = try builder.add(try builder.multiply(ids[0], try builder.constant(0.001)), ids[1]);
    ids[7] = try builder.chase(.{ .target = ids[6], .from = 0, .time = ms(400), .overshoot = 0.2 });
    const program = builder.finish();

    var a = weft.State.init(compiled.program, slab[0..compiled.program.slab_count]);
    var b = weft.State.init(program, hand_slab[0..program.slab_count]);
    for ([_]f64{ 0, 0.1, 0.5, 0.99, 1, 1.25, 2, 3.5, 0.3 }) |at| {
        a.eval(seconds(at));
        b.eval(seconds(at));
        for (names, ids) |name, id| {
            const read = a.values(compiled.signal(name).?);
            try testing.expectEqual(@as(usize, 1000), read.len);
            for (read, b.values(id), 0..) |found, expected, lane| {
                if (@as(u64, @bitCast(expected)) != @as(u64, @bitCast(found))) {
                    std.debug.print("{s} lane {d} at {d} s: {d} and {d}\n", .{ name, lane, at, found, expected });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
    var events_a: [4096]weft.Event = undefined;
    var events_b: [4096]weft.Event = undefined;
    const found_a = a.events(.{ .flicks = 0 }, seconds(2), &events_a);
    const found_b = b.events(.{ .flicks = 0 }, seconds(2), &events_b);
    try testing.expectEqual(found_b.count, found_a.count);
    // The bounces' first hits, 1/0.9 s plus g ms, before 2 s for the first 889 lanes.
    try testing.expectEqual(@as(u32, 889), found_a.count);
    for (events_a[0..found_a.count], events_b[0..found_b.count]) |x, y| {
        try testing.expectEqual(y.time.flicks, x.time.flicks);
        try testing.expectEqual(y.instance, x.instance);
    }
}

// Locks section 1's broadcasts and spreads: a vector of a lane and a noise per lane, a region of
// numbers spread to its count a component at a time, a component of each lane, and a module whose
// noise is per lane inside a region and one value outside it.
test "a region spreads, broadcasts, and expands modules in it" {
    const text = prelude ++
        \\module jitter(x) = x + noise(smooth, 1hz) * 0.1
        \\p = lanes(3, vec2(lane, noise(smooth, 1hz)))
        \\q = lanes(3, vec2(1, 2))
        \\px = p.x
        \\j = lanes(5, jitter(lane))
        \\one = jitter(1)
        \\shared = wave(sine, 1hz)
        \\mixed = lanes(5, lane + shared)
        \\
    ;
    compiled.compile(text) catch |err| return report(&compiled, text, err);
    var state = weft.State.init(compiled.program, slab[0..compiled.program.slab_count]);
    state.eval(seconds(0.4));
    const p = state.values(compiled.signal("p").?);
    try testing.expectEqual(@as(usize, 6), p.len);
    for (0..3) |lane| try testing.expectEqual(@as(f64, @floatFromInt(lane)), p[2 * lane]);
    try testing.expect(p[1] != p[3] and p[3] != p[5]);
    try testing.expectEqualSlices(f64, &.{ 1, 2, 1, 2, 1, 2 }, state.values(compiled.signal("q").?));
    try testing.expectEqualSlices(f64, &.{ 0, 1, 2 }, state.values(compiled.signal("px").?));
    const j = state.values(compiled.signal("j").?);
    try testing.expectEqual(@as(usize, 5), j.len);
    for (j, 0..) |value, lane| try testing.expect(@abs(value - @as(f64, @floatFromInt(lane))) <= 0.1);
    try testing.expect(j[1] - 1 != j[2] - 2);
    try testing.expectEqual(@as(usize, 1), state.values(compiled.signal("one").?).len);
    const shared = state.value(compiled.signal("shared").?);
    for (state.values(compiled.signal("mixed").?), 0..) |value, lane| {
        try testing.expectEqual(@as(f64, @floatFromInt(lane)) + shared, value);
    }
}

// Locks section 1's region of delays: one delay a lane, fed as one, each settling at its own
// fixed point, and a feed of one lane broadcast to every lane.
test "a region of delays is fed as one delay" {
    const text = prelude ++
        \\fb = lanes(4, delay(0))
        \\fb <- lanes(4, lane) + fb * 0.5
        \\flat = lanes(3, delay(0))
        \\flat <- 1 + flat * 0.5
        \\
    ;
    compiled.compile(text) catch |err| return report(&compiled, text, err);
    var state = weft.State.init(compiled.program, slab[0..compiled.program.slab_count]);
    state.eval(seconds(1));
    for (state.values(compiled.signal("fb").?), 0..) |value, lane| {
        try testing.expectApproxEqAbs(2 * @as(f64, @floatFromInt(lane)), value, 1e-9);
    }
    for (state.values(compiled.signal("flat").?)) |value| try testing.expectApproxEqAbs(@as(f64, 2), value, 1e-9);
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

// Locks section 2: each lane error has its code and points at what is wrong, never at the
// builder, so no lane count reaches the back end unchecked.
test "lanes that do not fit are an error where they are written" {
    const cases = [_]Case{
        .{ .text = "a = lane * 2\n", .code = .wrong_lanes, .at = "lane" },
        .{ .text = "a = wave(sine, 1hz, stagger: 2ms)\n", .code = .wrong_lanes, .at = "2ms" },
        .{ .text = "a = bounce(0..1, speed: 1, at: c0, stagger: -2ms)\n", .code = .wrong_lanes, .at = "-2ms" },
        .{ .text = "a = lanes(3, lanes(2, lane))\n", .code = .wrong_lanes, .at = "2" },
        .{ .text = "a = lanes(4, lane)\nb = lanes(5, lane)\nc = a + b\n", .code = .wrong_lanes, .at = "a + b" },
        .{ .text = "b = lanes(5, lane)\na = lanes(4, b + 1)\n", .code = .wrong_lanes, .at = "b" },
        .{ .text = "t = lanes(10, lane * 0.1 + 0.2)\nc = lanes(10, chase(lane, time: t))\n", .code = .wrong_lanes, .at = "t" },
        .{ .text = "r = lanes(3, lane + 1)\na = lanes(3, follow([0..1], by: spring(time: r)))\n", .code = .wrong_lanes, .at = "r" },
        .{ .text = "fb = delay(0)\nx = lanes(4, lane)\nfb <- x\n", .code = .wrong_lanes, .at = "x" },
        .{ .text = "fb = lanes(3, delay(0))\nfb <- lanes(4, lane)\n", .code = .wrong_lanes, .at = "lanes(4, lane)" },
        .{ .text = "a = lanes(0, 1)\n", .code = .out_of_range, .at = "0" },
        .{ .text = "a = lanes(2000000, 1)\n", .code = .out_of_range, .at = "2000000" },
        .{ .text = "lane = 3\n", .code = .reserved_name, .at = "lane" },
        .{ .text = "x = lanes(4, delay(0) + lane)\n", .code = .not_a_delay, .at = "lanes(4, delay(0) + lane)" },
        .{ .text = "x = delay(0) + 1\n", .code = .not_a_delay, .at = "delay(0) + 1" },
        .{ .text = "fb = delay(0)\nfb <- delay(1)\n", .code = .not_a_delay, .at = "delay(1)" },
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

// Locks the carry of step 15 across lanes: a pure edit keeps the reader of a chase of a thousand
// lanes, which then reads what a fresh reader reads; a change of its count starts it again.
test "a file of lanes carries across a pure edit" {
    const chase = "p = lanes(1000, chase(lane * 0.001 + noise(smooth, 1hz), time: 0.3s, overshoot: 0.2))\n";
    const before = prelude ++ chase ++ "w = wave(sine, 1hz)\n";
    const after = prelude ++ "w = lanes(7, wave(sine, 2hz, stagger: 10ms))\n" ++ chase;
    compiled.compile(before) catch |err| return report(&compiled, before, err);
    other.compile(after) catch |err| return report(&other, after, err);
    var old_state = weft.State.init(compiled.program, slab[0..compiled.program.slab_count]);
    old_state.eval(seconds(3));
    var carried = weft.State.init(other.program, other_slab[0..other.program.slab_count]);
    try testing.expect(other.carry(&carried, &compiled, &old_state));
    var fresh = weft.State.init(other.program, hand_slab[0..other.program.slab_count]);
    for ([_]f64{ 3, 3.5, 1, 4 }) |at| {
        carried.eval(seconds(at));
        fresh.eval(seconds(at));
        for ([_][]const u8{ "p", "w" }) |name| {
            const id = other.signal(name).?;
            try testing.expectEqualSlices(f64, fresh.values(id), carried.values(id));
        }
    }
    const fewer = prelude ++ "p = lanes(999, chase(lane * 0.001 + noise(smooth, 1hz), time: 0.3s, overshoot: 0.2))\n";
    other.compile(fewer) catch |err| return report(&other, fewer, err);
    var restarted = weft.State.init(other.program, other_slab[0..other.program.slab_count]);
    try testing.expect(!other.carry(&restarted, &compiled, &old_state));
}
