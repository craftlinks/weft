//! Tests of the graph: simulated nodes, checkpoints, and delays.
//!
//! They read `graph.zig` and `state.zig` as a client would, plus the few internals that
//! `graph.zig` marks public for its reader and its tests.

const std = @import("std");
const assert = std.debug.assert;
const Cue = @import("../cue.zig").Cue;
const Cues = @import("../cue.zig").Cues;
const motion = @import("../motion.zig");
const simulation = @import("../simulation.zig");
const time_module = @import("../time.zig");
const Time = time_module.Time;
const graph_module = @import("../graph.zig");
const testing = std.testing;
const Rate = @import("../time.zig").Rate;
const flicks_per_second = @import("../time.zig").flicks_per_second;
const State = graph_module.State;
const tween_of = @import("tween.zig").tween_of;
const Builder = graph_module.Builder;
const Chase = graph_module.Chase;
const Follow = graph_module.Follow;
const Id = graph_module.Id;
const Node = graph_module.Node;
const Program = graph_module.Program;
const Shift = graph_module.Shift;
const Tween = graph_module.Tween;
const step_flicks = graph_module.step_flicks;

/// A start cue half a step after 0.5 s, so a reader at a rate that divides 480 Hz lands halfway
/// between steps or on one, and a cue at 2 s. Two regions, and a graph of every simulated node: a
/// chase of a tween that rises at the second cue, a follower, a shift register, and a chase of
/// 1 - 0.8 times its own delay.
const Scene = struct {
    times: [2]Time,
    cues: Cues,
    region_entries: [2]simulation.Region,
    regions: simulation.Regions,
    nodes: [10]Node,
    outputs: [4]Id,
    program: Program,

    const slab_count = 37;

    fn init(scene: *Scene) !void {
        scene.cues = Cues.init(&scene.times);
        const start = try scene.cues.add(.{
            .flicks = flicks_per_second / 2 + simulation.step.flicks / 2,
        });
        const rise = try scene.cues.add(.{ .flicks = 2 * flicks_per_second });
        scene.regions = simulation.Regions.init(&scene.region_entries);
        const span = try scene.regions.add(&.{
            .{ .low = -1, .high = -0.5 },
            .{ .low = 0.5, .high = 1 },
        });
        var builder = Builder.init(&scene.nodes, .{
            .slab_count_max = slab_count,
            .cues = &scene.cues,
            .regions = scene.regions.table(),
            .start = start,
            .seed = 21,
        });
        const target = try builder.tween(tween_of(0, 1, rise, .in_out));
        scene.outputs[0] = try builder.chase(.{
            .target = target,
            .from = 0.5,
            .time = .{ .flicks = flicks_per_second * 2 / 5 },
            .overshoot = 0.1,
        });
        scene.outputs[1] = try builder.follow(.{
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
        });
        scene.outputs[2] = try builder.shift(.{
            .buckets = 8,
            .period = .{ .flicks = 2 * flicks_per_second },
            .low = -1,
            .high = 1,
            .odds = 0.5,
            .shape = .smooth,
            .seed = 4,
        });
        scene.outputs[3] = try build_feedback(&builder);
        scene.program = builder.finish();
        assert(scene.program.slab_count == slab_count);
    }

    /// Moves both cues by `shift`, the one ahead first, so neither passes the other.
    fn shift_cues(scene: *Scene, shift: i64) !void {
        const order = if (shift > 0) [2]u32{ 1, 0 } else [2]u32{ 0, 1 };
        for (order) |index| {
            const cue: Cue = .{ .index = index };
            try scene.cues.move(cue, .{ .flicks = scene.cues.at(cue).flicks + shift });
        }
    }

    fn read(scene: *const Scene, state: *State, time: Time) [4]f64 {
        assert(state.program.nodes.ptr == scene.program.nodes.ptr);
        state.eval(time);
        var result: [4]f64 = undefined;
        for (&result, scene.outputs) |*value, id| value.* = state.value(id);
        return result;
    }
};

/// A chase of 1 - 0.8 times its own delay, which settles where x = 1 - 0.8 x, at 1 / 1.8.
fn build_feedback(builder: *Builder) Builder.Error!Id {
    const echo = try builder.delay(0);
    const gain = try builder.constant(-0.8);
    const scaled = try builder.multiply(echo, gain);
    const one = try builder.constant(1);
    const target = try builder.add(one, scaled);
    const result = try builder.chase(.{
        .target = target,
        .from = 0,
        .time = .{ .flicks = flicks_per_second / 2 },
        .overshoot = 0.2,
    });
    try builder.close(echo, result);
    return result;
}

// Locks the page's first check: 10 s of every simulated node at 60 Hz, read forwards, backwards,
// in a scattered order with and without checkpoints, and from fresh readers, give the same bits.
// The feedback chase settles on 1 / 1.8 within 1e-9 by 10 s.
test "forward play and any seek give the same values" {
    var scene: Scene = undefined;
    try scene.init();
    const rate = Rate.from_hz(60).?;
    const frames_count = 600;
    var slab: [Scene.slab_count]f64 = undefined;
    var checkpoints: [12 * Scene.slab_count]f64 = undefined;
    var state = State.init_with_checkpoints(scene.program, &slab, &checkpoints);
    var forward: [frames_count][4]f64 = undefined;
    for (&forward, 0..) |*values, frame| {
        values.* = scene.read(&state, Time.from_ticks(@intCast(frame), rate).?);
    }
    try testing.expectEqual(@as(u32, 9), state.checkpoints_filled);

    var frame: usize = frames_count;
    while (frame > 0) {
        frame -= 1;
        const values = scene.read(&state, Time.from_ticks(@intCast(frame), rate).?);
        try testing.expectEqual(forward[frame], values);
    }
    var slab_plain: [Scene.slab_count]f64 = undefined;
    var plain = State.init(scene.program, &slab_plain);
    var hop: usize = 0;
    for (0..frames_count) |index| {
        hop = (hop + 389) % frames_count;
        const time = Time.from_ticks(@intCast(hop), rate).?;
        try testing.expectEqual(forward[hop], scene.read(&state, time));
        if (index % 5 != 0) continue;
        try testing.expectEqual(forward[hop], scene.read(&plain, time));
        var slab_fresh: [Scene.slab_count]f64 = undefined;
        var fresh = State.init(scene.program, &slab_fresh);
        try testing.expectEqual(forward[hop], scene.read(&fresh, time));
    }
    try testing.expectApproxEqAbs(@as(f64, 1.0 / 1.8), forward[frames_count - 1][3], 1e-9);
}

// Locks the page's second check: readers at 24, 60, 240, and 960 Hz through 5 s give the same
// bits at every instant they share, every 1/12 s, each halfway between two steps. Readers at 25,
// 144, and 44,100 Hz, which 480 does not divide, give the same bits at each whole second.
test "simulated signals ignore the reader's rate" {
    var scene: Scene = undefined;
    try scene.init();
    const rates_hz = [_]u32{ 24, 60, 240, 960 };
    var shared: [rates_hz.len][61][4]f64 = undefined;
    for (rates_hz, &shared) |hz, *values| read_shared(&scene, hz, 12, values);
    for (shared[1..]) |values| try testing.expectEqual(shared[0], values);

    const rates_odd_hz = [_]u32{ 25, 144, 44_100, 960 };
    var seconds: [rates_odd_hz.len][6][4]f64 = undefined;
    for (rates_odd_hz, &seconds) |hz, *values| read_shared(&scene, hz, 1, values);
    for (seconds[1..]) |values| try testing.expectEqual(seconds[0], values);
}

/// Plays `scene` from time zero at `hz`, keeping the values at each of `values.len` instants
/// `shared_hz` apart.
fn read_shared(scene: *const Scene, hz: u32, shared_hz: u32, values: [][4]f64) void {
    assert(hz % shared_hz == 0);
    var slab: [Scene.slab_count]f64 = undefined;
    var state = State.init(scene.program, &slab);
    const per_shared = hz / shared_hz;
    for (0..values.len * per_shared - per_shared + 1) |frame| {
        const read = scene.read(&state, Time.from_ticks(@intCast(frame), Rate.from_hz(hz).?).?);
        if (frame % per_shared == 0) values[frame / per_shared] = read;
    }
}

// Locks the bound of section 11 for the page's third check. Without checkpoints, a read at 10 s
// runs all 4,800 steps, and a read back at 9.99 s runs them again. With room for ten, one read at
// 10.5 s fills them all, and from then on no read anywhere in 10.5 s runs more than 479 steps.
test "after a pre-roll no seek runs more than one interval of steps" {
    var scene: Scene = undefined;
    try scene.init();
    const start = scene.cues.at(scene.program.start).flicks;
    var slab_plain: [Scene.slab_count]f64 = undefined;
    var plain = State.init(scene.program, &slab_plain);
    _ = scene.read(&plain, .{ .flicks = start + 10 * flicks_per_second - 1 });
    try testing.expectEqual(@as(u64, 4800), plain.steps_run);
    _ = scene.read(&plain, .{ .flicks = start + 999 * flicks_per_second / 100 });
    try testing.expectEqual(@as(u64, 4800 + 4796), plain.steps_run);

    var slab: [Scene.slab_count]f64 = undefined;
    var checkpoints: [10 * Scene.slab_count]f64 = undefined;
    var state = State.init_with_checkpoints(scene.program, &slab, &checkpoints);
    try testing.expectEqual(@as(u32, 10), state.checkpoints_count());
    _ = scene.read(&state, .{ .flicks = start + 21 * flicks_per_second / 2 });
    try testing.expectEqual(@as(u32, 10), state.checkpoints_filled);
    var steps_max: u64 = 0;
    var hop: i64 = 0;
    for (0..2000) |_| {
        hop = @mod(hop + 3_708_281_731, 21 * flicks_per_second / 2);
        const steps_before = state.steps_run;
        _ = scene.read(&state, .{ .flicks = start + hop });
        steps_max = @max(steps_max, state.steps_run - steps_before);
    }
    try testing.expectEqual(simulation.checkpoint_interval - 1, steps_max);
}

// Locks section 10 on the smallest cycle: a delay fed by itself plus one counts steps. It is 0
// before the start, 480 at 1 s, 1.5 halfway through the second step, and the sum is one more.
test "a delay closes a cycle and gives the step before" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = 0 });
    var nodes: [3]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 5, .cues = &cues });
    const count = try builder.delay(0);
    const one = try builder.constant(1);
    const sum = try builder.add(count, one);
    try builder.close(count, sum);
    var slab: [5]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    const rows = [_]struct { flicks: i64, count: f64 }{
        .{ .flicks = -1, .count = 0 },
        .{ .flicks = 0, .count = 0 },
        .{ .flicks = 3 * simulation.step.flicks / 2, .count = 1.5 },
        .{ .flicks = flicks_per_second, .count = 480 },
        .{ .flicks = 3 * simulation.step.flicks, .count = 3 },
    };
    for (rows) |row| {
        state.eval(.{ .flicks = row.flicks });
        try testing.expectEqual(row.count, state.value(count));
        try testing.expectEqual(row.count + 1, state.value(sum));
    }
}

/// A program of one chase from 0 of the tween `target_source`.
fn chase_alone(
    nodes: []Node,
    cues: *const Cues,
    law_time: Time,
    overshoot: f64,
    target_source: Tween,
) !struct { program: Program, chase: Id } {
    var builder = Builder.init(nodes, .{ .slab_count_max = 5, .cues = cues });
    const target = try builder.tween(target_source);
    const chase = try builder.chase(.{
        .target = target,
        .from = 0,
        .time = law_time,
        .overshoot = overshoot,
    });
    return .{ .program = builder.finish(), .chase = chase };
}

// Locks step 5's deferred spring with a moving target on two worked cases. Chasing a constant 1
// (a tween that is already there) from 0, it is step 5's spring folded at every step: within
// 1e-12 at every step of 2 s, for omega 8 critical and for overshoot 0.163. Chasing a ramp of
// 1 per second, a critical spring of period 0.5 s lags 2 / omega + step / 2 = 0.160197 s at 10 s.
test "a chase follows a moving target" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 0 });
    var nodes: [2]Node = undefined;
    var slab: [5]f64 = undefined;
    const omega_8: Time = .{ .flicks = 554_176_944 };
    for ([_]f64{ 0, 0.163 }) |overshoot| {
        var constant_source = tween_of(1, 1, cue, .linear);
        constant_source.duration = .{ .flicks = 1 };
        const built = try chase_alone(&nodes, &cues, omega_8, overshoot, constant_source);
        var state = State.init(built.program, &slab);
        const law: motion.Law = .{ .spring = motion.SpringLaw.of(omega_8, overshoot) };
        for (0..961) |index| {
            state.eval(.{ .flicks = @as(i64, @intCast(index)) * simulation.step.flicks });
            const seconds = @as(f64, @floatFromInt(index)) / 480;
            const whole = motion.advance(law, .{ .position = 0, .velocity = 0 }, 1, seconds);
            try testing.expectApproxEqAbs(whole.position, state.value(built.chase), 1e-12);
        }
    }
    var ramp = tween_of(0, 100, cue, .linear);
    ramp.duration = .{ .flicks = 100 * flicks_per_second };
    const half_second: Time = .{ .flicks = flicks_per_second / 2 };
    const built = try chase_alone(&nodes, &cues, half_second, 0, ramp);
    var state = State.init(built.program, &slab);
    state.eval(.{ .flicks = 10 * flicks_per_second });
    const lag_expected: f64 = 2.0 / (std.math.tau / 0.5) + simulation.step_seconds / 2.0;
    try testing.expectApproxEqAbs(lag_expected, 10 - state.value(built.chase), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.160197), lag_expected, 5e-7);
}

// Locks a follower's timeline with a Newtonian mover (speed 4, accel 2, decel 4), regions fixed
// at 2 and 5 in turn, and a pause of exactly 0.5 s. From 0 to 2 takes sqrt 3 s, so it lands at
// step 832, the first step after 831.38; holds 2 for 240 steps; leaves at step 1073; takes
// 2.1213 s to 5, landing at step 2091; and holds 5 until step 2331.
test "a follower lands, pauses, and moves on" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = 0 });
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
    const rows = [_]struct { step: i64, low: f64, high: f64 }{
        .{ .step = 1, .low = 0, .high = 0.001 },
        .{ .step = 831, .low = 1.999, .high = 2 - 1e-9 },
        .{ .step = 832, .low = 2, .high = 2 },
        .{ .step = 1072, .low = 2, .high = 2 },
        .{ .step = 1073, .low = 2 + 1e-9, .high = 2.001 },
        .{ .step = 2090, .low = 4.999, .high = 5 - 1e-9 },
        .{ .step = 2091, .low = 5, .high = 5 },
        .{ .step = 2331, .low = 5, .high = 5 },
        .{ .step = 2332, .low = 4.999, .high = 5 - 1e-9 },
    };
    for (rows) |row| {
        state.eval(.{ .flicks = row.step * simulation.step.flicks });
        const value = state.value(follower);
        try testing.expect(value >= row.low);
        try testing.expect(value <= row.high);
    }
}

// Locks that a cue move reaches a simulated reader: after moving the chase's target cue, a reader
// that has played past it gives what a fresh reader gives, which differs for the chase and not
// for the follower. Moving both cues by any amount, a flick or a day, shifts every simulated
// node by exactly that time.
test "moving a cue reaches a simulation" {
    var scene: Scene = undefined;
    try scene.init();
    var slab: [Scene.slab_count]f64 = undefined;
    var checkpoints: [4 * Scene.slab_count]f64 = undefined;
    var state = State.init_with_checkpoints(scene.program, &slab, &checkpoints);
    const time: Time = .{ .flicks = 3 * flicks_per_second };
    const before = scene.read(&state, time);
    try scene.cues.move(.{ .index = 1 }, .{ .flicks = 2 * flicks_per_second + 12_345_678 });
    const after = scene.read(&state, time);
    var slab_fresh: [Scene.slab_count]f64 = undefined;
    var fresh = State.init(scene.program, &slab_fresh);
    try testing.expectEqual(scene.read(&fresh, time), after);
    try testing.expect(before[0] != after[0]);
    try testing.expectEqual(before[1], after[1]);

    var expected: [64][4]f64 = undefined;
    for (&expected, 0..) |*values, index| {
        values.* = scene.read(&state, .{ .flicks = @as(i64, @intCast(index)) * 23_456_789 });
    }
    for ([_]i64{ 1, -7_777_777, 86_400 * flicks_per_second }) |shift| {
        try scene.shift_cues(shift);
        for (expected, 0..) |values, index| {
            const flicks = @as(i64, @intCast(index)) * 23_456_789 + shift;
            try testing.expectEqual(values, scene.read(&state, .{ .flicks = flicks }));
        }
        try scene.shift_cues(-shift);
    }
}

// Locks the layout of section 9 over 3 lanes: after a constant at 0, a chase at 3 keeps 3 lanes
// of before, after, and velocity, so a delay after it starts at 15, and the delay's 3 lanes of
// before and after end the slab at 24. Each chase lane follows its own lane of the target, a
// lane index, and the delay holds its initial value in all three at the start.
test "a simulated node keeps its state after its output" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = 0 });
    var nodes: [3]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 30, .cues = &cues });
    builder.lanes = 3;
    const index = try builder.lane();
    const chase = try builder.chase(.{
        .target = index,
        .from = 0,
        .time = .{ .flicks = flicks_per_second },
        .overshoot = 0,
    });
    const echo = try builder.delay(-1);
    try builder.close(echo, chase);
    const program = builder.finish();
    try testing.expect(program.simulated);
    try testing.expectEqual(@as(u32, 15), program.nodes[echo.index].offset);
    try testing.expectEqual(@as(u32, 24), program.slab_count);
    var slab: [24]f64 = undefined;
    var state = State.init(program, &slab);
    state.eval(.{ .flicks = flicks_per_second });
    const values = state.values(chase);
    try testing.expectEqual(@as(f64, 0), values[0]);
    try testing.expect(values[1] > 0.95 and values[1] < 1);
    try testing.expect(values[2] > 1.9 and values[2] < 2);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqualSlices(f64, &@as([3]f64, @splat(-1)), state.values(echo));

    var nodes_pure: [1]Node = undefined;
    var builder_pure = Builder.init(&nodes_pure, .{ .slab_count_max = 1 });
    _ = try builder_pure.constant(1);
    try testing.expect(!builder_pure.finish().simulated);
}

/// One cue at 0 and one region, [0, 1], for the refusals of the simulated ops.
pub const Fixture = struct {
    times: [1]Time,
    cues: Cues,
    region_entries: [1]simulation.Region,
    regions: simulation.Regions,
    span: simulation.Span,

    pub fn init(fixture: *Fixture) !void {
        fixture.cues = Cues.init(&fixture.times);
        _ = try fixture.cues.add(.{ .flicks = 0 });
        fixture.regions = simulation.Regions.init(&fixture.region_entries);
        fixture.span = try fixture.regions.add(&.{.{ .low = 0, .high = 1 }});
    }

    pub fn builder(fixture: *const Fixture, nodes: []Node) Builder {
        return Builder.init(nodes, .{
            .slab_count_max = 64,
            .cues = &fixture.cues,
            .regions = fixture.regions.table(),
        });
    }
};

// Locks each refusal of `chase`, `delay`, and `close` by name, that nothing refused was built,
// and that a delay can be closed on itself. A simulated node needs a start cue to exist.
test "the builder refuses a chase or a delay it cannot evaluate" {
    var nodes: [4]Node = undefined;
    var empty = Builder.init(&nodes, .{ .slab_count_max = 64 });
    try testing.expectError(error.UnknownCue, empty.delay(0));

    var fixture: Fixture = undefined;
    try fixture.init();
    var builder = fixture.builder(&nodes);
    const second: Time = .{ .flicks = flicks_per_second };
    const nan = std.math.nan(f64);
    var chase: Chase = .{ .target = .{ .index = 0 }, .from = 0, .time = second, .overshoot = 0 };
    try testing.expectError(error.UnknownNode, builder.chase(chase));
    const target = try builder.constant(1);
    chase.target = target;
    chase.from = nan;
    try testing.expectError(error.NotFinite, builder.chase(chase));
    chase.from = 0;
    chase.time = .{ .flicks = 0 };
    try testing.expectError(error.InvalidDuration, builder.chase(chase));
    chase.time = second;
    chase.overshoot = 1;
    try testing.expectError(error.InvalidOvershoot, builder.chase(chase));
    try testing.expectError(error.NotFinite, builder.delay(nan));
    try testing.expectEqual(@as(u32, 1), builder.node_count);

    const echo = try builder.delay(0);
    try testing.expectError(error.NotADelay, builder.close(target, echo));
    try testing.expectError(error.UnknownNode, builder.close(echo, .{ .index = 2 }));
    try builder.close(echo, echo);
    try testing.expectError(error.DelayClosed, builder.close(echo, target));
    _ = builder.finish();
}

// Locks each refusal of `follow` and `shift` by name, that nothing refused was built, and the
// edges that are accepted: the longest pause, and a period of one step per bucket.
test "the builder refuses a follower or a shift register it cannot evaluate" {
    var fixture: Fixture = undefined;
    try fixture.init();
    var nodes: [2]Node = undefined;
    var builder = fixture.builder(&nodes);
    const second: Time = .{ .flicks = flicks_per_second };
    const nan = std.math.nan(f64);
    var follow: Follow = .{
        .from = 0,
        .regions = fixture.span,
        .pick = .cycle,
        .mover = .{ .newtonian = .{ .speed = 1, .accel = 1, .decel = 0 } },
        .tolerance = 0,
        .pause_min = second,
        .pause_max = second,
        .seed = 0,
    };
    try testing.expectError(error.InvalidLimit, builder.follow(follow));
    follow.mover = .{ .spring = .{ .time = second, .overshoot = 0 } };
    const unknowns = [_]simulation.Span{
        .{ .first = 0, .count = 0 },
        .{ .first = 0, .count = 2 },
        .{ .first = 2, .count = 1 },
    };
    for (unknowns) |unknown| {
        follow.regions = unknown;
        try testing.expectError(error.UnknownRegions, builder.follow(follow));
    }
    follow.regions = fixture.span;
    follow.tolerance = -0.1;
    try testing.expectError(error.InvalidTolerance, builder.follow(follow));
    follow.tolerance = nan;
    try testing.expectError(error.NotFinite, builder.follow(follow));
    follow.tolerance = 0;
    const pause_steps_beyond: i64 = simulation.pause_steps_max + 1;
    const pauses = [_][2]i64{ .{ -1, 0 }, .{ 2, 1 }, .{ 0, pause_steps_beyond * step_flicks } };
    for (pauses) |pause| {
        follow.pause_min = .{ .flicks = pause[0] };
        follow.pause_max = .{ .flicks = pause[1] };
        try testing.expectError(error.InvalidPause, builder.follow(follow));
    }

    var shift: Shift = .{
        .buckets = 0,
        .period = second,
        .low = 0,
        .high = 1,
        .odds = 0.5,
        .shape = .steps,
        .seed = 0,
    };
    try testing.expectError(error.InvalidBuckets, builder.shift(shift));
    shift.buckets = simulation.buckets_max + 1;
    try testing.expectError(error.InvalidBuckets, builder.shift(shift));
    shift.buckets = 4;
    shift.odds = nan;
    try testing.expectError(error.NotFinite, builder.shift(shift));
    for ([_]f64{ -0.1, 1.1 }) |odds| {
        shift.odds = odds;
        try testing.expectError(error.InvalidOdds, builder.shift(shift));
    }
    shift.odds = 1;
    for ([_]i64{ 0, 4 * step_flicks - 1, (1 << 53) + 1 }) |period| {
        shift.period = .{ .flicks = period };
        try testing.expectError(error.InvalidDuration, builder.shift(shift));
    }
    try testing.expectEqual(@as(u32, 0), builder.node_count);

    shift.period = .{ .flicks = 4 * step_flicks };
    _ = try builder.shift(shift);
    follow.pause_min = .{ .flicks = 0 };
    follow.pause_max = .{ .flicks = simulation.pause_steps_max * step_flicks };
    _ = try builder.follow(follow);
}

// Locks `simulation.zig` section 7 on the showcase's runaway loop, a chase of 1 + gain times its
// own delay: at a gain of 1.5 it saturates at the bound and holds, `finite` still holds for the loop
// but not for twice its fourth power, and a track that turns the gain back to 0.5 brings it down to
// 2, where 1 + 0.5 x = x settles.
test "a runaway loop saturates at the bound and comes back" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = 0 });
    var track_entries: [1]@import("../track.zig").Track = undefined;
    var samples: [4]@import("../recording.zig").Sample = undefined;
    var tracks = @import("../track.zig").Tracks.init(&track_entries);
    const gain_track = try tracks.add(&samples, 0, 2, 1.5);
    var nodes: [11]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 32, .cues = &cues, .tracks = &tracks });
    const feedback = try builder.delay(0);
    const gain = try builder.track(gain_track);
    const scaled = try builder.multiply(feedback, gain);
    const one = try builder.constant(1);
    const target = try builder.add(one, scaled);
    const loop = try builder.chase(.{ .target = target, .from = 0, .time = .{ .flicks = flicks_per_second / 2 }, .overshoot = 0 });
    try builder.close(feedback, loop);
    const square = try builder.multiply(loop, loop);
    const fourth = try builder.multiply(square, square);
    const over = try builder.multiply(fourth, try builder.constant(2));
    var slab: [32]f64 = undefined;
    var state = State.init(builder.finish(), &slab);

    state.eval(.{ .flicks = flicks_per_second });
    try testing.expect(state.finite());
    try testing.expect(state.value(loop) < simulation.state_bound);
    // The spring reaches a fixed point of its rounding a few units of the last place below the
    // bound, and stays there, the same bits at every read.
    var held: ?f64 = null;
    for ([_]i64{ 100, 120, 150 }) |seconds| {
        state.eval(.{ .flicks = seconds * flicks_per_second });
        try testing.expectApproxEqRel(simulation.state_bound, state.value(loop), 1e-12);
        try testing.expectEqual(state.value(loop), state.value(feedback));
        if (held) |value| try testing.expectEqual(value, state.value(loop));
        held = state.value(loop);
        try testing.expect(std.math.isInf(state.value(over)));
        try testing.expect(!state.finite());
    }
    try tracks.write(gain_track, .{ .flicks = 150 * flicks_per_second }, 0.5);
    state.eval(.{ .flicks = 300 * flicks_per_second });
    try testing.expectApproxEqAbs(@as(f64, 2), state.value(loop), 1e-9);
    try testing.expect(state.finite());
}

// Locks that a moving value or a goal cannot start past `simulation.state_bound`.
test "the builder keeps a moving constant within the bound" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = 0 });
    var nodes: [4]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 64, .cues = &cues });
    const past = simulation.state_bound * 2;
    try testing.expectError(error.NotFinite, builder.delay(past));
    const target = try builder.constant(past);
    const second: Time = .{ .flicks = flicks_per_second };
    try testing.expectError(error.NotFinite, builder.chase(.{ .target = target, .from = past, .time = second, .overshoot = 0 }));
    _ = try builder.chase(.{ .target = target, .from = simulation.state_bound, .time = second, .overshoot = 0 });
    const echo = try builder.delay(-simulation.state_bound);
    try builder.close(echo, echo);
    var regions_entries: [1]simulation.Region = undefined;
    var regions = simulation.Regions.init(&regions_entries);
    try testing.expectError(error.NotFinite, regions.add(&.{.{ .low = 0, .high = past }}));
    _ = builder.finish();
}

/// A noise chased with its time from a track, a crossing of the chase, and an input, read by one
/// reader at 60 Hz for ten seconds: 600 frames, which need 4,800 steps (step 20).
const Paced = struct {
    cue_times: [1]Time,
    cues: Cues,
    track_entries: [1]@import("../track.zig").Track,
    track_samples: [600]@import("../recording.zig").Sample,
    tracks: @import("../track.zig").Tracks,
    time_track: @import("../track.zig").TrackId,
    nodes: [6]Node,
    program: Program,
    chase: Id,
    level: Id,
    slab: [64]f64,
    checkpoints: [10 * 64]f64,

    const frame_flicks = @divExact(flicks_per_second, 60);
    const frames = 600;

    fn init(paced: *Paced) !void {
        paced.cues = Cues.init(&paced.cue_times);
        _ = try paced.cues.add(.{ .flicks = 0 });
        paced.tracks = @import("../track.zig").Tracks.init(&paced.track_entries);
        paced.time_track = try paced.tracks.add(&paced.track_samples, 0.125, 2, 0.5);
        var builder = Builder.init(&paced.nodes, .{ .slab_count_max = 32, .cues = &paced.cues, .tracks = &paced.tracks, .seed = 5 });
        const wander = try builder.noise(.{ .shape = .smooth, .hz = 1, .seed = 1 });
        const time = try builder.track(paced.time_track);
        paced.chase = try builder.chase(.{ .target = wander, .from = 0, .time = .{ .flicks = flicks_per_second }, .overshoot = 0, .time_from = time });
        _ = try builder.crossing(.{ .input = paced.chase, .level = 0, .direction = .both });
        paced.level = try builder.input(.{ .low = 0, .high = 1, .initial = 0.25 });
        paced.program = builder.finish();
        assert(paced.program.reader_slab_count() <= paced.slab.len);
        assert(paced.program.slab_count * 10 <= paced.checkpoints.len);
    }

    /// A reader with room for the copy, and with ten checkpoints or none.
    fn reader(paced: *Paced, checkpoints: bool) State {
        const slab = paced.slab[0..@intCast(paced.program.reader_slab_count())];
        const memory = paced.checkpoints[0 .. 10 * paced.program.slab_count];
        return State.init_with_checkpoints(paced.program, slab, if (checkpoints) memory else &.{});
    }

    fn frame(index: u64) Time {
        return .{ .flicks = @as(i64, @intCast(index)) * frame_flicks };
    }

    /// The chase's value at `time` from a fresh reader with no copy and no checkpoints.
    fn fresh(paced: *const Paced, time: Time) f64 {
        var slab: [64]f64 = undefined;
        var state = State.init(paced.program, slab[0..paced.program.slab_count]);
        state.eval(time);
        return state.value(paced.chase);
    }
};

// Locks step 20's first measure: `events(last, now)` then `eval(now)` each frame replays one step
// a frame with the copy, with or without checkpoints, where v0.1.0 ran 147,001 and 1,443,001; and
// a reader with no room for the copy still restores a checkpoint, as before.
test "a reader with the copy replays one step when events come before the eval" {
    var paced: Paced = undefined;
    try paced.init();
    var out: [64]graph_module.Event = undefined;
    for ([_]bool{ true, false }) |checkpoints| {
        var state = paced.reader(checkpoints);
        for (1..Paced.frames + 1) |index| {
            _ = state.events(Paced.frame(index - 1), Paced.frame(index), &out);
            state.eval(Paced.frame(index));
            if (index % 50 == 0) try testing.expectEqual(paced.fresh(Paced.frame(index)), state.value(paced.chase));
        }
        try testing.expect(state.steps_run <= 5_401);
    }
    var slab: [64]f64 = undefined;
    var state = State.init_with_checkpoints(paced.program, slab[0..paced.program.slab_count], paced.checkpoints[0 .. 10 * paced.program.slab_count]);
    for (1..Paced.frames + 1) |index| {
        _ = state.events(Paced.frame(index - 1), Paced.frame(index), &out);
        state.eval(Paced.frame(index));
    }
    try testing.expect(state.steps_run > 100_000);
}

// Locks `events_since`: one step a frame, the same events as the `(last, now]` form, the events at
// exactly `now` on a first call, and none on a repeat or a seek back.
test "events since the last read cost no step the evals would not" {
    var paced: Paced = undefined;
    try paced.init();
    var state = paced.reader(true);
    var other_slab: [64]f64 = undefined;
    var other = State.init(paced.program, other_slab[0..@intCast(paced.program.reader_slab_count())]);
    var out: [64]graph_module.Event = undefined;
    var expected: [64]graph_module.Event = undefined;
    var total: u32 = 0;
    _ = state.events_since(Paced.frame(0), &out);
    other.eval(Paced.frame(0));
    for (1..Paced.frames + 1) |index| {
        const found = state.events_since(Paced.frame(index), &out);
        const wanted = other.events(.{ .flicks = Paced.frame(index - 1).flicks + 1 }, .{ .flicks = Paced.frame(index).flicks + 1 }, &expected);
        other.eval(Paced.frame(index));
        try testing.expectEqualDeep(wanted, found);
        try testing.expectEqualSlices(graph_module.Event, expected[0..wanted.count], out[0..found.count]);
        total += found.count;
    }
    try testing.expect(total > 0);
    try testing.expect(state.steps_run <= 4_801);
    try testing.expectEqual(@as(u32, 0), state.events_since(Paced.frame(Paced.frames), &out).count);
    try testing.expectEqual(@as(u32, 0), state.events_since(Paced.frame(10), &out).count);

    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const at = try cues.add(.{ .flicks = flicks_per_second });
    var nodes: [1]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 4, .cues = &cues });
    _ = try builder.cues(.{ .first = at, .count = 1 });
    var slab: [4]f64 = undefined;
    var first = State.init(builder.finish(), &slab);
    try testing.expectEqual(@as(u32, 1), first.events_since(.{ .flicks = flicks_per_second }, &out).count);
    try testing.expectEqual(@as(u32, 0), first.events_since(.{ .flicks = flicks_per_second }, &out).count);
}

// Locks step 20's third measure: a track write at the time just read, on alternate frames, drops
// the slab's own step but not the copy, so the next read replays one step. A recording attached to
// the input stays complete through it, and a seek back that reads a new value marks it incomplete.
test "a track write at the time just read replays one step" {
    var paced: Paced = undefined;
    try paced.init();
    var state = paced.reader(true);
    var entries: [16]@import("../recording.zig").Sample = undefined;
    var recording = @import("../recording.zig").Recording.init(&entries);
    state.record(paced.level, &recording);
    for (1..Paced.frames + 1) |index| {
        state.eval(Paced.frame(index));
        if (index % 2 == 0) {
            const value: f64 = if (index % 4 == 0) 0.5 else 0.625;
            try paced.tracks.write(paced.time_track, Paced.frame(index), value);
        }
        if (index % 50 == 1) try testing.expectEqual(paced.fresh(Paced.frame(index)), state.value(paced.chase));
    }
    try testing.expect(state.steps_run <= 5_100);
    try testing.expect(recording.complete());
    // A seek back that reads what the recording plays is still no loss; one that reads a new
    // value at an old time is.
    state.eval(.{ .flicks = 5 * flicks_per_second });
    try testing.expect(recording.complete());
    state.set_input(paced.level, 0.75);
    state.eval(.{ .flicks = 4 * flicks_per_second });
    try testing.expect(!recording.complete());
}

// Locks that a cue move drops the copy, and a carried state starts without one but keeps the
// time of its last read.
test "the copy is dropped by a cue move and not carried" {
    var paced: Paced = undefined;
    try paced.init();
    var state = paced.reader(true);
    state.eval(Paced.frame(60));
    try testing.expect(state.recent_step != null);
    try paced.cues.move(.{ .index = 0 }, .{ .flicks = flicks_per_second / 4 });
    state.eval(Paced.frame(61));
    try testing.expectEqual(paced.fresh(Paced.frame(61)), state.value(paced.chase));
    var twins: [6]?u32 = undefined;
    for (paced.program.nodes, 0..) |_, index| twins[index] = @intCast(index);
    var slab: [64]f64 = undefined;
    var carried = State.init(paced.program, slab[0..@intCast(paced.program.reader_slab_count())]);
    try testing.expect(carried.adopt(&state, twins[0..paced.program.nodes.len]));
    try testing.expectEqual(@as(?u64, null), carried.recent_step);
    try testing.expectEqual(state.last_read, carried.last_read);
}
