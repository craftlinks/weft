//! Tests of the graph: tracks and live parameters.
//!
//! They read `graph.zig` and `state.zig` as a client would, plus the few internals that
//! `graph.zig` marks public for its reader and its tests.

const std = @import("std");
const Cues = @import("../cue.zig").Cues;
const motion = @import("../motion.zig");
const range_module = @import("../range.zig");
const Range = range_module.Range;
const recording_module = @import("../recording.zig");
const Sample = recording_module.Sample;
const simulation = @import("../simulation.zig");
const time_module = @import("../time.zig");
const Time = time_module.Time;
const track_module = @import("../track.zig");
const Tracks = track_module.Tracks;
const TrackId = track_module.TrackId;
const wave_module = @import("../wave.zig");
const Wave = wave_module.Wave;
const graph_module = @import("../graph.zig");
const state_module = @import("../state.zig");
const testing = std.testing;
const Rate = @import("../time.zig").Rate;
const flicks_per_second = @import("../time.zig").flicks_per_second;
const State = graph_module.State;
const ranges_of = @import("ranges.zig").ranges_of;
const cue_table_at_zero = @import("events.zig").cue_table_at_zero;
const Builder = graph_module.Builder;
const Chase = graph_module.Chase;
const Follow = graph_module.Follow;
const Id = graph_module.Id;
const Node = graph_module.Node;
const Oscillator = graph_module.Oscillator;
const Program = graph_module.Program;
const step_time = state_module.step_time;

/// A page of live parameters (step 9.5): an oscillator, a chase, and two followers whose rates,
/// times, overshoots, and limits come from tracks, as Play's knobs drive them.
const Live = struct {
    cue_times: [1]Time,
    cues: Cues,
    region_entries: [1]simulation.Region,
    regions: simulation.Regions,
    track_entries: [4]track_module.Track,
    track_samples: [4][2048]Sample,
    tracks: Tracks,
    ids: [4]TrackId,
    nodes: [12]Node,
    program: Program,
    outputs: [4]Id,

    const slab_count_max = 96;

    fn init(live: *Live) !void {
        live.cues = try cue_table_at_zero(&live.cue_times);
        live.regions = simulation.Regions.init(&live.region_entries);
        _ = try live.regions.add(&.{.{ .low = 0, .high = 1 }});
        live.tracks = Tracks.init(&live.track_entries);
        const bounds = [4][3]f64{
            .{ 0.1, 3, 0.5 },
            .{ 0.125, 2, 0.5 },
            .{ 0, 0.9, 0.3 },
            .{ 0.25, 4, 1 },
        };
        for (&live.ids, &live.track_samples, bounds) |*id, *samples, bound| {
            id.* = try live.tracks.add(samples, bound[0], bound[1], bound[2]);
        }
        var builder = Builder.init(&live.nodes, .{
            .slab_count_max = slab_count_max,
            .cues = &live.cues,
            .regions = live.regions.table(),
            .tracks = &live.tracks,
            .seed = 9,
        });
        const rate = try builder.track(live.ids[0]);
        const oscillator = try builder.oscillator(.{ .shape = .sine, .rate = rate });
        const time = try builder.track(live.ids[1]);
        const chase = try builder.chase(.{
            .target = oscillator,
            .from = 0,
            .time = .{ .flicks = @divExact(flicks_per_second, 2) },
            .overshoot = 0.1,
            .time_from = time,
        });
        const overshoot = try builder.track(live.ids[2]);
        const sway = try builder.follow(.{
            .from = 0.5,
            .regions = .{ .first = 0, .count = 1 },
            .pick = .random,
            .mover = .{ .spring = .{ .time = .{ .flicks = flicks_per_second }, .overshoot = 0.3 } },
            .tolerance = 0.01,
            .pause_min = .{ .flicks = 0 },
            .pause_max = .{ .flicks = flicks_per_second },
            .seed = 4,
            .mover_from = .{ .overshoot = overshoot },
        });
        const speed = try builder.track(live.ids[3]);
        const four = try builder.constant(4);
        const limit = try builder.multiply(speed, four);
        const glide = try builder.follow(.{
            .from = 0.5,
            .regions = .{ .first = 0, .count = 1 },
            .pick = .random,
            .mover = .{ .newtonian = .{ .speed = 1, .accel = 4, .decel = 4 } },
            .tolerance = 0.01,
            .pause_min = .{ .flicks = 0 },
            .pause_max = .{ .flicks = @divExact(flicks_per_second, 2) },
            .seed = 9,
            .mover_from = .{ .speed = speed, .accel = limit, .decel = limit },
        });
        live.outputs = .{ oscillator, chase, sway, glide };
        live.program = builder.finish();
    }

    fn values(live: *const Live, state: *const State) [4]f64 {
        var result: [4]f64 = undefined;
        for (&result, live.outputs) |*value, id| value.* = state.value(id);
        return result;
    }

    /// A fresh state's values at `time`, with no checkpoints, so from the start.
    fn fresh(live: *const Live, time: Time) [4]f64 {
        var slab: [slab_count_max]f64 = undefined;
        var state = State.init(live.program, slab[0..live.program.slab_count]);
        state.eval(time);
        return live.values(&state);
    }
};

fn whole_seconds(count: i64) Time {
    return .{ .flicks = count * flicks_per_second };
}

/// Static, since a page and its checkpoints are too large for the test's stack.
const live_fixture = struct {
    var live: Live = undefined;
    var slab: [Live.slab_count_max]f64 = undefined;
    var checkpoints: [70 * Live.slab_count_max]f64 = undefined;
};

// Locks section 14's floor: a reader played to 60 s, then writes at 30 s, keeps the 30
// checkpoints before 30 s, and its reads at 10, 30, 45, and 60 s equal a fresh state's, bit for
// bit; the read at 10 s runs at most one interval of steps, from a kept checkpoint.
test "a track write keeps the past and drops only what it reaches" {
    const live = &live_fixture.live;
    try live.init();
    const used = live.program.slab_count;
    var state = State.init_with_checkpoints(
        live.program,
        live_fixture.slab[0..used],
        live_fixture.checkpoints[0 .. 70 * @as(usize, used)],
    );
    const rate = Rate.from_hz(60).?;
    for (0..3601) |frame| state.eval(Time.from_ticks(@intCast(frame), rate).?);
    try testing.expectEqual(@as(u32, 60), state.checkpoints_filled);
    try live.tracks.write(live.ids[0], whole_seconds(30), 2);
    try live.tracks.write(live.ids[2], whole_seconds(30), 0.8);
    try live.tracks.write(live.ids[3], whole_seconds(30), 0.5);
    const before = state.steps_run;
    state.eval(whole_seconds(10));
    try testing.expectEqual(@as(u32, 30), state.checkpoints_filled);
    try testing.expect(state.steps_run - before <= simulation.checkpoint_interval);
    try testing.expectEqualSlices(f64, &live.fresh(whole_seconds(10)), &live.values(&state));
    for ([_]i64{ 30, 45, 60, 10 }) |at| {
        state.eval(whole_seconds(at));
        try testing.expectEqualSlices(f64, &live.fresh(whole_seconds(at)), &live.values(&state));
    }
}

// Locks the cost of a knob: playing at 60 Hz for 30 s with a write of every track at the playhead
// each frame, no frame runs more than its own steps and one interval, and the values are a fresh
// state's at the end, bit for bit.
test "a write at the playhead costs at most one interval" {
    const live = &live_fixture.live;
    try live.init();
    const used = live.program.slab_count;
    var state = State.init_with_checkpoints(
        live.program,
        live_fixture.slab[0..used],
        live_fixture.checkpoints[0 .. 70 * @as(usize, used)],
    );
    const rate = Rate.from_hz(60).?;
    var most: u64 = 0;
    for (0..1801) |frame| {
        const time = Time.from_ticks(@intCast(frame), rate).?;
        const swing: f64 = @floatFromInt(frame % 7);
        for (live.ids, 0..) |id, index| {
            const track = live.tracks.at(id);
            const share = (swing + @as(f64, @floatFromInt(index))) / 10;
            try live.tracks.write(id, time, track.low + (track.high - track.low) * share);
        }
        const before = state.steps_run;
        state.eval(time);
        most = @max(most, state.steps_run - before);
    }
    try testing.expect(most <= 8 + simulation.checkpoint_interval);
    try testing.expectEqualSlices(f64, &live.fresh(whole_seconds(30)), &live.values(&state));
}

// Locks parameters from nodes against constants: a chase, a spring follower, and a Newtonian
// follower whose parameters come from constant nodes equal the same nodes with constant
// parameters, at 60 Hz for 60 s, bit for bit.
test "parameters from constant nodes equal constant parameters" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var region_entries: [1]simulation.Region = undefined;
    var regions = simulation.Regions.init(&region_entries);
    _ = try regions.add(&.{.{ .low = -1, .high = 1 }});
    var nodes: [16]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 128,
        .cues = &cues,
        .regions = regions.table(),
        .seed = 3,
    });
    const target = try builder.wave(.{ .shape = .triangle, .hz = 0.7 });
    const time: Time = .{ .flicks = 282_240_000 };
    const seconds = try builder.constant(0.4);
    const overshoot = try builder.constant(0.15);
    const chase: Chase = .{ .target = target, .from = 0, .time = time, .overshoot = 0.15 };
    var chase_from = chase;
    chase_from.time_from = seconds;
    chase_from.overshoot_from = overshoot;
    const spring: Follow = .{
        .from = 0,
        .regions = .{ .first = 0, .count = 1 },
        .pick = .random,
        .mover = .{ .spring = .{ .time = time, .overshoot = 0.15 } },
        .tolerance = 0.02,
        .pause_min = .{ .flicks = 0 },
        .pause_max = .{ .flicks = 282_240_000 },
        .seed = 5,
    };
    var spring_from = spring;
    spring_from.mover_from = .{ .time = seconds, .overshoot = overshoot };
    var newtonian = spring;
    newtonian.mover = .{ .newtonian = .{ .speed = 1.5, .accel = 6, .decel = 4 } };
    var newtonian_from = newtonian;
    newtonian_from.mover_from = .{
        .speed = try builder.constant(1.5),
        .accel = try builder.constant(6),
        .decel = try builder.constant(4),
    };
    const pairs = [3][2]Id{
        .{ try builder.chase(chase), try builder.chase(chase_from) },
        .{ try builder.follow(spring), try builder.follow(spring_from) },
        .{ try builder.follow(newtonian), try builder.follow(newtonian_from) },
    };
    const program = builder.finish();
    var slab: [128]f64 = undefined;
    var state = State.init(program, slab[0..program.slab_count]);
    const rate = Rate.from_hz(60).?;
    for (0..3601) |frame| {
        state.eval(Time.from_ticks(@intCast(frame), rate).?);
        for (pairs) |pair| {
            const constant: u64 = @bitCast(state.value(pair[0]));
            try testing.expectEqual(constant, @as(u64, @bitCast(state.value(pair[1]))));
        }
    }
}

// Locks the oscillator: at a constant rate it is the wave at that rate, at every step for 10 s,
// within the rounding of its summed phase.
test "an oscillator at a constant rate is the wave" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var nodes: [3]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 16, .cues = &cues });
    const rate = try builder.constant(1.25);
    const oscillator = try builder.oscillator(.{ .shape = .sine, .rate = rate });
    const program = builder.finish();
    var slab: [16]f64 = undefined;
    var state = State.init(program, slab[0..program.slab_count]);
    const wave: Wave = .{ .shape = .sine, .hz = 1.25 };
    for (0..4801) |step| {
        const time = step_time(.{ .flicks = 0 }, step);
        state.eval(time);
        try testing.expectApproxEqAbs(wave.sample(time), state.value(oscillator), 1e-9);
    }
    var out: [3]Range = undefined;
    const range = ranges_of(&program, &out)[oscillator.index];
    try testing.expect(range.low <= -1 and range.high >= 1);
}

// Locks the refusals of step 9.5, by name.
test "the builder refuses live parameters it cannot use" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var region_entries: [1]simulation.Region = undefined;
    var regions = simulation.Regions.init(&region_entries);
    _ = try regions.add(&.{.{ .low = 0, .high = 1 }});
    var nodes: [4]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 64,
        .cues = &cues,
        .regions = regions.table(),
    });
    const one = try builder.constant(1);
    try testing.expectError(error.UnknownTrack, builder.track(.{ .index = 0 }));
    const late: Oscillator = .{ .shape = .sine, .rate = one, .phase = 1 };
    try testing.expectError(error.InvalidPhase, builder.oscillator(late));
    const unknown: Oscillator = .{ .shape = .sine, .rate = .{ .index = 5 } };
    try testing.expectError(error.UnknownNode, builder.oscillator(unknown));
    var follow: Follow = .{
        .from = 0,
        .regions = .{ .first = 0, .count = 1 },
        .pick = .cycle,
        .mover = .{ .spring = .{ .time = .{ .flicks = flicks_per_second }, .overshoot = 0 } },
        .tolerance = 0.01,
        .pause_min = .{ .flicks = 0 },
        .pause_max = .{ .flicks = 0 },
        .seed = 1,
        .mover_from = .{ .speed = one },
    };
    try testing.expectError(error.InvalidParameter, builder.follow(follow));
    follow.mover = .{ .newtonian = .{ .speed = 1, .accel = 1, .decel = 1 } };
    follow.mover_from = .{ .time = one };
    try testing.expectError(error.InvalidParameter, builder.follow(follow));
    follow.mover_from = .{ .decel = .{ .index = 7 } };
    try testing.expectError(error.UnknownNode, builder.follow(follow));
    try testing.expectEqual(@as(u32, 1), builder.node_count);
}
