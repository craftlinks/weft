//! A spring's or a Newtonian move's goal at a cue chosen by lane (step 39):
//! `lanes(n, spring([series[lane]: 1], …))` and the same for `newtonian`.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Core
//! A motion whose path is one goal with `Goal.cue_by_lane` heads, in lane g of its region, for
//! the goal from cue `cue + g` (`graph.lane_cue`). So a by-lane motion over n lanes must equal n
//! one-lane motions, each with its goal at its own cue, bit for bit: values at every time and
//! goals reached, for a spring and a Newtonian move. A slice built with `lane_first` reads the
//! family's own cues; a reader that seeks back and forth, or across checkpoints, reads what a
//! fresh reader reads; a cue moved moves its lane only; ranges are the one-lane ranges; and the
//! builder refuses a by-lane goal outside a region, past the cue table, or in a path of two.
//!
//! ## 2. The Language
//! `series[lane]` as the only goal of a `spring` or a `newtonian` builds the builder's nodes,
//! node for node, as a vector too, through a module's cue (Tapestry's `pop(s[lane])`) and a
//! module's path (`snap([s[lane]: 1])`). A path by lane never shares a run with the path at the
//! series' first cue. A recompile carries a reader of it as of any file. Every refusal that
//! remains has its code, its place, and its hint, the page's three lanes rest before their cues
//! and settle after, and the formatter keeps a goal by lane as written.

const std = @import("std");
const testing = std.testing;
const weft = @import("weft");
const Event = weft.Event;
const Id = weft.Id;
const State = weft.State;
const Time = weft.Time;

const flicks_per_second = weft.time.flicks_per_second;
const lanes_count = 3;
/// The family's cues, uneven: 800 ms apart, as the study probed, then a fourth for `Cues.move`'s
/// room and the slice's refusal.
const cue_ms = [lanes_count + 1]i64{ 1000, 1800, 2600, 5000 };
/// Long enough for every lane's spring to settle: about 7.4 s after its cue.
const end_ms = 12_000;

fn ms(count: i64) Time {
    return .{ .flicks = @divExact(flicks_per_second, 1000) * count };
}

var cue_times: [cue_ms.len]Time = undefined;
var cues: weft.Cues = undefined;
var goal_entries: [16]weft.Goal = undefined;
var goals: weft.Goals = undefined;
/// `[cue 0 by lane: 1]`, the family's path, and `[cue g: 1]`, lane g's own.
var by_lane_path: weft.Path = undefined;
var own_paths: [lanes_count + 1]weft.Path = undefined;

fn tables() !void {
    cues = weft.Cues.init(&cue_times);
    for (cue_ms) |at| _ = try cues.add(ms(at));
    goals = weft.Goals.init(&goal_entries);
    by_lane_path = try goals.add(&.{.{ .cue = .{ .index = 0 }, .value = 1, .cue_by_lane = true }});
    for (&own_paths, 0..) |*path, g| path.* = try goals.add(&.{.{ .cue = .{ .index = @intCast(g) }, .value = 1 }});
}

fn spring_of(path: weft.Path) weft.Spring {
    return .{ .from = 0, .goals = path, .time = ms(450), .overshoot = 0.3 };
}

fn newtonian_of(path: weft.Path) weft.Newtonian {
    return .{ .from = 0, .goals = path, .speed = 4, .accel = 20, .decel = 12 };
}

const Pair = struct { spring: Id, newtonian: Id };

/// The family: a spring and a Newtonian move by lane, and, when `with_chase`, a chase of the
/// spring, which makes the program simulated.
fn build_family(builder: *weft.Builder, lanes: u32, with_chase: bool) !Pair {
    builder.lanes = lanes;
    const pair: Pair = .{
        .spring = try builder.spring(spring_of(by_lane_path)),
        .newtonian = try builder.newtonian(newtonian_of(by_lane_path)),
    };
    if (with_chase) _ = try builder.chase(.{ .target = pair.spring, .from = 0, .time = ms(200), .overshoot = 0.1 });
    builder.lanes = null;
    return pair;
}

/// Lane g alone: the same spring and Newtonian move in one lane, outside a region, at cue g.
fn build_alone(builder: *weft.Builder, g: u32) !Pair {
    return .{
        .spring = try builder.spring(spring_of(own_paths[g])),
        .newtonian = try builder.newtonian(newtonian_of(own_paths[g])),
    };
}

fn options(slab_count_max: u32, lane_first: u32) weft.Builder.Options {
    return .{ .slab_count_max = slab_count_max, .cues = &cues, .goals = goals.table(), .lane_first = lane_first };
}

const grid_count = 572;
/// Every 7 ms from 12,345 flicks, over 4 s, and a flick before, on, and after every cue.
fn times_sampled(out: *[grid_count + 3 * cue_ms.len]Time) []const Time {
    for (out[0..grid_count], 0..) |*time, k| time.* = .{ .flicks = ms(7).flicks * @as(i64, @intCast(k)) + 12_345 };
    for (cue_ms, 0..) |at, index| {
        for ([_]i64{ -1, 0, 1 }, 0..) |offset, k| out[grid_count + 3 * index + k] = .{ .flicks = ms(at).flicks + offset };
    }
    return out;
}

fn by_event(_: void, a: Event, b: Event) bool {
    return weft.event.before(&a, &b);
}

fn same_bits(a: f64, b: f64) bool {
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

var nodes: [8]weft.Node = undefined;
var slab: [64]f64 = undefined;
var alone_nodes: [4]weft.Node = undefined;
var alone_slab: [16]f64 = undefined;

// Locks section 1: a spring (450 ms, overshoot 0.3) and a Newtonian move by lane over 3 lanes at
// cues 1,000, 1,800, and 2,600 ms equal 3 one-lane graphs each at its own cue, bit for bit, at
// 584 times (1,752 values a node); each lane is exactly 0 a flick before its cue; and the
// family's goals reached over [0, 12 s), whole and in ranges of 250 ms, are the 3 graphs' merged
// in order: 6 events, the springs' 7,417 ms after their cues to the flick of a one-lane spring.
test "a spring and a Newtonian move by lane equal one graph a lane, at its own cue" {
    try tables();
    var builder = weft.Builder.init(&nodes, options(slab.len, 0));
    const family = try build_family(&builder, lanes_count, false);
    const program = builder.finish();
    try testing.expectEqual(@as(u32, 2 * (lanes_count + weft.motion.cursor_count)), program.slab_count);
    var state = State.init(program, slab[0..program.slab_count]);
    var time_buffer: [grid_count + 3 * cue_ms.len]Time = undefined;
    const times = times_sampled(&time_buffer);

    var merged: [16]Event = undefined;
    var merged_count: usize = 0;
    for (0..lanes_count) |lane| {
        const g: u32 = @intCast(lane);
        var alone_builder = weft.Builder.init(&alone_nodes, options(alone_slab.len, 0));
        const alone = try build_alone(&alone_builder, g);
        var reader = State.init(alone_builder.finish(), &alone_slab);
        for (times) |time| {
            state.eval(time);
            reader.eval(time);
            inline for (.{ "spring", "newtonian" }) |field| {
                const family_value = state.values(@field(family, field))[lane];
                try testing.expect(same_bits(reader.value(@field(alone, field)), family_value));
            }
        }
        state.eval(.{ .flicks = ms(cue_ms[lane]).flicks - 1 });
        try testing.expectEqual(@as(f64, 0), state.values(family.spring)[lane]);
        try testing.expectEqual(@as(f64, 0), state.values(family.newtonian)[lane]);
        var events: [4]Event = undefined;
        const found = reader.events(ms(0), ms(end_ms), &events);
        try testing.expectEqual(weft.Events{ .count = 2, .dropped = 0 }, found);
        for (events[0..found.count]) |event| {
            merged[merged_count] = event;
            merged[merged_count].source = if (event.source.index == alone.spring.index) family.spring else family.newtonian;
            merged[merged_count].instance = g;
            merged_count += 1;
        }
    }
    std.sort.block(Event, merged[0..merged_count], {}, by_event);
    var spring_reached: [lanes_count]i64 = undefined;
    for (merged[0..merged_count]) |event| {
        if (event.source.index == family.spring.index) spring_reached[event.instance] = event.time.flicks;
    }
    for (spring_reached, cue_ms[0..lanes_count]) |reached, at| try testing.expectEqual(ms(at + 7417).flicks, @divTrunc(reached, ms(1).flicks) * ms(1).flicks);
    var whole: [16]Event = undefined;
    const found = state.events(ms(0), ms(end_ms), &whole);
    try testing.expectEqual(weft.Events{ .count = 6, .dropped = 0 }, found);
    try testing.expectEqualSlices(Event, merged[0..merged_count], whole[0..found.count]);
    var pieces: [16]Event = undefined;
    var piece_count: usize = 0;
    var at: i64 = 0;
    while (at < end_ms) : (at += 250) {
        const piece = state.events(ms(at), ms(at + 250), pieces[piece_count..]);
        piece_count += piece.count;
    }
    try testing.expectEqualSlices(Event, merged[0..merged_count], pieces[0..piece_count]);
}

// Locks the slice: the family built from lane 1 with two lanes, `lane_first = 1`, equals lanes 1
// and 2 of the whole, values at 584 times and the 4 goals reached over [0, 12 s).
test "a slice from lane 1 equals lanes 1 and 2 of the whole" {
    try tables();
    var builder = weft.Builder.init(&nodes, options(slab.len, 0));
    const whole = try build_family(&builder, lanes_count, false);
    var state = State.init(builder.finish(), &slab);
    var slice_nodes: [8]weft.Node = undefined;
    var slice_slab: [64]f64 = undefined;
    var slice_builder = weft.Builder.init(&slice_nodes, options(slice_slab.len, 1));
    const slice = try build_family(&slice_builder, 2, false);
    var reader = State.init(slice_builder.finish(), &slice_slab);
    var time_buffer: [grid_count + 3 * cue_ms.len]Time = undefined;
    for (times_sampled(&time_buffer)) |time| {
        state.eval(time);
        reader.eval(time);
        inline for (.{ "spring", "newtonian" }) |field| {
            const all = state.values(@field(whole, field));
            try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(all[1..3]), std.mem.sliceAsBytes(reader.values(@field(slice, field))));
        }
    }
    var all_events: [16]Event = undefined;
    const all_found = state.events(ms(0), ms(end_ms), &all_events);
    var slice_events: [16]Event = undefined;
    const slice_found = reader.events(ms(0), ms(end_ms), &slice_events);
    try testing.expectEqual(@as(u32, 4), slice_found.count);
    var kept: usize = 0;
    for (all_events[0..all_found.count]) |event| {
        if (event.instance == 0) continue;
        try testing.expectEqual(event.time, slice_events[kept].time);
        try testing.expectEqual(event.instance, slice_events[kept].instance);
        kept += 1;
    }
    try testing.expectEqual(@as(usize, slice_found.count), kept);
}

var checkpoints: [8 * 64]f64 = undefined;
const probe_ms = [_]i64{ 2900, 1200, 4000, 1000, 3100, 999, 2650, 1850, 6000, 1300 };

// Locks a seek: a reader of the family with a chase of the spring, which keeps checkpoints, run
// forward to 6 s, then sent back and forth to 10 times, reads at each what a reader started
// there reads, bit for bit, for the spring, the Newtonian move, and the chase.
test "a seek back and forth reads what a fresh reader reads" {
    try tables();
    var builder = weft.Builder.init(&nodes, options(slab.len, 0));
    const family = try build_family(&builder, lanes_count, true);
    const program = builder.finish();
    try testing.expect(program.simulated);
    const chase: Id = .{ .index = family.newtonian.index + 1 };
    var state = State.init_with_checkpoints(program, slab[0..program.slab_count], &checkpoints);
    var at: i64 = 0;
    while (at <= 6000) : (at += 50) state.eval(ms(at));
    try testing.expect(state.checkpoints_filled > 0);
    for (probe_ms) |probe| {
        state.eval(ms(probe));
        var fresh = State.init(program, fresh_slab[0..program.slab_count]);
        fresh.eval(ms(probe));
        for ([_]Id{ family.spring, family.newtonian, chase }) |id| {
            try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(fresh.values(id)), std.mem.sliceAsBytes(state.values(id)));
        }
    }
}

// Locks `Cues.move` by lane: on a reader with checkpoints of the family with a chase, moving cue 1
// from 1,800 to 1,500 ms changes lane 1's spring, Newtonian move, and chase at 2,000 ms and its
// goals reached, which are then a one-lane graph's at the moved cue, and leaves lanes 0 and 2's
// values and events bit for bit.
test "moving one lane's cue moves that lane only" {
    try tables();
    var builder = weft.Builder.init(&nodes, options(slab.len, 0));
    const family = try build_family(&builder, lanes_count, true);
    const program = builder.finish();
    const chase: Id = .{ .index = family.newtonian.index + 1 };
    var state = State.init_with_checkpoints(program, slab[0..program.slab_count], &checkpoints);
    const at = ms(2000);
    state.eval(ms(6000));
    state.eval(at);
    const ids = [_]Id{ family.spring, family.newtonian, chase };
    var before: [ids.len][lanes_count]f64 = undefined;
    for (ids, &before) |id, *row| @memcpy(row, state.values(id));
    var events_before: [16]Event = undefined;
    const found_before = state.events(ms(0), ms(end_ms), &events_before);

    try cues.move(.{ .index = 1 }, ms(1500));
    state.eval(at);
    for (ids, before) |id, row| {
        for (state.values(id), row, 0..) |now, was, lane| {
            if (lane == 1) try testing.expect(!same_bits(now, was)) else try testing.expect(same_bits(now, was));
        }
    }
    var alone_builder = weft.Builder.init(&alone_nodes, options(alone_slab.len, 0));
    const alone = try build_alone(&alone_builder, 1);
    var reader = State.init(alone_builder.finish(), &alone_slab);
    reader.eval(at);
    try testing.expect(same_bits(reader.value(alone.spring), state.values(family.spring)[1]));
    try testing.expect(same_bits(reader.value(alone.newtonian), state.values(family.newtonian)[1]));
    var alone_events: [4]Event = undefined;
    const alone_found = reader.events(ms(0), ms(end_ms), &alone_events);
    var events_after: [16]Event = undefined;
    const found_after = state.events(ms(0), ms(end_ms), &events_after);
    try testing.expectEqual(found_before.count, found_after.count);
    var lane_one: usize = 0;
    var others: usize = 0;
    for (events_after[0..found_after.count]) |event| {
        if (event.instance == 1) {
            try testing.expectEqual(alone_events[lane_one].time, event.time);
            lane_one += 1;
            continue;
        }
        while (events_before[others].instance == 1) others += 1;
        try testing.expectEqual(events_before[others], event);
        others += 1;
    }
    try testing.expectEqual(@as(usize, alone_found.count), lane_one);
    try cues.move(.{ .index = 1 }, ms(1800));
}

// Locks ranges: a motion by lane declares the range of the same motion at one cue, the spring's
// [0, 1.3] for its overshoot of 0.3 and the Newtonian move's alike, since a range reads only
// `from` and the goals' values.
test "a motion by lane has the range of one at one cue" {
    try tables();
    var builder = weft.Builder.init(&nodes, options(slab.len, 0));
    const family = try build_family(&builder, lanes_count, false);
    const alone = try build_alone(&builder, 0);
    const program = builder.finish();
    var ranges: [8]weft.Range = undefined;
    program.ranges(ranges[0..program.nodes.len]);
    try testing.expectEqual(ranges[alone.spring.index], ranges[family.spring.index]);
    try testing.expectEqual(ranges[alone.newtonian.index], ranges[family.newtonian.index]);
    try testing.expectApproxEqAbs(@as(f64, 1.3), ranges[family.spring.index].high, 1e-9);
}

// Locks the builder's refusals: a goal by lane outside a region is `LaneMismatch`; a region of 3
// from cue 2, or from lane 2 of a slice of 3, runs past the 4 cues, `UnknownCue`; and a goal by
// lane in a path of two, first or second, is `LaneMismatch`, for a spring and a Newtonian move.
test "the builder refuses a goal by lane outside a region, past the table, or in a path of two" {
    try tables();
    const late = try goals.add(&.{.{ .cue = .{ .index = 2 }, .value = 1, .cue_by_lane = true }});
    const first_two = try goals.add(&.{
        .{ .cue = .{ .index = 0 }, .value = 1, .cue_by_lane = true },
        .{ .cue = .{ .index = 3 }, .value = 0 },
    });
    const second_two = try goals.add(&.{
        .{ .cue = .{ .index = 0 }, .value = 1 },
        .{ .cue = .{ .index = 1 }, .value = 0, .cue_by_lane = true },
    });
    var builder = weft.Builder.init(&nodes, options(slab.len, 0));
    try testing.expectError(error.LaneMismatch, builder.spring(spring_of(by_lane_path)));
    try testing.expectError(error.LaneMismatch, builder.newtonian(newtonian_of(by_lane_path)));
    builder.lanes = lanes_count;
    try testing.expectError(error.UnknownCue, builder.spring(spring_of(late)));
    try testing.expectError(error.UnknownCue, builder.newtonian(newtonian_of(late)));
    for ([_]weft.Path{ first_two, second_two }) |path| {
        try testing.expectError(error.LaneMismatch, builder.spring(spring_of(path)));
        try testing.expectError(error.LaneMismatch, builder.newtonian(newtonian_of(path)));
    }
    _ = try builder.spring(spring_of(by_lane_path));
    var slice = weft.Builder.init(&nodes, options(slab.len, 2));
    slice.lanes = 3;
    try testing.expectError(error.UnknownCue, slice.spring(spring_of(by_lane_path)));
    slice.lanes = 2;
    _ = try slice.newtonian(newtonian_of(by_lane_path));
}

const limits: weft.lang.Limits = .{
    .tokens = 1024,
    .tree = 512,
    .names = 64,
    .nodes = 64,
    .slab = 1 << 10,
    .cues = 16,
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

const s_line = "cue s = [1s, 1800ms, 2600ms]\n";
const pop_module = "module pop(at, stagger: 0s) = spring([at: 1], time: 450ms, overshoot: 0.3, stagger: stagger)\n";

// Locks section 2's equality: `lanes(3, spring([s[lane]: 1], …))` and the same `newtonian` build,
// node for node and goal for goal, what the builder builds by hand over the same cues; so do
// Tapestry's `pop(s[lane])`, a cue through a module, and `snap([s[lane]: 1])`, a path through
// one; a vec2 goal by lane is one run a component, each by lane, packed.
test "the language builds the builder's nodes" {
    try compile(&compiled, s_line ++
        "p = lanes(3, spring([s[lane]: 1], time: 450ms, overshoot: 0.3))\n" ++
        "n = lanes(3, newtonian([s[lane]: 1], speed: 4, accel: 20, decel: 12))\n");
    cues = weft.Cues.init(&cue_times);
    for (cue_ms[0..lanes_count]) |at| _ = try cues.add(ms(at));
    goals = weft.Goals.init(&goal_entries);
    by_lane_path = try goals.add(&.{.{ .cue = .{ .index = 0 }, .value = 1, .cue_by_lane = true }});
    try testing.expectEqualSlices(Time, cues.table(), compiled.program.cues.table());
    try testing.expectEqualSlices(weft.Goal, goals.table(), compiled.program.goals);
    var builder = weft.Builder.init(&nodes, options(slab.len, 0));
    _ = try build_family(&builder, lanes_count, false);
    const hand = builder.finish();
    try testing.expectEqual(hand.nodes.len, compiled.program.nodes.len);
    for (hand.nodes, compiled.program.nodes) |a, b| try testing.expect(same_node(a, b));

    const modules = [_][]const u8{
        pop_module ++ "p = lanes(3, pop(s[lane]))\n",
        "module snap(goal) = spring(goal, time: 450ms, overshoot: 0.3)\np = lanes(3, snap([s[lane]: 1]))\n",
    };
    for (modules) |text| {
        const source = try std.mem.concat(testing.allocator, u8, &.{ s_line, text });
        defer testing.allocator.free(source);
        try compile(&other, source);
        try testing.expectEqual(@as(usize, 1), other.program.nodes.len);
        try testing.expect(same_node(hand.nodes[0], other.program.nodes[0]));
        try testing.expectEqualSlices(weft.Goal, goals.table(), other.program.goals);
    }

    try compile(&other, s_line ++ "v = lanes(3, spring([s[lane]: vec2(1, -2)], from: vec2(0, 1), time: 450ms))\n");
    try testing.expectEqual(@as(usize, 3), other.program.nodes.len);
    try testing.expectEqual(@as(usize, 2), other.program.goals.len);
    for (other.program.goals, [_]f64{ 1, -2 }) |goal, value| {
        try testing.expect(goal.cue_by_lane);
        try testing.expectEqual(value, goal.value);
    }
    for (other.program.nodes[0..2]) |node| try testing.expectEqual(@as(u32, lanes_count), node.extent.lanes);
    try testing.expectEqual(@as(u32, lanes_count), other.program.nodes[2].extent.lanes);
}

// Locks path sharing: `[s[lane]: 1]` and `[s[0]: 1]` in one file are two runs of the goal table,
// one by lane, while a second `[s[lane]: 1]` shares the first's; the lane-0 spring is one lane.
test "a path by lane never shares the path at the series' first cue" {
    try compile(&compiled, s_line ++
        "a = lanes(3, spring([s[lane]: 1], time: 450ms))\n" ++
        "b = spring([s[0]: 1], time: 450ms)\n" ++
        "c = lanes(3, spring([s[lane]: 1], time: 300ms))\n");
    const table = compiled.program.goals;
    try testing.expectEqual(@as(usize, 2), table.len);
    try testing.expect(table[0].cue_by_lane);
    try testing.expect(!table[1].cue_by_lane);
    const nodes_of = compiled.program.nodes;
    try testing.expectEqual(nodes_of[0].op.motion.goals, nodes_of[2].op.motion.goals);
    try testing.expect(nodes_of[0].op.motion.goals.first != nodes_of[1].op.motion.goals.first);
    try testing.expectEqual(@as(u32, 1), nodes_of[1].extent.lanes);
}

const recompile_base = s_line ++
    "pops = lanes(3, spring([s[lane]: 1], time: 450ms, overshoot: 0.3))\n" ++
    "lag = chase(pops, time: 200ms, overshoot: 0.1)\n";

var old_slab: [64]f64 = undefined;
var old_checkpoints: [16 * 64]f64 = undefined;
var carried_slab: [64]f64 = undefined;
var carried_checkpoints: [16 * 64]f64 = undefined;
var fresh_slab: [64]f64 = undefined;

fn reader_of(program: weft.Program, into: []f64, kept: []f64) State {
    const size = program.slab_count;
    return .init_with_checkpoints(program, into[0..size], kept[0 .. 16 * size]);
}

// Locks a recompile: a reader of the pop row and a chase of it, run to 5 s, carries over an edit
// that adds a line above them and reads, forwards and back across checkpoints, what a fresh
// reader of the new program reads, bit for bit; an edit to `s` refuses the carry, and the fresh
// program's lane 1 is then a one-lane spring at the edited cue.
test "a recompile carries a reader of a spring by lane" {
    try compile(&compiled, recompile_base);
    var old = reader_of(compiled.program, &old_slab, &old_checkpoints);
    var at: i64 = 0;
    while (at <= 5000) : (at += 100) old.eval(ms(at));
    const edited = "extra = wave(saw, 3hz)\n" ++ recompile_base;
    try compile(&other, edited);
    var carried = reader_of(other.program, &carried_slab, &carried_checkpoints);
    var fresh = State.init(other.program, fresh_slab[0..other.program.slab_count]);
    try testing.expect(other.carry(&carried, &compiled, &old));
    for ([_]i64{ 5000, 5100, 1900, 2700, 7000, 1000, 999, 3300 }) |probe| {
        carried.eval(ms(probe));
        fresh.eval(ms(probe));
        for ([_][]const u8{ "pops", "lag" }) |name| {
            const id = other.signal(name).?;
            try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(fresh.values(id)), std.mem.sliceAsBytes(carried.values(id)));
        }
    }

    const moved = "cue s = [1s, 1500ms, 2600ms]\n" ++ recompile_base[s_line.len..];
    try compile(&other, moved);
    carried = reader_of(other.program, &carried_slab, &carried_checkpoints);
    try testing.expect(!other.carry(&carried, &compiled, &old));
    try compile(&failing, "cue s = [1s, 1500ms, 2600ms]\none = spring([s[1]: 1], time: 450ms, overshoot: 0.3)\n");
    var alone = State.init(failing.program, &alone_slab);
    for ([_]i64{ 1499, 1500, 1600, 2000, 9000 }) |probe| {
        carried.eval(ms(probe));
        alone.eval(ms(probe));
        try testing.expect(same_bits(alone.value(failing.signal("one").?), carried.values(other.signal("pops").?)[1]));
    }
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

// Locks section 2's refusals, each with its code, the text it points at, and its hint: a goal by
// lane in a path of two, first or second, for a spring and a Newtonian move, and through a
// module's cue; a declared path by lane; `stagger:` beside it, written and through `pop`'s
// parameter, which points at the module's use of it; a series one cue short; and outside a
// region.
test "every refusal of a goal by lane, with its hint" {
    const two_hint = "write one goal, `[s[lane]: 1]`, or give every lane the same path, moved by `stagger:`";
    const drop_hint = "each lane already starts at its own cue; drop `stagger:`";
    const cases = [_]Case{
        .{ .text = "x = lanes(3, spring([s[lane]: 1, c: 0], time: 1s))\n", .code = .wrong_lanes, .at = "s[lane]", .hint = two_hint },
        .{ .text = "x = lanes(3, spring([s[0]: 0, s[lane]: 1], time: 1s))\n", .code = .wrong_lanes, .at = "s[lane]", .hint = two_hint },
        .{ .text = "x = lanes(3, newtonian([s[lane]: 1, c: 0], speed: 1, accel: 1, decel: 1))\n", .code = .wrong_lanes, .at = "s[lane]", .hint = two_hint },
        .{ .text = "module two(at) = spring([at: 1, c: 0], time: 1s)\nx = lanes(3, two(s[lane]))\n", .code = .wrong_lanes, .at = "s[lane]", .hint = two_hint },
        .{ .text = "p = [s[lane]: 1]\nx = lanes(3, spring(p, time: 1s))\n", .code = .wrong_lanes, .at = "s[lane]", .hint = "write the path in the call, as `spring([s[lane]: 1], …)`, inside `lanes(n, …)`" },
        .{ .text = "x = lanes(3, spring([s[lane]: 1], time: 1s, stagger: 10ms))\n", .code = .wrong_lanes, .at = "10ms", .hint = drop_hint },
        .{ .text = "x = lanes(3, newtonian([s[lane]: 1], speed: 1, accel: 1, decel: 1, stagger: 10ms))\n", .code = .wrong_lanes, .at = "10ms", .hint = drop_hint },
        .{ .text = pop_module ++ "x = lanes(3, pop(s[lane], stagger: 10ms))\n", .code = .wrong_lanes, .at = "stagger", .hint = drop_hint },
        .{ .text = "x = lanes(4, spring([s[lane]: 1], time: 1s))\n", .code = .wrong_lanes, .at = "s[lane]", .hint = "give the series a cue for every lane, or the region fewer lanes" },
        .{ .text = "x = spring([s[lane]: 1], time: 1s)\n", .code = .wrong_lanes, .at = "s[lane]", .hint = "wrap the call in a region, such as `lanes(3, …)`" },
    };
    for (cases) |case| {
        const text = try std.mem.concat(testing.allocator, u8, &.{ s_line, "cue c = 4s\n", case.text });
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
    const two = try first_error(s_line ++ "cue c = 4s\nx = lanes(3, spring([s[lane]: 1, c: 0], time: 1s))\n");
    try testing.expectEqualStrings("`s[lane]` is a cue for each lane, and a path by lane has one goal", two.message_text());
    const declared = try first_error(s_line ++ "p = [s[lane]: 1]\n");
    try testing.expectEqualStrings("`s[lane]` is a cue for each lane, and a declared path is outside any region", declared.message_text());
}

const pop_file = "cue s = [1s, 1800ms, 2600ms]\n" ++ pop_module ++ "pops = lanes(3, pop(s[lane]))\n";

// Locks the step page's demo, Tapestry's uneven pop: lane g of `pops` is exactly 0 a flick before
// `s[g]` and above 0 a flick after it, peaks at 1.3 (its overshoot of 0.3), reaches its goal 7,417
// ms after its cue, and is exactly 1 from then on, while the lanes after it still rest; and each
// lane's cue keeps its form, item g of the list.
test "three lanes pop in at uneven cues, at rest before and settled after" {
    try compile(&compiled, pop_file);
    const program = compiled.program;
    const pops = compiled.signal("pops").?;
    var state = State.init(program, slab[0..program.slab_count]);
    const table = program.cues.table();
    var reached: [lanes_count]Event = undefined;
    var events: [8]Event = undefined;
    const found = state.events(ms(0), ms(end_ms), &events);
    try testing.expectEqual(weft.Events{ .count = lanes_count, .dropped = 0 }, found);
    for (events[0..found.count]) |event| reached[event.instance] = event;
    for (table, 0..) |cue, lane| {
        // A lane's cue is an item of the list, where a retime writes it back (step 41).
        try testing.expectEqual(@as(u32, @intCast(lane)), compiled.cue_form(@intCast(lane)).?.listed.element);
        state.eval(.{ .flicks = cue.flicks - 1 });
        for (state.values(pops)[lane..]) |value| try testing.expectEqual(@as(f64, 0), value);
        state.eval(.{ .flicks = cue.flicks + 1 });
        try testing.expect(state.values(pops)[lane] > 0);
        var peak: f64 = 0;
        for (0..450) |after| {
            state.eval(.{ .flicks = cue.flicks + ms(@intCast(after)).flicks });
            peak = @max(peak, state.values(pops)[lane]);
        }
        try testing.expectApproxEqAbs(@as(f64, 1.3), peak, 1e-4);
        const settled = reached[lane].time;
        try testing.expectEqual(cue.flicks + ms(7417).flicks, @divTrunc(settled.flicks, ms(1).flicks) * ms(1).flicks);
        for ([_]i64{ 0, 1, ms(500).flicks }) |after| {
            state.eval(.{ .flicks = settled.flicks + after });
            try testing.expectEqual(@as(f64, 1), state.values(pops)[lane]);
        }
    }
}

var format_buffer: [1024]u8 = undefined;
var syntax: weft.lang.Syntax(limits) = undefined;

// Locks the formatter: a goal by lane in a path, inline and through Tapestry's `pop`, stays as
// written, and a loose one is written canonically.
test "the formatter keeps a goal by lane" {
    const canonical = pop_file ++ "ring = lanes(3, spring([s[lane]: vec2(1, 2)], time: 450ms))\n";
    try testing.expect(syntax.parse_source(canonical));
    try testing.expectEqualStrings(canonical, try syntax.format_into(&format_buffer));
    try testing.expect(syntax.parse_source(s_line ++ "ring = lanes(3,spring([ s[lane] :1 ],time:450ms))\n"));
    try testing.expectEqualStrings(s_line ++ "ring = lanes(3, spring([s[lane]: 1], time: 450ms))\n", try syntax.format_into(&format_buffer));
}
