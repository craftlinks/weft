//! Tests of the graph: events.
//!
//! They read `graph.zig` and `state.zig` as a client would, plus the few internals that
//! `graph.zig` marks public for its reader and its tests.

const std = @import("std");
const Cue = @import("../cue.zig").Cue;
const Cues = @import("../cue.zig").Cues;
const event_module = @import("../event.zig");
const Event = event_module.Event;
const Events = event_module.Events;
const motion = @import("../motion.zig");
const Goal = motion.Goal;
const simulation = @import("../simulation.zig");
const time_module = @import("../time.zig");
const Time = time_module.Time;
const track_module = @import("../track.zig");
const Tracks = track_module.Tracks;
const graph_module = @import("../graph.zig");
const state_module = @import("../state.zig");
const testing = std.testing;
const flicks_per_second = @import("../time.zig").flicks_per_second;
const State = graph_module.State;
const Fixture = @import("simulated.zig").Fixture;
const tween_of = @import("tween.zig").tween_of;
const Bounce = graph_module.Bounce;
const BounceIds = graph_module.BounceIds;
const Builder = graph_module.Builder;
const Crossing = graph_module.Crossing;
const CueSpan = graph_module.CueSpan;
const Id = graph_module.Id;
const Node = graph_module.Node;
const Program = graph_module.Program;
const flicks_per_second_float = graph_module.flicks_per_second_float;
const pass = state_module.pass;
const step_ceiling = state_module.step_ceiling;

/// One cue at 0, for the event tests of a single source.
pub fn cue_table_at_zero(times: *[1]Time) !Cues {
    var cues = Cues.init(times);
    _ = try cues.add(.{ .flicks = 0 });
    return cues;
}

/// A bounce between 0 and 1 at 0.7 units a second from the cue at 0, alone in a program.
fn bounce_alone(nodes: *[2]Node, cues: *const Cues) !BounceIds {
    var builder = Builder.init(nodes, .{ .slab_count_max = 2, .cues = cues });
    const ids = try builder.bounce(.{
        .low = 0,
        .high = 1,
        .speed = 0.7,
        .start = .{ .index = 0 },
    });
    _ = builder.finish();
    return ids;
}

// Locks the bounce worked on the page: 0.7 units a second between 0 and 1 is a leg of
// 1,008,000,000.0000001 flicks in an f64, so the hits are one flick after each 1/0.7 s, at
// 1,008,000,001, 2,016,000,001, 3,024,000,001, and 4,032,000,001. [0, 1 s) has none, [1, 2 s) the
// first at +0.7, and [2, 3 s) the second at -0.7. At each hit the position is on its wall exactly,
// and a flick before, it is not.
test "a bounce hits its walls at exact flicks" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var nodes: [2]Node = undefined;
    const ids = try bounce_alone(&nodes, &cues);
    const program: Program = .{
        .nodes = &nodes,
        .cues = &cues,
        .goals = &.{},
        .regions = &.{},
        .samples = &.{},
        .tracks = &Tracks.empty,
        .start = .{ .index = 0 },
        .simulated = false,
        .slab_count = 2,
    };
    var slab: [2]f64 = undefined;
    var state = State.init(program, &slab);
    var out: [4]Event = undefined;
    const second = flicks_per_second;
    try testing.expectEqual(Events{ .count = 0, .dropped = 0 }, state.events(
        .{ .flicks = 0 },
        .{ .flicks = second },
        &out,
    ));
    const first = state.events(.{ .flicks = second }, .{ .flicks = 2 * second }, &out);
    try testing.expectEqual(Events{ .count = 1, .dropped = 0 }, first);
    try testing.expectEqual(Event{
        .time = .{ .flicks = 1_008_000_001 },
        .source = ids.position,
        .instance = 0,
        .value = 0.7,
    }, out[0]);
    const next = state.events(.{ .flicks = 2 * second }, .{ .flicks = 3 * second }, &out);
    try testing.expectEqual(Events{ .count = 1, .dropped = 0 }, next);
    try testing.expectEqual(@as(i64, 2_016_000_001), out[0].time.flicks);
    try testing.expectEqual(@as(f64, -0.7), out[0].value);

    const all = state.events(.{ .flicks = 0 }, .{ .flicks = 6 * second }, &out);
    try testing.expectEqual(Events{ .count = 4, .dropped = 0 }, all);
    const hits = [_]i64{ 1_008_000_001, 2_016_000_001, 3_024_000_001, 4_032_000_001 };
    for (out, hits, 0..) |event, flicks, index| {
        try testing.expectEqual(flicks, event.time.flicks);
        const wall: f64 = if (index % 2 == 0) 1 else 0;
        state.eval(event.time);
        try testing.expectEqual(wall, state.value(ids.position));
        const velocity_after: f64 = if (index % 2 == 0) -0.7 else 0.7;
        try testing.expectEqual(velocity_after, state.value(ids.velocity));
        state.eval(.{ .flicks = flicks - 1 });
        try testing.expect(state.value(ids.position) != wall);
        try testing.expectEqual(event.value, state.value(ids.velocity));
    }
    state.eval(.{ .flicks = -1 });
    try testing.expectEqual(@as(f64, 0), state.value(ids.position));
    try testing.expectEqual(@as(f64, 0), state.value(ids.velocity));
    // Halfway through 0.5 s of real time is not halfway through the first leg, a flick longer.
    state.eval(.{ .flicks = 504_000_000 });
    try testing.expectEqual(@as(f64, 504_000_000.0 / 1_008_000_001.0), state.value(ids.position));
}

/// The event sources of the mixed graph, each of which can also be built alone.
const Source = enum { bounce, crossing, follow, shift, cues, spring };

/// A start cue half a step after 0.5 s, so no reader at a rate that divides 480 Hz lands on a
/// step, then cues at 2, 5, 5, and 9 s. A graph of every event source: a bounce, a crossing of 0
/// by a chase of a slow wave, a follower, a shift register, the cues, and a spring with a goal at
/// each cue but the start, or one of them alone.
const Mixed = struct {
    times: [5]Time,
    cues: Cues,
    region_entries: [2]simulation.Region,
    regions: simulation.Regions,
    goal_entries: [4]Goal,
    goals: motion.Goals,
    nodes: [12]Node,
    program: Program,

    const slab_count_max = 64;

    fn init(mixed: *Mixed, only: ?Source) !void {
        mixed.cues = Cues.init(&mixed.times);
        const start = try mixed.cues.add(.{
            .flicks = flicks_per_second / 2 + simulation.step.flicks / 2,
        });
        var cues: [4]Cue = undefined;
        for (&cues, [_]i64{ 2, 5, 5, 9 }) |*cue, seconds| {
            cue.* = try mixed.cues.add(.{ .flicks = seconds * flicks_per_second });
        }
        mixed.regions = simulation.Regions.init(&mixed.region_entries);
        const span = try mixed.regions.add(&.{
            .{ .low = -1, .high = -0.5 },
            .{ .low = 0.5, .high = 1 },
        });
        mixed.goals = motion.Goals.init(&mixed.goal_entries);
        const path = try mixed.goals.add(&.{
            .{ .cue = cues[0], .value = 1 },
            .{ .cue = cues[1], .value = -1 },
            .{ .cue = cues[2], .value = 0.5 },
            .{ .cue = cues[3], .value = 0.5 },
        });
        var builder = Builder.init(&mixed.nodes, .{
            .slab_count_max = slab_count_max,
            .cues = &mixed.cues,
            .goals = mixed.goals.table(),
            .regions = mixed.regions.table(),
            .start = start,
            .seed = 33,
        });
        for (std.enums.values(Source)) |source| {
            if (only) |alone| if (alone != source) continue;
            try build_source(&builder, source, start, span, path);
        }
        mixed.program = builder.finish();
    }

    fn build_source(
        builder: *Builder,
        source: Source,
        start: Cue,
        span: simulation.Span,
        path: motion.Path,
    ) !void {
        switch (source) {
            .bounce => _ = try builder.bounce(.{
                .low = -1,
                .high = 1,
                .speed = 1.4,
                .start = start,
            }),
            .crossing => {
                const wave = try builder.wave(.{ .shape = .triangle, .hz = 0.5 });
                const chase = try builder.chase(.{
                    .target = wave,
                    .from = 0,
                    .time = .{ .flicks = flicks_per_second / 3 },
                    .overshoot = 0.2,
                });
                _ = try builder.crossing(.{ .input = chase, .level = 0, .direction = .both });
            },
            .follow => _ = try builder.follow(.{
                .from = 0,
                .regions = span,
                .pick = .random,
                .mover = .{ .spring = .{
                    .time = .{ .flicks = flicks_per_second / 4 },
                    .overshoot = 0,
                } },
                .tolerance = 0.01,
                .pause_min = .{ .flicks = flicks_per_second / 10 },
                .pause_max = .{ .flicks = flicks_per_second * 3 / 10 },
                .seed = 3,
            }),
            .shift => _ = try builder.shift(.{
                .buckets = 8,
                .period = .{ .flicks = 2 * flicks_per_second },
                .low = -1,
                .high = 1,
                .odds = 0.5,
                .shape = .smooth,
                .seed = 4,
            }),
            .cues => _ = try builder.cues(.{ .first = start, .count = 5 }),
            .spring => _ = try builder.spring(.{
                .from = 0,
                .goals = path,
                .time = .{ .flicks = flicks_per_second / 2 },
                .overshoot = 0.1,
            }),
        }
    }
};

const events_max = 1 << 15;
pub var events_whole: [events_max]Event = undefined;
pub var events_joined: [events_max]Event = undefined;

/// The events of `[0, end)` on a fresh reader of `program`, in `out`, none dropped.
pub fn events_at_once(program: Program, end: Time, out: []Event) ![]const Event {
    var slab: [Mixed.slab_count_max]f64 = undefined;
    var state = State.init(program, &slab);
    const result = state.events(.{ .flicks = 0 }, end, out);
    try testing.expectEqual(@as(u64, 0), result.dropped);
    return out[0..result.count];
}

/// How a test splits `[0, end)`: into blocks of one length, or at drawn cut points.
pub const Split = union(enum) {
    block: i64,
    drawn: u64,
};

/// The events of `[0, end)` on a fresh reader of `program`, split as `split` says, each range's
/// events after the last's in `out`, none dropped. Between ranges it evaluates at `eval_seed`'s
/// drawn times, if given.
pub fn events_split(
    program: Program,
    end: Time,
    split: Split,
    eval_seed: ?u64,
    out: []Event,
) ![]const Event {
    var slab: [Mixed.slab_count_max]f64 = undefined;
    var checkpoints: [4 * Mixed.slab_count_max]f64 = undefined;
    var state = State.init_with_checkpoints(program, slab[0..program.slab_count], &checkpoints);
    var prng = std.Random.DefaultPrng.init(switch (split) {
        .block => 0,
        .drawn => |seed| seed,
    });
    var evals = std.Random.DefaultPrng.init(eval_seed orelse 0);
    var count: u32 = 0;
    var t0: Time = .{ .flicks = 0 };
    while (t0.flicks < end.flicks) {
        const length: i64 = switch (split) {
            .block => |block| block,
            // Empty ranges, a flick, and up to a second and a half.
            .drawn => prng.random().intRangeLessThan(i64, 0, 3 * flicks_per_second / 2),
        };
        const t1: Time = .{ .flicks = @min(t0.flicks + length, end.flicks) };
        const result = state.events(t0, t1, out[count..]);
        try testing.expectEqual(@as(u64, 0), result.dropped);
        count += result.count;
        if (eval_seed != null) {
            state.eval(.{ .flicks = evals.random().intRangeLessThan(i64, 0, end.flicks) });
        }
        t0 = t1;
    }
    return out[0..count];
}

const audio_block_flicks = 1_881_600;

// Locks the splitting promise of section 11: for each source alone and for the mixed graph, the
// events of [0, 60 s) equal, byte for byte, the events of every split into audio blocks, 1/60 s,
// 1 s, and 7 s, and at drawn cut points, empty ranges among them. Every source fires.
test "splitting a range never changes its events" {
    const minute: Time = .{ .flicks = 60 * flicks_per_second };
    const splits = [_]Split{
        .{ .block = audio_block_flicks },
        .{ .block = flicks_per_second / 60 },
        .{ .block = flicks_per_second },
        .{ .block = 7 * flicks_per_second },
        .{ .drawn = 1 },
        .{ .drawn = 2 },
    };
    var mixed: Mixed = undefined;
    for ([_]?Source{ null, .bounce, .crossing, .follow, .shift, .cues, .spring }) |only| {
        try mixed.init(only);
        const whole = try events_at_once(mixed.program, minute, &events_whole);
        try testing.expect(whole.len > 0);
        for (splits) |split| {
            const joined = try events_split(mixed.program, minute, split, null, &events_joined);
            try testing.expectEqualSlices(Event, whole, joined);
        }
        if (only == null) {
            var sources_firing: u32 = 0;
            for (mixed.program.nodes, 0..) |_, index| {
                for (whole) |event| {
                    if (event.source.index == index) {
                        sources_firing += 1;
                        break;
                    }
                }
            }
            try testing.expectEqual(@as(u32, 6), sources_firing);
        }
    }
}

// Locks the splitting promise over an hour of the mixed graph, against blocks of a second.
test "an hour of events equals its seconds" {
    var mixed: Mixed = undefined;
    try mixed.init(null);
    const hour: Time = .{ .flicks = 3600 * flicks_per_second };
    const whole = try events_at_once(mixed.program, hour, &events_whole);
    try testing.expect(whole.len > 10_000);
    const split: Split = .{ .block = flicks_per_second };
    const joined = try events_split(mixed.program, hour, split, null, &events_joined);
    try testing.expectEqualSlices(Event, whole, joined);
}

// Locks that event times do not depend on the reader: blocks at 44.1 kHz and 48 kHz of 128
// samples, and at 60 Hz, give the events of the whole 10 s, and so does any of them with evals at
// drawn times between its ranges.
test "events ignore the reader's rate and its evals" {
    var mixed: Mixed = undefined;
    try mixed.init(null);
    const end: Time = .{ .flicks = 10 * flicks_per_second };
    const whole = try events_at_once(mixed.program, end, &events_whole);
    const blocks = [_]i64{ 128 * 16_000, audio_block_flicks, flicks_per_second / 60 };
    for (blocks, 0..) |block, index| {
        for ([_]?u64{ null, index + 7 }) |eval_seed| {
            const split: Split = .{ .block = block };
            const joined = try events_split(mixed.program, end, split, eval_seed, &events_joined);
            try testing.expectEqualSlices(Event, whole, joined);
        }
    }
}

// Locks the first decision of the page: [30 s, 40 s), then [5 s, 10 s), then [30 s, 40 s) again
// give the same events each time, with and without checkpoints, and the same as a fresh reader.
test "a past range gives its events again" {
    var mixed: Mixed = undefined;
    try mixed.init(null);
    const ranges = [_][2]i64{ .{ 30, 40 }, .{ 5, 10 }, .{ 30, 40 } };
    var first: [3][256]Event = undefined;
    var counts: [3]u32 = undefined;
    for (ranges, &first, &counts) |range, *out, *count| {
        var slab: [Mixed.slab_count_max]f64 = undefined;
        var state = State.init(mixed.program, &slab);
        const t0: Time = .{ .flicks = range[0] * flicks_per_second };
        const t1: Time = .{ .flicks = range[1] * flicks_per_second };
        const result = state.events(t0, t1, out);
        try testing.expectEqual(@as(u64, 0), result.dropped);
        count.* = result.count;
    }
    for ([_]u32{ 0, 64 }) |checkpoints_count| {
        var slab: [Mixed.slab_count_max]f64 = undefined;
        var checkpoints: [64 * Mixed.slab_count_max]f64 = undefined;
        const room = checkpoints[0 .. checkpoints_count * mixed.program.slab_count];
        const slab_used = slab[0..mixed.program.slab_count];
        var state = State.init_with_checkpoints(mixed.program, slab_used, room);
        for (ranges, first, counts) |range, expected, count| {
            var out: [256]Event = undefined;
            const t0: Time = .{ .flicks = range[0] * flicks_per_second };
            const t1: Time = .{ .flicks = range[1] * flicks_per_second };
            const result = state.events(t0, t1, &out);
            try testing.expectEqual(Events{ .count = count, .dropped = 0 }, result);
            try testing.expectEqualSlices(Event, expected[0..count], out[0..count]);
        }
    }
    try testing.expect(counts[0] > 10);
    try testing.expectEqualSlices(Event, first[0][0..counts[0]], first[2][0..counts[2]]);
}

// Locks the bound of section 11: over 10 s of consecutive 1/60 s ranges, each runs exactly the
// steps it spans, from the step the last one left, and an eval at its end runs none, since the
// start cue keeps every end off a step.
test "events never run ahead of the reader" {
    var mixed: Mixed = undefined;
    try mixed.init(null);
    const start = mixed.cues.at(mixed.program.start);
    var slab: [Mixed.slab_count_max]f64 = undefined;
    var state = State.init(mixed.program, &slab);
    var out: [64]Event = undefined;
    const frame = flicks_per_second / 60;
    for (0..600) |index| {
        const t0: Time = .{ .flicks = @as(i64, @intCast(index)) * frame };
        const t1: Time = .{ .flicks = t0.flicks + frame };
        const steps_before = state.steps_run;
        _ = state.events(t0, t1, &out);
        const spanned = step_ceiling(start, t1) - step_ceiling(start, t0);
        try testing.expectEqual(steps_before + spanned, state.steps_run);
        state.eval(t1);
        try testing.expectEqual(steps_before + spanned, state.steps_run);
    }
    try testing.expectEqual(@as(u64, 4800 - 240), state.steps_run);
}

// Locks the overflow rule of `event.zig`: a buffer of 2 over the 4 hits of the worked bounce keeps
// the first 2 and counts 2, an empty one counts all 4, and a canary after the buffer is untouched.
// Over a minute of the mixed graph, 10 kept events are the head of the full list, and the rest
// are counted exactly.
test "overflow keeps the earliest events and counts the rest exactly" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var nodes: [2]Node = undefined;
    _ = try bounce_alone(&nodes, &cues);
    const program: Program = .{
        .nodes = &nodes,
        .cues = &cues,
        .goals = &.{},
        .regions = &.{},
        .samples = &.{},
        .tracks = &Tracks.empty,
        .start = .{ .index = 0 },
        .simulated = false,
        .slab_count = 2,
    };
    var slab: [2]f64 = undefined;
    var state = State.init(program, &slab);
    const end: Time = .{ .flicks = 6 * flicks_per_second };
    var full: [4]Event = undefined;
    const zero: Time = .{ .flicks = 0 };
    try testing.expectEqual(Events{ .count = 4, .dropped = 0 }, state.events(zero, end, &full));
    var memory: [3]Event = undefined;
    const canary: Event = .{
        .time = .{ .flicks = -9 },
        .source = .{ .index = 9 },
        .instance = 9,
        .value = 9,
    };
    memory[2] = canary;
    const kept = state.events(zero, end, memory[0..2]);
    try testing.expectEqual(Events{ .count = 2, .dropped = 2 }, kept);
    try testing.expectEqualSlices(Event, full[0..2], memory[0..2]);
    try testing.expectEqual(canary, memory[2]);
    const counted = state.events(zero, end, memory[0..0]);
    try testing.expectEqual(Events{ .count = 0, .dropped = 4 }, counted);
    try testing.expectEqual(canary, memory[2]);

    var mixed: Mixed = undefined;
    try mixed.init(null);
    const minute: Time = .{ .flicks = 60 * flicks_per_second };
    const whole = try events_at_once(mixed.program, minute, &events_whole);
    var mixed_slab: [Mixed.slab_count_max]f64 = undefined;
    var mixed_state = State.init(mixed.program, &mixed_slab);
    var head: [10]Event = undefined;
    const result = mixed_state.events(.{ .flicks = 0 }, minute, &head);
    try testing.expectEqual(Events{ .count = 10, .dropped = whole.len - 10 }, result);
    try testing.expectEqualSlices(Event, whole[0..10], &head);
}

/// A program of one source over `input_build`'s input, a crossing of it at `level`, with the cue at
/// 0 as the start.
fn crossing_of_tween(nodes: *[2]Node, cues: *const Cues, level: f64) !Id {
    var builder = Builder.init(nodes, .{ .slab_count_max = 4, .cues = cues });
    var rise = tween_of(0, 1, .{ .index = 0 }, .linear);
    rise.duration = .{ .flicks = flicks_per_second };
    const input = try builder.tween(rise);
    const gate = try builder.crossing(.{ .input = input, .level = level, .direction = .rising });
    _ = builder.finish();
    return gate;
}

// Locks the crossing worked on the page: a linear tween from 0 to 1 over 1 s, crossed rising at
// 0.3, lands on the level at step 144, so its event is at exactly 0.3 s, 211,680,000 flicks, where
// the gate turns 1, and a flick before it is 0. At 0.301 the event is at 0.301 s, 212,385,600
// flicks, within a flick: the weight in the step is 0.48000000000000215, so it rounds up to
// 212,385,601. The value is the slope, 1 a second, and there is one event each.
test "a crossing fires where its input crosses, in the step" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    const rows = [_]struct { level: f64, flicks: i64 }{
        .{ .level = 0.3, .flicks = 211_680_000 },
        .{ .level = 0.301, .flicks = 212_385_601 },
    };
    for (rows) |row| {
        var nodes: [2]Node = undefined;
        const gate = try crossing_of_tween(&nodes, &cues, row.level);
        const program: Program = .{
            .nodes = &nodes,
            .cues = &cues,
            .goals = &.{},
            .regions = &.{},
            .samples = &.{},
            .tracks = &Tracks.empty,
            .start = .{ .index = 0 },
            .simulated = true,
            .slab_count = 4,
        };
        var slab: [4]f64 = undefined;
        var state = State.init(program, &slab);
        var out: [4]Event = undefined;
        const result = state.events(.{ .flicks = 0 }, .{ .flicks = 2 * flicks_per_second }, &out);
        try testing.expectEqual(Events{ .count = 1, .dropped = 0 }, result);
        try testing.expectEqual(gate, out[0].source);
        try testing.expectApproxEqAbs(@as(f64, 1), out[0].value, 1e-12);
        try testing.expectEqual(row.flicks, out[0].time.flicks);
        if (row.level == 0.3) {
            state.eval(out[0].time);
            try testing.expectEqual(@as(f64, 1), state.value(gate));
            state.eval(.{ .flicks = row.flicks - 1 });
            try testing.expectEqual(@as(f64, 0), state.value(gate));
        }
    }
}

// Locks the limit of section 11. A 960 Hz sine is two whole cycles a step, so at every step it is
// within rounding of 0, and its crossings of 0.5 come and go inside each step: a second of it
// gives no event, though the gate, exact at any time, is 1 a quarter cycle in. (A 1,000 Hz sine
// would alias to 40 Hz on the step grid and fire at that rate instead.) Falling and both see
// nothing either.
test "a crossing that comes back within a step gives no event" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    for (std.enums.values(Crossing.Direction)) |direction| {
        var nodes: [2]Node = undefined;
        var builder = Builder.init(&nodes, .{ .slab_count_max = 4, .cues = &cues });
        const wave = try builder.wave(.{ .shape = .sine, .hz = 960 });
        const gate = try builder.crossing(.{ .input = wave, .level = 0.5, .direction = direction });
        var slab: [4]f64 = undefined;
        var state = State.init(builder.finish(), &slab);
        var out: [4]Event = undefined;
        const result = state.events(.{ .flicks = 0 }, .{ .flicks = flicks_per_second }, &out);
        try testing.expectEqual(Events{ .count = 0, .dropped = 0 }, result);
        state.eval(.{ .flicks = flicks_per_second / 3840 });
        try testing.expectEqual(@as(f64, 1), state.value(gate));
        state.eval(.{ .flicks = 0 });
        try testing.expectEqual(@as(f64, 0), state.value(gate));
    }
}

/// Cues at 1 s and 4 s, one path over them, and a motion of `law` from `from`, alone. The goals
/// are `first` and `second`.
const Reach = struct {
    times: [2]Time,
    cues: Cues,
    entries: [2]Goal,
    goals: motion.Goals,
    nodes: [1]Node,
    program: Program,
    motion: Id,

    fn init(reach: *Reach, law: motion.Law, from: f64, first: f64, second: f64) !void {
        reach.cues = Cues.init(&reach.times);
        const cue_first = try reach.cues.add(.{ .flicks = flicks_per_second });
        const cue_second = try reach.cues.add(.{ .flicks = 4 * flicks_per_second });
        reach.goals = motion.Goals.init(&reach.entries);
        const path = try reach.goals.add(&.{
            .{ .cue = cue_first, .value = first },
            .{ .cue = cue_second, .value = second },
        });
        var builder = Builder.init(&reach.nodes, .{
            .slab_count_max = 1 + motion.cursor_count,
            .cues = &reach.cues,
            .goals = reach.goals.table(),
        });
        reach.motion = switch (law) {
            .spring => |spring| try builder.push(.{ .motion = .{
                .from = from,
                .goals = path,
                .law = .{ .spring = spring },
            } }),
            .newtonian => |limits| try builder.newtonian(.{
                .from = from,
                .goals = path,
                .speed = limits.speed,
                .accel = limits.accel,
                .decel = limits.decel,
            }),
        };
        reach.program = builder.finish();
    }

    /// The events of the first minute.
    fn events(reach: *const Reach, out: []Event) ![]const Event {
        var slab: [1 + motion.cursor_count]f64 = undefined;
        var state = State.init(reach.program, &slab);
        const result = state.events(.{ .flicks = 0 }, .{ .flicks = 60 * flicks_per_second }, out);
        try testing.expectEqual(@as(u64, 0), result.dropped);
        return out[0..result.count];
    }
};

// Locks a goal reached on the page's worked move: speed 4, accel 2, decel 4, from 0 to 2, takes
// sqrt 3 s, 1,222,135,049.8 flicks, so the event is 1,222,135,050 flicks after the cue at 1 s,
// the first flick where the closed form returns the goal at rest; the flick before does not. The
// next goal, 2 again, is already met at rest, so it fires at its own cue. Moving the first cue by
// 0.25 s moves its event by exactly that.
test "a Newtonian move fires when it lands, and a goal already met fires at its cue" {
    const limits: motion.Limits = .{ .speed = 4, .accel = 2, .decel = 4 };
    var reach: Reach = undefined;
    try reach.init(.{ .newtonian = limits }, 0, 2, 2);
    var out: [4]Event = undefined;
    const events = try reach.events(&out);
    try testing.expectEqual(@as(usize, 2), events.len);
    const landed = flicks_per_second + 1_222_135_050;
    try testing.expectEqual(Event{
        .time = .{ .flicks = landed },
        .source = reach.motion,
        .instance = 0,
        .value = 2,
    }, events[0]);
    try testing.expectEqual(@as(i64, 4 * flicks_per_second), events[1].time.flicks);
    const law: motion.Law = .{ .newtonian = limits };
    const rest: motion.Kinematics = .{ .position = 0, .velocity = 0 };
    const at: motion.Kinematics = .{ .position = 2, .velocity = 0 };
    const seconds_at = @as(f64, 1_222_135_050) / flicks_per_second_float;
    const seconds_before = @as(f64, 1_222_135_049) / flicks_per_second_float;
    try testing.expectEqual(at, motion.advance(law, rest, 2, seconds_at));
    try testing.expect(!std.meta.eql(at, motion.advance(law, rest, 2, seconds_before)));
    var slab: [1 + motion.cursor_count]f64 = undefined;
    var state = State.init(reach.program, &slab);
    state.eval(events[0].time);
    try testing.expectEqual(@as(f64, 2), state.value(reach.motion));

    try reach.cues.move(.{ .index = 0 }, .{ .flicks = flicks_per_second + flicks_per_second / 4 });
    const moved = try reach.events(&out);
    try testing.expectEqual(landed + flicks_per_second / 4, moved[0].time.flicks);
}

// Locks a spring's goal reached, and a goal cut short. A critical spring of omega 8 from 0 to 1
// settles after about 5.1 s, which is after the next cue at 4 s, so its first goal fires nothing;
// it settles on the second, -1, once, within a minute, where eval returns it exactly. A bouncy
// spring of overshoot 0.2 heading for 1 then back to 0 is the same: one event, the last goal.
test "a spring fires once when it settles, and a goal cut short fires nothing" {
    const critical = motion.SpringLaw.from_omega_zeta(8, 1);
    const bouncy = motion.SpringLaw.of(.{ .flicks = flicks_per_second / 2 }, 0.2);
    for ([_]motion.SpringLaw{ critical, bouncy }, [_]f64{ -1, 0 }) |law, second| {
        var reach: Reach = undefined;
        try reach.init(.{ .spring = law }, 0, 1, second);
        var out: [4]Event = undefined;
        const events = try reach.events(&out);
        try testing.expectEqual(@as(usize, 1), events.len);
        try testing.expectEqual(second, events[0].value);
        try testing.expect(events[0].time.flicks > 4 * flicks_per_second);
        var slab: [1 + motion.cursor_count]f64 = undefined;
        var state = State.init(reach.program, &slab);
        state.eval(events[0].time);
        try testing.expectEqual(second, state.value(reach.motion));
        // The flick before, the closed form from the second cue is not yet at rest on the goal.
        const op = &reach.program.nodes[0].op.motion;
        const cursor_none: [motion.cursor_count]f64 = @splat(0);
        const goals = reach.goals.table();
        const start = motion.kinematics_at_goal(op, goals, &reach.cues, &cursor_none, 1);
        const flicks_before = events[0].time.flicks - 1 - 4 * flicks_per_second;
        const seconds_before = @as(f64, @floatFromInt(flicks_before)) / flicks_per_second_float;
        const before = motion.advance(op.law, start, second, seconds_before);
        try testing.expect(before.position != second or before.velocity != 0);
    }
    // A Newtonian move too slow for its first goal before the next cue, then one that lands.
    var reach: Reach = undefined;
    try reach.init(.{ .newtonian = .{ .speed = 1, .accel = 1, .decel = 1 } }, 0, 10, 0);
    var out: [4]Event = undefined;
    const events = try reach.events(&out);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(@as(f64, 0), events[0].value);
}

// Locks the follower worked on the page: a Newtonian follower (speed 4, accel 2, decel 4) from 0
// to a goal of 2 arrives at step 832, so its first event is at 832 steps, 1,223,040,000 flicks
// after the start, with the goal as the value, and the next at step 2091, at 5.
test "a follower fires at the step it arrives" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var region_entries: [2]simulation.Region = undefined;
    var regions = simulation.Regions.init(&region_entries);
    const span = try regions.add(&.{ .{ .low = 2, .high = 2 }, .{ .low = 5, .high = 5 } });
    var nodes: [1]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 9,
        .cues = &cues,
        .regions = regions.table(),
    });
    const half_second: Time = .{ .flicks = flicks_per_second / 2 };
    const follower = try builder.follow(.{
        .from = 0,
        .regions = span,
        .pick = .cycle,
        .mover = .{ .newtonian = .{ .speed = 4, .accel = 2, .decel = 4 } },
        .tolerance = 0,
        .pause_min = half_second,
        .pause_max = half_second,
        .seed = 0,
    });
    var slab: [9]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    var out: [4]Event = undefined;
    const result = state.events(.{ .flicks = 0 }, .{ .flicks = 5 * flicks_per_second }, &out);
    try testing.expectEqual(Events{ .count = 2, .dropped = 0 }, result);
    try testing.expectEqual(Event{
        .time = .{ .flicks = 1_223_040_000 },
        .source = follower,
        .instance = 0,
        .value = 2,
    }, out[0]);
    try testing.expectEqual(@as(i64, 2091 * simulation.step.flicks), out[1].time.flicks);
    try testing.expectEqual(@as(f64, 5), out[1].value);
    state.eval(out[0].time);
    try testing.expectEqual(@as(f64, 2), state.value(follower));
}

// Locks a shift register's events: entering bucket n is at its boundary, pass * period +
// ceil(within * period / buckets) flicks after the start, an exact integer even where the period
// does not divide, and the value is the entered bucket's, which a stepped shape returns there.
// Bucket 0 at the start fires nothing.
test "a shift register fires at each bucket boundary, exactly" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    for ([_]i64{ flicks_per_second, flicks_per_second + 1 }) |period| {
        var nodes: [1]Node = undefined;
        var builder = Builder.init(&nodes, .{ .slab_count_max = 16, .cues = &cues });
        const shift = try builder.shift(.{
            .buckets = 3,
            .period = .{ .flicks = period },
            .low = -1,
            .high = 1,
            .odds = 0.5,
            .shape = .steps,
            .seed = 8,
        });
        var slab: [16]f64 = undefined;
        var state = State.init(builder.finish(), &slab);
        var out: [16]Event = undefined;
        const result = state.events(.{ .flicks = 0 }, .{ .flicks = 4 * flicks_per_second }, &out);
        try testing.expectEqual(Events{ .count = 11, .dropped = 0 }, result);
        for (out[0..result.count], 1..) |event, bucket| {
            const pass_index: i64 = @intCast(bucket / 3);
            const within: i64 = @intCast(bucket % 3);
            const within_flicks = std.math.divCeil(i64, within * period, 3) catch unreachable;
            const boundary = pass_index * period + within_flicks;
            try testing.expectEqual(boundary, event.time.flicks);
            state.eval(.{ .flicks = boundary + simulation.step.flicks });
            if (period == flicks_per_second) {
                state.eval(event.time);
                try testing.expectEqual(event.value, state.value(shift));
            }
        }
    }
}

// Locks the order of `event.zig` across sources: a follower arriving at 1,223,040,000 flicks and a
// cue at that flick come out by source index, whichever is built first, though the cue's event is
// found first.
test "events at one flick come out by source index" {
    var times: [2]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = 0 });
    const cue = try cues.add(.{ .flicks = 1_223_040_000 });
    var region_entries: [1]simulation.Region = undefined;
    var regions = simulation.Regions.init(&region_entries);
    const span = try regions.add(&.{.{ .low = 2, .high = 2 }});
    for ([_]bool{ true, false }) |follower_first| {
        var nodes: [2]Node = undefined;
        var builder = Builder.init(&nodes, .{
            .slab_count_max = 10,
            .cues = &cues,
            .regions = regions.table(),
        });
        var ids: [2]Id = undefined;
        for (0..2) |index| {
            const build_follower = (index == 0) == follower_first;
            ids[index] = if (build_follower) try builder.follow(.{
                .from = 0,
                .regions = span,
                .pick = .cycle,
                .mover = .{ .newtonian = .{ .speed = 4, .accel = 2, .decel = 4 } },
                .tolerance = 0,
                .pause_min = .{ .flicks = 2 * flicks_per_second },
                .pause_max = .{ .flicks = 2 * flicks_per_second },
                .seed = 0,
            }) else try builder.cues(.{ .first = cue, .count = 1 });
        }
        var slab: [10]f64 = undefined;
        var state = State.init(builder.finish(), &slab);
        var out: [4]Event = undefined;
        const result = state.events(.{ .flicks = 0 }, .{ .flicks = 2 * flicks_per_second }, &out);
        try testing.expectEqual(Events{ .count = 2, .dropped = 0 }, result);
        for (out[0..2], ids) |event, id| {
            try testing.expectEqual(@as(i64, 1_223_040_000), event.time.flicks);
            try testing.expectEqual(id, event.source);
        }
    }
}

// Locks a cue span's events and signal: cues at 1, 1, and 2 s fire in cue order, the first two at
// one flick, each with its index; the count is 2 from 1 s and 3 from 2 s; and a cue move moves its
// event and its count.
test "cues fire in cue order, and a move moves them" {
    var times: [4]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = 0 });
    const first = try cues.add(.{ .flicks = flicks_per_second });
    _ = try cues.add(.{ .flicks = flicks_per_second });
    const last = try cues.add(.{ .flicks = 2 * flicks_per_second });
    var nodes: [1]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 1, .cues = &cues });
    const span = try builder.cues(.{ .first = first, .count = 3 });
    var slab: [1]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    var out: [4]Event = undefined;
    const end: Time = .{ .flicks = 3 * flicks_per_second };
    const zero: Time = .{ .flicks = 0 };
    try testing.expectEqual(Events{ .count = 3, .dropped = 0 }, state.events(zero, end, &out));
    const expected = [_][2]i64{
        .{ flicks_per_second, 1 },
        .{ flicks_per_second, 2 },
        .{ 2 * flicks_per_second, 3 },
    };
    for (out[0..3], expected) |event, row| {
        try testing.expectEqual(row[0], event.time.flicks);
        try testing.expectEqual(@as(f64, @floatFromInt(row[1])), event.value);
    }
    const counts = [_][2]i64{
        .{ flicks_per_second - 1, 0 },
        .{ flicks_per_second, 2 },
        .{ 2 * flicks_per_second, 3 },
    };
    for (counts) |row| {
        state.eval(.{ .flicks = row[0] });
        try testing.expectEqual(@as(f64, @floatFromInt(row[1])), state.value(span));
    }
    try cues.move(last, .{ .flicks = 2 * flicks_per_second + 5 });
    try testing.expectEqual(Events{ .count = 3, .dropped = 0 }, state.events(zero, end, &out));
    try testing.expectEqual(2 * flicks_per_second + 5, out[2].time.flicks);
    state.eval(.{ .flicks = 2 * flicks_per_second });
    try testing.expectEqual(@as(f64, 2), state.value(span));
}

// Locks each refusal of `bounce`, `crossing`, and `cues` by name, that nothing refused was built,
// and that a bounce is built whole or not at all.
test "the builder refuses an event source it cannot evaluate" {
    var empty = Builder.init(&.{}, .{ .slab_count_max = 0 });
    const constant_source: Crossing = .{ .input = .{ .index = 0 }, .level = 0, .direction = .both };
    try testing.expectError(error.UnknownNode, empty.crossing(constant_source));

    var fixture: Fixture = undefined;
    try fixture.init();
    var nodes: [2]Node = undefined;
    var builder = fixture.builder(&nodes);
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    var bounce: Bounce = .{ .low = 0, .high = 1, .speed = 1, .start = .{ .index = 0 } };
    for ([_][3]f64{ .{ nan, 1, 1 }, .{ 0, inf, 1 }, .{ 0, 1, nan } }) |row| {
        bounce.low = row[0];
        bounce.high = row[1];
        bounce.speed = row[2];
        try testing.expectError(error.NotFinite, builder.bounce(bounce));
    }
    bounce = .{ .low = 1, .high = 1, .speed = 1, .start = .{ .index = 0 } };
    try testing.expectError(error.InvalidRange, builder.bounce(bounce));
    bounce.high = 0;
    try testing.expectError(error.InvalidRange, builder.bounce(bounce));
    bounce.high = 2;
    for ([_]f64{ 0, -1 }) |speed| {
        bounce.speed = speed;
        try testing.expectError(error.InvalidLimit, builder.bounce(bounce));
    }
    bounce.speed = 1;
    bounce.start = .{ .index = 1 };
    try testing.expectError(error.UnknownCue, builder.bounce(bounce));
    bounce.start = .{ .index = 0 };
    // A leg under a flick, and one of 2^53 flicks or more.
    for ([_]f64{ 2 * flicks_per_second_float, 1e-9 }) |speed| {
        bounce.speed = speed;
        try testing.expectError(error.InvalidDuration, builder.bounce(bounce));
    }
    bounce.low = -std.math.floatMax(f64);
    bounce.high = std.math.floatMax(f64);
    bounce.speed = 1;
    try testing.expectError(error.InvalidDuration, builder.bounce(bounce));
    bounce = .{ .low = 0, .high = 1, .speed = flicks_per_second_float, .start = .{ .index = 0 } };
    try testing.expectEqual(@as(u32, 0), builder.node_count);

    const input = try builder.constant(1);
    try testing.expectError(error.NodeCapacityExceeded, builder.bounce(bounce));
    try testing.expectEqual(@as(u32, 1), builder.node_count);
    var crossing: Crossing = .{ .input = .{ .index = 1 }, .level = 0, .direction = .rising };
    try testing.expectError(error.UnknownNode, builder.crossing(crossing));
    crossing.input = input;
    crossing.level = nan;
    try testing.expectError(error.NotFinite, builder.crossing(crossing));
    const spans = [_]CueSpan{
        .{ .first = .{ .index = 0 }, .count = 0 },
        .{ .first = .{ .index = 0 }, .count = 2 },
        .{ .first = .{ .index = 1 }, .count = 1 },
    };
    for (spans) |span| try testing.expectError(error.UnknownCue, builder.cues(span));
    try testing.expectEqual(@as(u32, 1), builder.node_count);
    crossing.level = 0;
    _ = try builder.crossing(crossing);

    var slab_small = Builder.init(&nodes, .{ .slab_count_max = 1, .cues = &fixture.cues });
    try testing.expectError(error.SlabCapacityExceeded, slab_small.bounce(bounce));
    try testing.expectEqual(@as(u32, 0), slab_small.node_count);
    var no_start = Builder.init(&nodes, .{ .slab_count_max = 4 });
    const lonely = try no_start.constant(0);
    crossing.input = lonely;
    try testing.expectError(error.UnknownCue, no_start.crossing(crossing));
    var room = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = &fixture.cues });
    const ids = try room.bounce(bounce);
    try testing.expectEqual(@as(u32, 1), ids.velocity.index);
}
