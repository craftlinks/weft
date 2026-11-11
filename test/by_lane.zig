//! A cue chosen by lane (step 28): `tween(…, at: beat[lane])` and the same for `bounce`, and a
//! series written as a list of times.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Core
//! A tween or a bounce whose `cue_by_lane` is set starts lane g of its region at cue
//! `start + g` (`graph.lane_cue`). So a by-lane node over n lanes must equal n one-lane nodes,
//! each at its own cue, bit for bit: the values of the tween and of both bounce outputs, and the
//! bounce's events merged in order with the overflow counted exactly. A slice built with
//! `lane_first` reads the family's own cues, a cue moved moves its lane only, and the builder
//! refuses a by-lane node outside a region or with a lane past the cue table.
//!
//! ## 2. The Language
//! `series[lane]` in the `at` of a `tween` or a `bounce` builds the node the builder builds, node
//! for node, through a module too, and a chain of tweens with `from` left out builds what the
//! longer text builds. Every refusal of the step has its code, its place, and its hint. A series
//! written as a list puts its cues in the table in order, and the formatter keeps both forms as
//! written.

const std = @import("std");
const testing = std.testing;
const weft = @import("weft");
const Event = weft.Event;
const Events = weft.Events;
const Id = weft.Id;
const State = weft.State;
const Time = weft.Time;

const flicks_per_second = weft.time.flicks_per_second;
const lanes_count = 8;
/// The family's cues, uneven: a pause after the fourth and after the sixth.
const cue_ms = [lanes_count]i64{ 1000, 1080, 1160, 1240, 1560, 1640, 2000, 2300 };
const over_ms = 300;

fn ms(count: i64) Time {
    return .{ .flicks = @divExact(flicks_per_second, 1000) * count };
}

var cue_times: [lanes_count]Time = undefined;
var cues: weft.Cues = undefined;

fn cue_table() !void {
    cues = weft.Cues.init(&cue_times);
    for (cue_ms) |at| _ = try cues.add(ms(at));
}

/// The family's nodes: a tween by lane, a bounce by lane (position and velocity), and, when
/// `with_chase`, a chase of the bounce, which makes the program simulated.
const Family = struct {
    tween: Id,
    position: Id,
    velocity: Id,
};

fn build_family(builder: *weft.Builder, lanes: u32, with_chase: bool) !Family {
    builder.lanes = lanes;
    const tween = try builder.tween(.{
        .from = 0,
        .to = 1,
        .duration = ms(over_ms),
        .ease = .out,
        .start = .{ .index = 0 },
        .previous = null,
        .cue_by_lane = true,
    });
    const ball = try builder.bounce(.{ .low = 0, .high = 1, .speed = 4, .start = .{ .index = 0 }, .cue_by_lane = true });
    if (with_chase) _ = try builder.chase(.{ .target = ball.position, .from = 0, .time = ms(200), .overshoot = 0.1 });
    builder.lanes = null;
    return .{ .tween = tween, .position = ball.position, .velocity = ball.velocity };
}

/// Lane g alone: the same tween and bounce in one lane, outside a region, at cue g.
fn build_alone(builder: *weft.Builder, g: u32) !Family {
    const tween = try builder.tween(.{
        .from = 0,
        .to = 1,
        .duration = ms(over_ms),
        .ease = .out,
        .start = .{ .index = g },
        .previous = null,
    });
    const ball = try builder.bounce(.{ .low = 0, .high = 1, .speed = 4, .start = .{ .index = g } });
    return .{ .tween = tween, .position = ball.position, .velocity = ball.velocity };
}

/// Times around every cue: a flick before, on it, a flick after, and halfway through its tween.
fn times_around(out: *[lanes_count * 4 + 2]Time) []const Time {
    var count: usize = 0;
    for (cue_ms) |at| {
        const cue = ms(at).flicks;
        for ([_]i64{ -1, 0, 1, ms(over_ms / 2).flicks }) |offset| {
            out[count] = .{ .flicks = cue + offset };
            count += 1;
        }
    }
    out[count] = ms(0);
    out[count + 1] = ms(4000);
    return out[0 .. count + 2];
}

fn by_event(_: void, a: Event, b: Event) bool {
    return weft.event.before(&a, &b);
}

var nodes: [16]weft.Node = undefined;
var slab: [256]f64 = undefined;
var alone_nodes: [4]weft.Node = undefined;
var alone_slab: [8]f64 = undefined;

// Locks section 1: a tween and a bounce by lane over 8 lanes at cues 1,000 to 2,300 ms equal 8
// one-lane graphs each at its own cue, bit for bit, the tween and both bounce outputs, at 34 times
// around every cue; the velocity flips exactly where the position hits a wall; and the family's
// events over [0, 4 s) are the 8 graphs' events merged in order (75 hits: a leg is 250 ms, so 11
// for each of the first four lanes, then 9, 9, 7, and 6), into buffers of 0, 5, and 75, with the
// rest counted exactly.
test "a tween and a bounce by lane equal one graph a lane, at its own cue" {
    try cue_table();
    var builder = weft.Builder.init(&nodes, .{ .slab_count_max = slab.len, .cues = &cues });
    const family = try build_family(&builder, lanes_count, false);
    const program = builder.finish();
    var state = State.init(program, slab[0..program.slab_count]);
    var time_buffer: [lanes_count * 4 + 2]Time = undefined;
    const times = times_around(&time_buffer);
    try testing.expectEqual(@as(usize, 34), times.len);

    var merged: [128]Event = undefined;
    var merged_count: usize = 0;
    const end = ms(4000);
    for (0..lanes_count) |lane| {
        const g: u32 = @intCast(lane);
        var alone_builder = weft.Builder.init(&alone_nodes, .{ .slab_count_max = alone_slab.len, .cues = &cues });
        const alone = try build_alone(&alone_builder, g);
        var reader = State.init(alone_builder.finish(), &alone_slab);
        for (times) |time| {
            state.eval(time);
            reader.eval(time);
            inline for (.{ "tween", "position", "velocity" }) |field| {
                const family_value = state.values(@field(family, field))[lane];
                try testing.expectEqual(@as(u64, @bitCast(reader.value(@field(alone, field)))), @as(u64, @bitCast(family_value)));
            }
        }
        var events: [32]Event = undefined;
        const found = reader.events(ms(0), end, &events);
        try testing.expectEqual(@as(u64, 0), found.dropped);
        for (events[0..found.count]) |event| {
            // The velocity changes sign exactly at a hit: a flick before it, it heads into the wall.
            reader.eval(.{ .flicks = event.time.flicks - 1 });
            try testing.expectEqual(event.value, reader.value(alone.velocity));
            reader.eval(event.time);
            try testing.expectEqual(-event.value, reader.value(alone.velocity));
            merged[merged_count] = event;
            merged[merged_count].source = family.position;
            merged[merged_count].instance = g;
            merged_count += 1;
        }
    }
    std.sort.block(Event, merged[0..merged_count], {}, by_event);
    try testing.expectEqual(@as(usize, 75), merged_count);
    for ([_]usize{ 0, 5, 75 }) |size| {
        var reader = State.init(program, slab[0..program.slab_count]);
        var out: [75]Event = undefined;
        const found = reader.events(ms(0), end, out[0..size]);
        try testing.expectEqual(Events{ .count = @intCast(size), .dropped = 75 - size }, found);
        try testing.expectEqualSlices(Event, merged[0..size], out[0..size]);
    }
}

// Locks the slice: the family built from lane 5 with three lanes, `lane_first = 5`, equals lanes 5
// to 7 of the whole, values at 34 times and events over [0, 4 s), 9 + 7 + 6 hits from cues 5 to 7.
test "a slice from lane 5 equals lanes 5 and up of the whole" {
    try cue_table();
    var builder = weft.Builder.init(&nodes, .{ .slab_count_max = slab.len, .cues = &cues });
    const whole = try build_family(&builder, lanes_count, false);
    const program = builder.finish();
    var state = State.init(program, slab[0..program.slab_count]);
    var slice_nodes: [16]weft.Node = undefined;
    var slice_slab: [64]f64 = undefined;
    var slice_builder = weft.Builder.init(&slice_nodes, .{ .slab_count_max = slice_slab.len, .cues = &cues, .lane_first = 5 });
    const slice = try build_family(&slice_builder, 3, false);
    const slice_program = slice_builder.finish();
    var reader = State.init(slice_program, slice_slab[0..slice_program.slab_count]);
    var time_buffer: [lanes_count * 4 + 2]Time = undefined;
    for (times_around(&time_buffer)) |time| {
        state.eval(time);
        reader.eval(time);
        inline for (.{ "tween", "position", "velocity" }) |field| {
            const all = state.values(@field(whole, field));
            try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(all[5..8]), std.mem.sliceAsBytes(reader.values(@field(slice, field))));
        }
    }
    var all_events: [128]Event = undefined;
    const all_found = state.events(ms(0), ms(4000), &all_events);
    var slice_events: [64]Event = undefined;
    const slice_found = reader.events(ms(0), ms(4000), &slice_events);
    var kept: usize = 0;
    for (all_events[0..all_found.count]) |event| {
        if (event.instance < 5) continue;
        try testing.expectEqual(event.time, slice_events[kept].time);
        try testing.expectEqual(event.instance, slice_events[kept].instance);
        try testing.expectEqual(event.value, slice_events[kept].value);
        kept += 1;
    }
    try testing.expectEqual(@as(usize, slice_found.count), kept);
    try testing.expectEqual(@as(usize, 22), kept);
}

var checkpoints: [8 * 256]f64 = undefined;

// Locks `Cues.move` by lane: on a reader with checkpoints of the family with a chase of the bounce,
// moving cue 3 from 1,240 to 1,200 ms changes lane 3's tween, bounce, and chase at 1,480 ms and its
// events over [0, 4 s), and leaves every other lane's values and events bit for bit.
test "moving one lane's cue moves that lane only" {
    try cue_table();
    var builder = weft.Builder.init(&nodes, .{ .slab_count_max = slab.len, .cues = &cues });
    const family = try build_family(&builder, lanes_count, true);
    const program = builder.finish();
    try testing.expect(program.simulated);
    const chase: Id = .{ .index = family.velocity.index + 1 };
    var state = State.init_with_checkpoints(program, slab[0..program.slab_count], &checkpoints);
    // Lane 3 is 240 ms past its old cue, rising at 0.96, and 280 ms past its new one, falling at
    // 0.88. (At 1,470 ms both would be at 0.92.)
    const at = ms(1480);
    state.eval(at);
    var before: [4][lanes_count]f64 = undefined;
    const ids = [_]Id{ family.tween, family.position, family.velocity, chase };
    for (ids, &before) |id, *row| @memcpy(row, state.values(id));
    state.eval(ms(3000));
    try testing.expect(state.checkpoints_filled > 0);
    var events_before: [128]Event = undefined;
    const found_before = state.events(ms(0), ms(4000), &events_before);

    try cues.move(.{ .index = 3 }, ms(1200));
    state.eval(at);
    for (ids, before) |id, row| {
        const now = state.values(id);
        for (0..lanes_count) |lane| {
            const same = @as(u64, @bitCast(now[lane])) == @as(u64, @bitCast(row[lane]));
            if (lane == 3) try testing.expect(!same) else try testing.expect(same);
        }
    }
    var events_after: [128]Event = undefined;
    const found_after = state.events(ms(0), ms(4000), &events_after);
    var others_before: usize = 0;
    var others_after: usize = 0;
    var lane3_moved = false;
    for (events_before[0..found_before.count]) |event| {
        if (event.instance == 3) continue;
        others_before += 1;
    }
    for (events_after[0..found_after.count]) |event| {
        if (event.instance == 3) {
            lane3_moved = lane3_moved or @mod(event.time.flicks - ms(1200).flicks, ms(250).flicks) == 0;
            continue;
        }
        others_after += 1;
    }
    try testing.expect(lane3_moved);
    try testing.expectEqual(others_before, others_after);
    var a: usize = 0;
    var b: usize = 0;
    while (a < found_before.count and b < found_after.count) {
        if (events_before[a].instance == 3) {
            a += 1;
            continue;
        }
        if (events_after[b].instance == 3) {
            b += 1;
            continue;
        }
        try testing.expectEqual(events_before[a], events_after[b]);
        a += 1;
        b += 1;
    }
}

// Locks the builder's refusals: a cue by lane outside a region is `LaneMismatch`; a region of 8
// over a table of 8 cues from cue 1, or from lane 5 of a slice of 4, runs past the table, and is
// `UnknownCue`, for a tween and a bounce alike; from cue 0 the 8 lanes fit.
test "the builder refuses a cue by lane outside a region or past the table" {
    try cue_table();
    const tween: weft.Tween = .{ .from = 0, .to = 1, .duration = ms(100), .ease = .linear, .start = .{ .index = 1 }, .previous = null, .cue_by_lane = true };
    const ball: weft.Bounce = .{ .low = 0, .high = 1, .speed = 1, .start = .{ .index = 1 }, .cue_by_lane = true };
    var builder = weft.Builder.init(&nodes, .{ .slab_count_max = slab.len, .cues = &cues });
    try testing.expectError(error.LaneMismatch, builder.tween(tween));
    try testing.expectError(error.LaneMismatch, builder.bounce(ball));
    builder.lanes = lanes_count;
    try testing.expectError(error.UnknownCue, builder.tween(tween));
    try testing.expectError(error.UnknownCue, builder.bounce(ball));
    var from_zero = tween;
    from_zero.start = .{ .index = 0 };
    _ = try builder.tween(from_zero);
    var slice = weft.Builder.init(&nodes, .{ .slab_count_max = slab.len, .cues = &cues, .lane_first = 5 });
    slice.lanes = 4;
    var ball_zero = ball;
    ball_zero.start = .{ .index = 0 };
    try testing.expectError(error.UnknownCue, slice.bounce(ball_zero));
    slice.lanes = 3;
    _ = try slice.bounce(ball_zero);
}

const limits: weft.lang.Limits = .{
    .tokens = 1024,
    .tree = 512,
    .names = 64,
    .nodes = 64,
    .slab = 1 << 12,
    .cues = 32,
    .goals = 16,
    .regions = 4,
    .tracks = 2,
    .track_samples = 4,
    .modules = 8,
};
const Compiled = weft.lang.Compiled(limits);
var compiled: Compiled = undefined;
var other: Compiled = undefined;
var failing: Compiled = undefined;

fn compile(into: *Compiled, text: []const u8) !void {
    into.compile(text) catch |err| {
        for (into.errors()) |found| std.debug.print("{s}: {s}\n", .{ found.message_text(), found.hint_text() });
        return err;
    };
}

/// Two nodes equal field for field; a pack's inputs only up to its count, since the rest are
/// undefined.
fn same_node(a: weft.Node, b: weft.Node) bool {
    if (a.op == .pack and b.op == .pack) {
        const x = a.op.pack;
        const y = b.op.pack;
        if (x.count != y.count or a.offset != b.offset or !std.meta.eql(a.extent, b.extent)) return false;
        for (x.inputs[0..x.count], y.inputs[0..y.count]) |p, q| if (p.index != q.index) return false;
        return true;
    }
    return std.meta.eql(a, b);
}

const beat_line = "cue beat = [1s, 1080ms, 1160ms, 1240ms, 1560ms, 1640ms, 2s, 2300ms]\n";

// Locks section 2's equality: `lanes(8, tween(…, at: beat[lane]))`, a vector tween, and a bounce
// build, node for node, what the builder builds by hand over the same cues; so does the tween
// through a module of one frame and of two; and every value agrees at 34 times.
test "the language builds the builder's nodes" {
    try compile(&compiled, beat_line ++
        "t = lanes(8, tween(from: 0, to: 1, at: beat[lane], over: 300ms, ease: out))\n" ++
        "v = lanes(8, tween(from: vec2(0, 1), to: vec2(1, 0), at: beat[lane], over: 300ms))\n" ++
        "b = lanes(8, bounce(0..1, speed: 4, at: beat[lane]))\n");
    try cue_table();
    for (compiled.program.cues.table(), cues.table()) |a, b| try testing.expectEqual(b, a);
    var builder = weft.Builder.init(&nodes, .{ .slab_count_max = slab.len, .cues = &cues });
    builder.lanes = lanes_count;
    const tween: weft.Tween = .{ .from = 0, .to = 1, .duration = ms(over_ms), .ease = .out, .start = .{ .index = 0 }, .previous = null, .cue_by_lane = true };
    _ = try builder.tween(tween);
    var x = tween;
    x.ease = .linear;
    var y = x;
    y.from = 1;
    y.to = 0;
    const ids = [_]Id{ try builder.tween(x), try builder.tween(y) };
    _ = try builder.pack(&ids);
    _ = try builder.bounce(.{ .low = 0, .high = 1, .speed = 4, .start = .{ .index = 0 }, .cue_by_lane = true });
    const hand = builder.finish();
    try testing.expectEqual(hand.nodes.len, compiled.program.nodes.len);
    for (hand.nodes, compiled.program.nodes) |a, b| try testing.expect(same_node(a, b));

    const modules = [_][]const u8{
        "module letter(at) = tween(from: 0, to: 1, at: at, over: 300ms, ease: out)\nt = lanes(8, letter(beat[lane]))\n",
        "module inner(c) = tween(from: 0, to: 1, at: c, over: 300ms, ease: out)\nmodule letter(at) = inner(at)\n" ++
            "t = lanes(8, letter(beat[lane]))\n",
    };
    for (modules) |text| {
        const source = try std.mem.concat(testing.allocator, u8, &.{ beat_line, text });
        defer testing.allocator.free(source);
        try compile(&other, source);
        try testing.expectEqual(@as(usize, 1), other.program.nodes.len);
        try testing.expect(same_node(hand.nodes[0], other.program.nodes[0]));
    }
}

// Locks step 31's default through a cue by lane: `b`, after `a` with its `from` left out, builds
// what the text with `from: 1` builds, node for node.
test "a chain of tweens by lane leaves out from" {
    const head = "cue beat = [0s, 1s, 2s]\ncue back = [3s, 3500ms, 4s]\n" ++
        "a = lanes(3, tween(from: 0, to: 1, at: beat[lane], over: 500ms))\n";
    try compile(&compiled, head ++ "b = lanes(3, tween(to: 0.25, at: back[lane], over: 200ms, after: a))\n");
    try compile(&other, head ++ "b = lanes(3, tween(from: 1, to: 0.25, at: back[lane], over: 200ms, after: a))\n");
    try testing.expectEqual(other.program.nodes.len, compiled.program.nodes.len);
    for (other.program.nodes, compiled.program.nodes) |a, b| try testing.expect(same_node(a, b));
    try testing.expect(compiled.program.nodes[1].op.tween.cue_by_lane);
    try testing.expectEqual(@as(u32, 3), compiled.program.nodes[1].op.tween.start.index);
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

const Case = struct {
    text: []const u8,
    code: weft.lang.diagnostic.Code,
    at: []const u8,
    hint: []const u8,
};

// Locks section 2's refusals, each with its code, the text it points at, and its hint: outside a
// region; a name other than `lane`; an expression in the index; a series one cue short, with both
// counts; `beat[lane]` in a path, `cues(…)`, a cue's own declaration, and a tween's `after`-less
// cue through a noun's parameter; `stagger:` beside it; regions nested; a cue that is not a series;
// and a list series empty or out of order.
test "every refusal of a cue by lane, with its hint" {
    const by_lane_hint = "a cue chosen by lane starts a `tween` or a `bounce`, as its `at:`";
    const index_hint = "declare the cues the lanes want, `cue NAME = [1s, 1200ms]`, then write `NAME[lane]`";
    const cases = [_]Case{
        .{ .text = "x = tween(from: 0, to: 1, at: beat[lane], over: 1s)\n", .code = .wrong_lanes, .at = "beat[lane]", .hint = "wrap the call in a region, such as `lanes(4, …)`" },
        .{ .text = "x = lanes(4, tween(from: 0, to: 1, at: beat[k], over: 1s))\n", .code = .wrong_type, .at = "beat[k]", .hint = "an index is a whole number, or `lane` inside a region" },
        .{ .text = "x = lanes(4, tween(from: 0, to: 1, at: beat[lane + 1], over: 1s))\n", .code = .unexpected_token, .at = "+", .hint = index_hint },
        .{ .text = "x = lanes(4, tween(from: 0, to: 1, at: beat[2 * lane], over: 1s))\n", .code = .unexpected_token, .at = "*", .hint = index_hint },
        .{ .text = "x = lanes(5, tween(from: 0, to: 1, at: beat[lane], over: 1s))\n", .code = .wrong_lanes, .at = "beat[lane]", .hint = "give the series a cue for every lane, or the region fewer lanes" },
        .{ .text = "x = lanes(4, spring([beat[lane]: 1], time: 1s))\n", .code = .wrong_lanes, .at = "beat[lane]", .hint = by_lane_hint },
        .{ .text = "x = lanes(4, cues(beat[lane]))\n", .code = .wrong_lanes, .at = "beat[lane]", .hint = by_lane_hint },
        .{ .text = "cue c = beat[lane]\n", .code = .wrong_lanes, .at = "beat[lane]", .hint = by_lane_hint },
        .{ .text = "cue c = beat[lane] + 10ms\n", .code = .wrong_lanes, .at = "beat[lane]", .hint = by_lane_hint },
        .{ .text = "x = lanes(4, tween(from: 0, to: 1, at: beat[lane], over: 1s, stagger: 10ms))\n", .code = .wrong_lanes, .at = "10ms", .hint = "each lane already starts at its own cue; drop `stagger:`" },
        .{ .text = "x = lanes(4, bounce(0..1, speed: 1, at: beat[lane], stagger: 10ms))\n", .code = .wrong_lanes, .at = "10ms", .hint = "each lane already starts at its own cue; drop `stagger:`" },
        .{ .text = "x = lanes(4, lanes(2, tween(from: 0, to: 1, at: beat[lane], over: 1s)))\n", .code = .wrong_lanes, .at = "2", .hint = "regions do not nest; give the outer region the lanes of both" },
        .{ .text = "cue one = 5s\nx = lanes(4, tween(from: 0, to: 1, at: one[lane], over: 1s))\n", .code = .wrong_type, .at = "one[lane]", .hint = "" },
        .{ .text = "cue empty = []\n", .code = .bad_series, .at = "[]", .hint = "for example `cue title = [1s, 1080ms, 1560ms]`" },
        .{ .text = "cue late = [5s, 4500ms]\n", .code = .cue_out_of_order, .at = "4500ms", .hint = "write the list in time order" },
        .{ .text = "cue early = [500ms]\n", .code = .cue_out_of_order, .at = "500ms", .hint = "move it above the cues it comes before" },
    };
    for (cases) |case| {
        const text = try std.mem.concat(testing.allocator, u8, &.{ "cue beat = [1s, 2s, 3s, 4s]\n", case.text });
        defer testing.allocator.free(text);
        const found = first_error(text) catch |err| {
            std.debug.print("compiled: {s}\n", .{case.text});
            return err;
        };
        const pointed = text[found.start..][0..found.len];
        const same = found.code == case.code and std.mem.eql(u8, pointed, case.at) and std.mem.eql(u8, found.hint_text(), case.hint);
        if (!same) {
            std.debug.print("{s}: {s} at `{s}`: {s} / {s}\n", .{ case.text, @tagName(found.code), pointed, found.message_text(), found.hint_text() });
            return error.TestUnexpectedResult;
        }
    }
    const short = try first_error("cue beat = [1s, 2s, 3s, 4s]\nx = lanes(5, tween(from: 0, to: 1, at: beat[lane], over: 1s))\n");
    try testing.expectEqualStrings("`beat` has 4 cues and the region 5 lanes", short.message_text());
}

const score = @import("score.zig");

// Locks the client's side: a noun's cue parameter, here the score's `say`, refuses `beat[lane]`
// with the hint, inside a region's file as outside, and takes `beat[2]`.
test "a client's cue parameter refuses a cue by lane" {
    const text = "cue beat = [1s, 2s, 3s]\nn = say(beat[lane], \"line\")\n";
    failing.compile_client(&score.nouns, &.{}, text) catch {
        const found = failing.errors()[0];
        try testing.expectEqual(weft.lang.diagnostic.Code.wrong_lanes, found.code);
        try testing.expectEqualStrings("a cue chosen by lane starts a `tween` or a `bounce`, as its `at:`", found.hint_text());
        try compile_client_ok("cue beat = [1s, 2s, 3s]\nn = say(beat[2], \"line\")\n");
        return;
    };
    return error.TestUnexpectedResult;
}

fn compile_client_ok(text: []const u8) !void {
    compiled.compile_client(&score.nouns, &.{}, text) catch |err| {
        for (compiled.errors()) |found| std.debug.print("{s}\n", .{found.message_text()});
        return err;
    };
    const noun = compiled.noun("n").?;
    try testing.expectEqual(@as(u32, 2), noun.values[0].cue);
}

// Locks the list series: its items as times, as an earlier cue, and as a cue plus a time, in the
// table in order after the cues above; one item; `title[2]` a cue of it; `cues(title)` its events,
// one at each; and `cue_name` naming each element.
test "a series written as a list" {
    try compile(&compiled, "cue c0 = 500ms\ncue title = [1s, c0 + 1080ms, 1580ms, 1580ms, 2s]\ncue solo = [3s]\n" ++
        "x = tween(from: 0, to: 1, at: title[2], over: 1s)\nn = cues(title)\nm = lanes(1, bounce(0..1, speed: 1, at: solo[lane]))\n");
    const expected = [_]i64{ 500, 1000, 1580, 1580, 1580, 2000, 3000 };
    const table = compiled.program.cues.table();
    try testing.expectEqual(expected.len, table.len);
    for (expected, table) |at, time| try testing.expectEqual(ms(at), time);
    try testing.expectEqual(@as(u32, 3), compiled.program.nodes[compiled.signal("x").?.index].op.tween.start.index);
    const name = compiled.cue_name(4).?;
    try testing.expectEqualStrings("title", name.name);
    try testing.expectEqual(@as(?u32, 3), name.element);
    try testing.expectEqualStrings("solo", compiled.cue_name(6).?.name);
    var state = State.init(compiled.program, slab[0..compiled.program.slab_count]);
    var out: [16]Event = undefined;
    const found = state.events_of(&.{compiled.signal("n").?}, ms(0), ms(2500), &out);
    try testing.expectEqual(Events{ .count = 5, .dropped = 0 }, found);
    for (out[0..5], 1..) |event, index| try testing.expectEqual(@as(f64, @floatFromInt(index)), event.value);
}

var format_buffer: [4096]u8 = undefined;
var syntax: weft.lang.Syntax(limits) = undefined;

// Locks the formatter: `beat[lane]` and a list series stay as written; a long list stays on one
// line, since nothing wraps; and one whose last item has a comma is one item a line.
test "the formatter keeps a cue by lane and a list series" {
    const canonical = beat_line ++
        "cue long = [1s, 1100ms, 1200ms, 1300ms, 1400ms, 1500ms, 1600ms, 1700ms, 1800ms, 1900ms, 2s, 2100ms, 2200ms]\n" ++
        "cue tall = [\n    3s,\n    4s,\n]\n" ++
        "t = lanes(8, tween(from: 0, to: 1, at: beat[lane], over: 300ms))\n";
    try testing.expect(syntax.parse_source(canonical));
    try testing.expectEqualStrings(canonical, try syntax.format_into(&format_buffer));
    const loose = "cue  beat=[1s,1080ms ,1160ms]\nt = lanes(3,tween(from:0, to:1, at:beat[lane], over:300ms))\n";
    try testing.expect(syntax.parse_source(loose));
    try testing.expectEqualStrings(
        "cue beat = [1s, 1080ms, 1160ms]\nt = lanes(3, tween(from: 0, to: 1, at: beat[lane], over: 300ms))\n",
        try syntax.format_into(&format_buffer),
    );
}

const title_file =
    \\cue letters = [1s, 1080ms, 1160ms, 1240ms, 1320ms, 1400ms, 1720ms, 1800ms, 1880ms, 1960ms, 2040ms]
    \\rise = lanes(11, tween(from: 0, to: 1, at: letters[lane], over: 300ms, ease: out))
    \\pop = lanes(11, bounce(0..1, speed: 4, at: letters[lane]))
    \\
;

// Locks the step page's title: lane i of `rise` is 0 a flick before `letters[i]` and above 0 a
// flick after it; the gap after lane 5 is 320 ms against 80 ms elsewhere; and each lane of `pop`
// first hits a leg, 250 ms, after its cue.
test "a title whose letters pause after a word" {
    try compile(&compiled, title_file);
    const program = compiled.program;
    var state = State.init(program, slab[0..program.slab_count]);
    const rise = compiled.signal("rise").?;
    const table = program.cues.table();
    try testing.expectEqual(@as(usize, 11), table.len);
    for (table, 0..) |cue, lane| {
        state.eval(.{ .flicks = cue.flicks - 1 });
        try testing.expectEqual(@as(f64, 0), state.values(rise)[lane]);
        state.eval(.{ .flicks = cue.flicks + 1 });
        try testing.expect(state.values(rise)[lane] > 0);
        if (lane == 0) continue;
        const gap = cue.flicks - table[lane - 1].flicks;
        try testing.expectEqual(ms(if (lane == 6) 320 else 80).flicks, gap);
    }
    var sources: [weft.graph.components_max]Id = undefined;
    const pop = compiled.event_sources("pop", &sources);
    var out: [64]Event = undefined;
    var firsts: [11]?Event = @splat(null);
    var reader = State.init(program, slab[0..program.slab_count]);
    const found = reader.events_of(pop, ms(0), ms(2300), &out);
    try testing.expectEqual(@as(u64, 0), found.dropped);
    for (out[0..found.count]) |event| {
        if (firsts[event.instance] == null) firsts[event.instance] = event;
    }
    for (firsts, table) |first, cue| try testing.expectEqual(cue.flicks + ms(250).flicks, first.?.time.flicks);
}
