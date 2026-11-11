//! Events by source (step 23): `State.events_of` against `State.events` filtered, and what a call
//! over solved sources leaves in the state, which is nothing.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Oracle
//! `events_of(sources)` is defined as `events` with every other source's events left out, so the
//! test runs both: one reader takes every event of a range into a buffer that holds them all, and
//! for every subset of the program's event sources, a fresh reader's `events_of` must give the
//! filtered list's first `out.len` events, in order, with the rest counted. The programs are the
//! catalog's six event graphs built together (three solved sources and three stepped ones) with a
//! chase beside them, and a region of a staggered bounce and a crossing of it. Each subset is run
//! as it is and with a node that fires nothing added, at the catalog's four epochs, over two
//! ranges, into buffers of 0, 1, 4, 16, and one more than the range holds. The counts of subsets
//! and calls are asserted, so the bound cannot grow or shrink unnoticed.
//!
//! ## 2. Changing Nothing
//! A call whose sources are all solved reads only the cue table, the goals, and a motion's
//! cursor, so it must leave every byte of the state as it was: the `State` itself, its slab with
//! the copy of the step before, and its checkpoints. The tests snapshot a reader before such calls
//! and compare after, then check that the next `eval` and `events` give what a reader that never
//! made them gives, at a time on a step and at one off it, and while a playhead moves forwards
//! and scrubs back.
//!
//! ## 3. From Text
//! `Compiled.event_sources` gives the list for a binding: through a `spread` and a `pack`, so a
//! region's bounce with no stagger and a vector's spring give their events, which `weft sample
//! --events` missed before this step (`test/cli.zig` locks the command's side).

const std = @import("std");
const testing = std.testing;
const weft = @import("weft");
const catalog = @import("catalog");
const Event = weft.Event;
const Events = weft.Events;
const Id = weft.Id;
const State = weft.State;
const Time = weft.Time;

const flicks_per_second = weft.time.flicks_per_second;
const step_flicks: i64 = weft.simulation.step.flicks;
const nodes_max = 64;
const slab_max = 1024;
const sources_max = 16;
/// Room for eight checkpoints, a second each, of a slab of `slab_max`.
const checkpoint_count = 8;
const events_max = 512;

/// The buffers each subset is read into, before the one a run's events all fit in.
const buffer_sizes = [_]usize{ 0, 1, 4, 16 };

/// A program built in place over the catalog's tables, which it points into, and its nodes sorted
/// into those that fire events and those that do not.
const Built = struct {
    tables: catalog.Tables,
    nodes: [nodes_max]weft.Node,
    program: weft.Program,
    fired: [sources_max]Id,
    fired_count: usize,
    silent: [nodes_max]Id,
    silent_count: usize,

    /// The catalog's six event graphs together, then a chase of a wave, which is simulated and
    /// fires nothing.
    fn catalog_all(built: *Built, epoch: *const catalog.Epoch) !void {
        built.tables.init(epoch);
        var builder = built.tables.builder(&built.nodes, slab_max);
        for (std.enums.values(catalog.EventGraph)) |graph| try catalog.event_graph_build(graph, &builder);
        const wave = try builder.wave(.{ .shape = .sine, .hz = 0.7 });
        _ = try builder.chase(.{ .target = wave, .from = 0, .time = ms(400), .overshoot = 0.1 });
        built.finish(&builder);
    }

    /// A region of four lanes: a bounce staggered by 100 ms, and a crossing of it at 0.5 either
    /// way, which is laned because its input is.
    fn laned(built: *Built, epoch: *const catalog.Epoch) !void {
        built.tables.init(epoch);
        var builder = built.tables.builder(&built.nodes, slab_max);
        builder.lanes = 4;
        const ball = try builder.bounce(.{
            .low = 0,
            .high = 1,
            .speed = 1.5,
            .start = .{ .index = 0 },
            .stagger = ms(100),
        });
        _ = try builder.crossing(.{ .input = ball.position, .level = 0.5, .direction = .both });
        built.finish(&builder);
    }

    fn finish(built: *Built, builder: *weft.Builder) void {
        built.program = builder.finish();
        built.fired_count = 0;
        built.silent_count = 0;
        for (built.program.nodes, 0..) |*node, index| {
            const id: Id = .{ .index = @intCast(index) };
            if (State.fires_events(node)) {
                built.fired[built.fired_count] = id;
                built.fired_count += 1;
            } else {
                built.silent[built.silent_count] = id;
                built.silent_count += 1;
            }
        }
    }

    /// The fired sources whose op is solved, ascending.
    fn solved(built: *const Built, out: []Id) []const Id {
        var count: usize = 0;
        for (built.fired[0..built.fired_count]) |id| {
            if (built.program.nodes[id.index].op.simulated()) continue;
            out[count] = id;
            count += 1;
        }
        return out[0..count];
    }

    fn first_silent(built: *const Built, comptime tag: std.meta.Tag(weft.graph.Op)) Id {
        for (built.silent[0..built.silent_count]) |id| {
            if (built.program.nodes[id.index].op == tag) return id;
        }
        unreachable;
    }

    fn start(built: *const Built) Time {
        return built.program.cues.at(built.program.start);
    }
};

var program_built: Built = undefined;
var slab: [slab_max]f64 = undefined;
var other_slab: [slab_max]f64 = undefined;
var checkpoints: [checkpoint_count * slab_max]f64 = undefined;
var other_checkpoints: [checkpoint_count * slab_max]f64 = undefined;
var all_events: [events_max]Event = undefined;
var wanted: [events_max]Event = undefined;
var got: [events_max]Event = undefined;

fn ms(count: i64) Time {
    return .{ .flicks = @divExact(flicks_per_second, 1000) * count };
}

fn after(time: Time, flicks: i64) Time {
    return .{ .flicks = time.flicks + flicks };
}

/// Puts `id` into the ascending `list[0..count]`, and returns the new count.
fn insert(list: []Id, count: usize, id: Id) usize {
    var at = count;
    while (at > 0 and list[at - 1].index > id.index) : (at -= 1) list[at] = list[at - 1];
    list[at] = id;
    return count + 1;
}

fn listed(list: []const Id, id: Id) bool {
    for (list) |each| if (each.index == id.index) return true;
    return false;
}

/// What the oracle ran: lists of sources and `events_of` calls.
const Tally = struct {
    lists: usize = 0,
    calls: usize = 0,
    mixed: usize = 0,
};

/// Section 1 on one program and one range: every subset of its event sources, as it is and with
/// a node that fires nothing, against the reference reader's events filtered.
fn oracle(t0: Time, t1: Time, tally: *Tally) !void {
    const program = program_built.program;
    const reader_slab = slab[0..@intCast(@max(program.reader_slab_count(), program.slab_count))];
    var reference = State.init(program, reader_slab);
    const full = reference.events(t0, t1, &all_events);
    try testing.expectEqual(@as(u64, 0), full.dropped);
    // Every source fires in the range, so no subset is vacuous.
    for (program_built.fired[0..program_built.fired_count]) |id| {
        var fires = false;
        for (all_events[0..full.count]) |event| fires = fires or event.source.index == id.index;
        try testing.expect(fires);
    }
    const subsets = @as(usize, 1) << @intCast(program_built.fired_count);
    for (0..subsets) |mask| for (0..2) |with_silent| {
        var list: [sources_max + 1]Id = undefined;
        var count: usize = 0;
        var solved = false;
        var stepped = false;
        for (program_built.fired[0..program_built.fired_count], 0..) |id, bit| {
            if (mask & (@as(usize, 1) << @intCast(bit)) == 0) continue;
            count = insert(&list, count, id);
            if (program.nodes[id.index].op.simulated()) stepped = true else solved = true;
        }
        if (with_silent == 1) count = insert(&list, count, program_built.silent[mask % program_built.silent_count]);
        const sources = list[0..count];
        try testing.expect(State.sources_valid(&program, sources));
        tally.lists += 1;
        tally.mixed += @intFromBool(solved and stepped);
        var wanted_count: usize = 0;
        for (all_events[0..full.count]) |event| {
            if (!listed(sources, event.source)) continue;
            wanted[wanted_count] = event;
            wanted_count += 1;
        }
        const sizes = buffer_sizes ++ [_]usize{full.count + 1};
        for (sizes) |size| {
            var state = State.init(program, reader_slab);
            const result = state.events_of(sources, t0, t1, got[0..size]);
            const kept = @min(size, wanted_count);
            try testing.expectEqual(Events{ .count = @intCast(kept), .dropped = wanted_count - kept }, result);
            try testing.expectEqualSlices(Event, wanted[0..kept], got[0..kept]);
            tally.calls += 1;
        }
    };
}

// Locks section 1: for all 64 subsets of the catalog's six event sources and all 4 of the region's
// two, each as it is and with a node that fires nothing, `events_of` equals `events` filtered,
// event for event, with count and dropped, at 4 epochs, 2 ranges, and 5 buffer sizes: 136 lists a
// range, 1,088 lists, and 5,440 calls; 800 of the lists, 4,000 calls, mix solved and stepped sources.
test "events_of is events filtered by source, for every subset" {
    var tally: Tally = .{};
    for (&catalog.epochs) |*epoch| {
        const zero: Time = .{ .flicks = epoch.seconds * flicks_per_second };
        const end = after(zero, catalog.event_range_seconds * flicks_per_second);
        // A range inside the first, off every step and cue, so a reader seeks into it.
        const inner_t0 = after(zero, 1_300 * @divExact(flicks_per_second, 1000) + 17);
        const inner_t1 = after(zero, 4_700 * @divExact(flicks_per_second, 1000) + 5);
        for ([_][2]Time{ .{ zero, end }, .{ inner_t0, inner_t1 } }) |range| {
            try program_built.catalog_all(epoch);
            try testing.expectEqual(@as(usize, 6), program_built.fired_count);
            try oracle(range[0], range[1], &tally);
            try program_built.laned(epoch);
            try testing.expectEqual(@as(usize, 2), program_built.fired_count);
            try oracle(range[0], range[1], &tally);
        }
    }
    try testing.expectEqual(@as(usize, (64 + 4) * 2 * 4 * 2), tally.lists);
    try testing.expectEqual(@as(usize, 1_088), tally.lists);
    try testing.expectEqual(@as(usize, 5_440), tally.calls);
    // 7 * 7 of the catalog's 64 subsets mix a solved and a stepped source, and 1 of the region's 4.
    try testing.expectEqual(@as(usize, (49 + 1) * 2 * 4 * 2), tally.mixed);
    try testing.expectEqual(@as(usize, 800), tally.mixed);
}

/// Every byte a reader holds: the `State`, its slab with the copy after it, and its checkpoints.
const Snapshot = struct {
    state: [@sizeOf(State)]u8,
    slab: [slab_max]f64,
    checkpoints: [checkpoint_count * slab_max]f64,

    fn take(snapshot: *Snapshot, state: *const State) void {
        @memcpy(&snapshot.state, std.mem.asBytes(state));
        snapshot.slab = slab;
        snapshot.checkpoints = checkpoints;
    }

    fn expect_same(snapshot: *const Snapshot, state: *const State) !void {
        try testing.expectEqualSlices(u8, &snapshot.state, std.mem.asBytes(state));
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&snapshot.slab), std.mem.sliceAsBytes(&slab));
        try testing.expectEqualSlices(
            u8,
            std.mem.sliceAsBytes(&snapshot.checkpoints),
            std.mem.sliceAsBytes(&checkpoints),
        );
    }
};

var kept_snapshot: Snapshot = undefined;

/// A reader of `program_built.program` over the file's slab and checkpoints, with the copy of the step
/// before, and a second over the other ones.
fn readers() [2]State {
    const size: usize = @intCast(program_built.program.reader_slab_count());
    std.debug.assert(size > program_built.program.slab_count);
    return .{
        State.init_with_checkpoints(program_built.program, slab[0..size], &checkpoints),
        State.init_with_checkpoints(program_built.program, other_slab[0..size], &other_checkpoints),
    };
}

/// Both readers' outputs after an `eval`, every node's values, bit for bit, and their steps.
fn expect_same_reads(a: *const State, b: *const State) !void {
    try testing.expectEqual(b.steps_run, a.steps_run);
    try testing.expectEqual(b.step, a.step);
    for (0..program_built.program.nodes.len) |index| {
        const id: Id = .{ .index = @intCast(index) };
        try testing.expectEqualSlices(
            u8,
            std.mem.sliceAsBytes(b.values(id)),
            std.mem.sliceAsBytes(a.values(id)),
        );
    }
}

// Locks section 2: on the catalog's program, a reader with checkpoints and the copy of the step
// before evaluates at a time on step 2,000 and at one 12,345 flicks off step 3,000, then asks for
// the events of its three solved sources over 3 s behind to 3 s ahead, of the chase alone, and of
// none. Every byte of the state, slab, and checkpoints is as it was, and the next eval and events
// match a reader that made none of those calls, steps and bits.
test "a call over solved sources changes nothing in the state" {
    try program_built.catalog_all(&catalog.epochs[0]);
    var pair = readers();
    const a = &pair[0];
    const b = &pair[1];
    var solved_ids: [sources_max]Id = undefined;
    const solved = program_built.solved(&solved_ids);
    try testing.expectEqual(@as(usize, 3), solved.len);
    const chase = [_]Id{program_built.first_silent(.chase)};
    const start = program_built.start();
    const times = [_]Time{
        after(start, 2_000 * step_flicks),
        after(start, 3_000 * step_flicks + 12_345),
    };
    for (times) |time| {
        a.eval(time);
        b.eval(time);
        try testing.expect(a.steps_run > 0);
        kept_snapshot.take(a);
        var out: [64]Event = undefined;
        const window = a.events_of(solved, after(time, -3 * flicks_per_second), after(time, 3 * flicks_per_second), &out);
        try testing.expect(window.count > 0);
        try testing.expectEqual(Events{ .count = 0, .dropped = 0 }, a.events_of(&chase, after(time, -flicks_per_second), time, &out));
        try testing.expectEqual(Events{ .count = 0, .dropped = 0 }, a.events_of(&.{}, after(time, -flicks_per_second), time, &out));
        try kept_snapshot.expect_same(a);
        // `value` still reads the last eval.
        try expect_same_reads(a, b);

        const next = after(time, 4 * step_flicks + 777);
        a.eval(next);
        b.eval(next);
        try expect_same_reads(a, b);
        var a_out: [64]Event = undefined;
        var b_out: [64]Event = undefined;
        const later = after(next, flicks_per_second);
        const a_found = a.events(next, later, &a_out);
        const b_found = b.events(next, later, &b_out);
        try testing.expectEqual(b_found, a_found);
        try testing.expectEqualSlices(Event, b_out[0..b_found.count], a_out[0..a_found.count]);
        try testing.expectEqual(b.steps_run, a.steps_run);
    }
}

// Locks the other half of the contract: a list that mixes solved and stepped sources steps exactly
// as `events` does. Over [1 s, 5 s) after an eval at 0.75 s, `events_of` of every source but the
// cues runs the same steps, leaves the same slab and copy bit for bit, and the same step, copy,
// and checkpoints filled, as `events`.
test "a mixed call steps exactly as events does" {
    try program_built.catalog_all(&catalog.epochs[1]);
    var pair = readers();
    const a = &pair[0];
    const b = &pair[1];
    const start = program_built.start();
    var list: [sources_max]Id = undefined;
    var count: usize = 0;
    for (program_built.fired[0..program_built.fired_count]) |id| {
        if (program_built.program.nodes[id.index].op == .cues) continue;
        list[count] = id;
        count += 1;
    }
    try testing.expectEqual(@as(usize, 5), count);
    a.eval(after(start, 3 * flicks_per_second / 4));
    b.eval(after(start, 3 * flicks_per_second / 4));
    var a_out: [64]Event = undefined;
    var b_out: [64]Event = undefined;
    const t0 = after(start, flicks_per_second);
    const t1 = after(start, 5 * flicks_per_second);
    const a_found = a.events_of(list[0..count], t0, t1, &a_out);
    const b_found = b.events(t0, t1, &b_out);
    try testing.expect(a_found.count > 0);
    try testing.expect(a_found.count < b_found.count);
    try testing.expectEqual(b.steps_run, a.steps_run);
    try testing.expectEqual(b.step, a.step);
    try testing.expectEqual(b.recent_step, a.recent_step);
    try testing.expectEqual(b.checkpoints_filled, a.checkpoints_filled);
    try testing.expectEqual(b.evaluated, a.evaluated);
    const size: usize = @intCast(program_built.program.reader_slab_count());
    try testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(other_slab[0..size]),
        std.mem.sliceAsBytes(slab[0..size]),
    );
}

// Locks the edges: an empty list gives {0, 0}; the bounce's velocity, a tween, and the chase fire
// nothing and run no step, even on a program that steps; a crossing alone steps; and a list that
// is not strictly ascending, repeats a node, or names one past the program is not valid.
test "an empty list, sources that fire nothing, and invalid lists" {
    try program_built.catalog_all(&catalog.epochs[0]);
    var pair = readers();
    const a = &pair[0];
    const start = program_built.start();
    var out: [16]Event = undefined;
    const t1 = after(start, 2 * flicks_per_second);
    try testing.expectEqual(Events{ .count = 0, .dropped = 0 }, a.events_of(&.{}, start, t1, &out));
    for ([_]Id{ program_built.first_silent(.bounce), program_built.first_silent(.tween), program_built.first_silent(.chase) }) |id| {
        try testing.expectEqual(Events{ .count = 0, .dropped = 0 }, a.events_of(&.{id}, start, t1, &out));
    }
    try testing.expectEqual(@as(u64, 0), a.steps_run);
    try testing.expectEqual(@as(?u64, null), a.step);

    var crossing: Id = undefined;
    for (program_built.fired[0..program_built.fired_count]) |id| {
        if (program_built.program.nodes[id.index].op == .crossing) crossing = id;
    }
    const found = a.events_of(&.{crossing}, start, t1, &out);
    try testing.expectEqual(@as(u32, 1), found.count);
    try testing.expect(a.steps_run > 0);

    const program = &program_built.program;
    const past: Id = .{ .index = @intCast(program.nodes.len) };
    try testing.expect(State.sources_valid(program, &.{}));
    try testing.expect(State.sources_valid(program, &.{ .{ .index = 0 }, .{ .index = 2 } }));
    try testing.expect(!State.sources_valid(program, &.{ .{ .index = 2 }, .{ .index = 0 } }));
    try testing.expect(!State.sources_valid(program, &.{ .{ .index = 1 }, .{ .index = 1 } }));
    try testing.expect(!State.sources_valid(program, &.{past}));
}

// Locks what a build without safety gives for an invalid list, which is an assert elsewhere: the
// unsorted, repeated, and past-the-end lists of the catalog's sources read as the empty list,
// {0, 0}, and leave every byte of the state as it was. Skipped where asserts run.
test "an invalid list reads as empty where asserts are compiled out" {
    if (std.debug.runtime_safety) return error.SkipZigTest;
    try program_built.catalog_all(&catalog.epochs[0]);
    var pair = readers();
    const a = &pair[0];
    const start = program_built.start();
    a.eval(after(start, flicks_per_second));
    kept_snapshot.take(a);
    const fired = program_built.fired[0..program_built.fired_count];
    const past: Id = .{ .index = @intCast(program_built.program.nodes.len) };
    const lists = [_][]const Id{
        &.{ fired[3], fired[0] },
        &.{ fired[1], fired[1] },
        &.{ fired[0], past },
    };
    var out: [16]Event = undefined;
    for (lists) |list| {
        try testing.expect(!State.sources_valid(&program_built.program, list));
        const found = a.events_of(list, start, after(start, 4 * flicks_per_second), &out);
        try testing.expectEqual(Events{ .count = 0, .dropped = 0 }, found);
    }
    try kept_snapshot.expect_same(a);
}

// Locks section 2 while time moves: a reader that reads the events of its solved sources 3 s
// behind to 3 s ahead after each eval, playing 300 frames at 60 Hz, then scrubbing back to 2 s,
// 4.5 s, and 1.25 s and playing 30 frames from each, reads every node's values bit for bit and
// runs every step as a reader that only evaluates.
test "events_of over solved sources between evals, forwards and scrubbing back" {
    try program_built.catalog_all(&catalog.epochs[2]);
    var pair = readers();
    const a = &pair[0];
    const b = &pair[1];
    var solved_ids: [sources_max]Id = undefined;
    const solved = program_built.solved(&solved_ids);
    const rate = weft.Rate.from_hz(60).?;
    const zero = program_built.start();
    const runs = [_][2]i64{ .{ 0, 300 }, .{ 120, 30 }, .{ 270, 30 }, .{ 75, 30 } };
    var frames: usize = 0;
    var kept: u64 = 0;
    for (runs) |run| {
        for (0..@intCast(run[1])) |at| {
            const tick = run[0] + @as(i64, @intCast(at));
            const time = after(zero, weft.Time.from_ticks(tick, rate).?.flicks);
            a.eval(time);
            b.eval(time);
            var out: [64]Event = undefined;
            const window = a.events_of(solved, after(time, -3 * flicks_per_second), after(time, 3 * flicks_per_second), &out);
            kept += window.count;
            try expect_same_reads(a, b);
            frames += 1;
        }
    }
    try testing.expectEqual(@as(usize, 390), frames);
    try testing.expect(kept > 0);
}

const limits: weft.lang.Limits = .{
    .tokens = 512,
    .tree = 256,
    .names = 32,
    .nodes = 32,
    .slab = 1 << 12,
    .cues = 8,
    .goals = 16,
    .regions = 4,
    .tracks = 2,
    .track_samples = 4,
    .modules = 4,
};
var compiled: weft.lang.Compiled(limits) = undefined;

/// The ops of `name`'s event sources, after its first node's op.
fn sources_of(name: []const u8, out: []Id) ![]const Id {
    var found: [weft.graph.components_max]Id = undefined;
    const list = compiled.event_sources(name, &found);
    @memcpy(out[0..list.len], list);
    return out[0..list.len];
}

fn op_of(id: Id) std.meta.Tag(weft.graph.Op) {
    return std.meta.activeTag(compiled.program.nodes[id.index].op);
}

// Locks `event_sources` (section 3): a region's bounce with no stagger is a spread of one bounce,
// whose position is its source; with a stagger the bounce is the first node; a `vec2` spring is a
// pack of two springs, both sources, ascending; a vector of one spring twice gives it once; a
// crossing is its own source; and a wave, a bounce scaled, and a name that is no signal give none.
// `events_of` over each list keeps events where the first node alone kept none.
test "event_sources follows a spread and a pack" {
    const text =
        \\cue go = 0s
        \\cue c1 = 1s
        \\plain = lanes(4, bounce(0..1, speed: 2, at: go))
        \\staggered = lanes(4, bounce(0..1, speed: 2, at: go, stagger: 100ms))
        \\v = spring([go: vec2(0, 0), c1: vec2(1, 2)], time: 0.5s)
        \\s = spring([go: 0, c1: 1], time: 0.5s)
        \\twice = vec2(s, s)
        \\w = wave(sine, 1hz)
        \\x = crossing(w, level: 0)
        \\scaled = bounce(0..1, speed: 2, at: go) * 2
        \\
    ;
    try compiled.compile(text);
    var out: [weft.graph.components_max]Id = undefined;

    const plain = try sources_of("plain", &out);
    try testing.expect(op_of(compiled.signal("plain").?) == .spread);
    try testing.expectEqual(@as(usize, 1), plain.len);
    try testing.expect(op_of(plain[0]) == .bounce);
    try testing.expectEqual(compiled.program.nodes[compiled.signal("plain").?.index].op.spread, plain[0]);

    var staggered_out: [weft.graph.components_max]Id = undefined;
    const staggered = try sources_of("staggered", &staggered_out);
    try testing.expectEqualSlices(Id, &.{compiled.signal("staggered").?}, staggered);

    var v_out: [weft.graph.components_max]Id = undefined;
    const v = try sources_of("v", &v_out);
    try testing.expect(op_of(compiled.signal("v").?) == .pack);
    try testing.expectEqual(@as(usize, 2), v.len);
    try testing.expect(v[0].index < v[1].index);
    for (v) |id| try testing.expect(op_of(id) == .motion);

    var twice_out: [weft.graph.components_max]Id = undefined;
    try testing.expectEqualSlices(Id, &.{compiled.signal("s").?}, try sources_of("twice", &twice_out));
    var x_out: [weft.graph.components_max]Id = undefined;
    try testing.expectEqualSlices(Id, &.{compiled.signal("x").?}, try sources_of("x", &x_out));
    var none_out: [weft.graph.components_max]Id = undefined;
    try testing.expectEqual(@as(usize, 0), (try sources_of("w", &none_out)).len);
    try testing.expectEqual(@as(usize, 0), (try sources_of("scaled", &none_out)).len);
    try testing.expectEqual(@as(usize, 0), (try sources_of("go", &none_out)).len);
    try testing.expectEqual(@as(usize, 0), (try sources_of("nothing", &none_out)).len);

    const program = compiled.program;
    var reader = State.init(program, slab[0..@intCast(program.reader_slab_count())]);
    var events_out: [64]Event = undefined;
    const t1: Time = .{ .flicks = 3 * flicks_per_second };
    // A bounce of 2 units a second over 0..1 hits every half second from 0.5 s: 5 hits before 3 s,
    // on its one lane; staggered, its four lanes hit 5, 5, 5, and 5 times.
    try testing.expectEqual(Events{ .count = 5, .dropped = 0 }, reader.events_of(plain, .{ .flicks = 0 }, t1, &events_out));
    try testing.expectEqual(Events{ .count = 20, .dropped = 0 }, reader.events_of(staggered, .{ .flicks = 0 }, t1, &events_out));
    try testing.expect(reader.events_of(v, .{ .flicks = 0 }, t1, &events_out).count > 0);
    // The first nodes alone, as `--events` read them before this step.
    try testing.expectEqual(Events{ .count = 0, .dropped = 0 }, reader.events_of(&.{compiled.signal("plain").?}, .{ .flicks = 0 }, t1, &events_out));
    try testing.expectEqual(Events{ .count = 0, .dropped = 0 }, reader.events_of(&.{compiled.signal("v").?}, .{ .flicks = 0 }, t1, &events_out));
}
