//! Tests of the graph: springs and Newtonian moves.
//!
//! They read `graph.zig` and `state.zig` as a client would, plus the few internals that
//! `graph.zig` marks public for its reader and its tests.

const std = @import("std");
const Cue = @import("../cue.zig").Cue;
const Cues = @import("../cue.zig").Cues;
const motion = @import("../motion.zig");
const Goal = motion.Goal;
const simulation = @import("../simulation.zig");
const time_module = @import("../time.zig");
const Time = time_module.Time;
const track_module = @import("../track.zig");
const Tracks = track_module.Tracks;
const graph_module = @import("../graph.zig");
const testing = std.testing;
const Rate = @import("../time.zig").Rate;
const State = graph_module.State;
const Builder = graph_module.Builder;
const Id = graph_module.Id;
const Node = graph_module.Node;
const Program = graph_module.Program;

/// Cues at 0, 0.4, 1.1, and 1.5 s, and two paths over them: 1, 0, 3, -2 for a spring, and 10, 2,
/// 6 for a Newtonian move from the second cue.
const Track = struct {
    times: [4]Time,
    cues: Cues,
    entries: [7]Goal,
    goals: motion.Goals,
    spring_path: motion.Path,
    newtonian_path: motion.Path,

    fn init(track: *Track) !void {
        track.cues = Cues.init(&track.times);
        const seconds_tenths = [_]i64{ 0, 4, 11, 15 };
        var cues: [4]Cue = undefined;
        for (seconds_tenths, &cues) |tenths, *cue| {
            cue.* = try track.cues.add(.{ .flicks = tenths * 70_560_000 });
        }
        track.goals = motion.Goals.init(&track.entries);
        track.spring_path = try track.goals.add(&.{
            .{ .cue = cues[0], .value = 1 },
            .{ .cue = cues[1], .value = 0 },
            .{ .cue = cues[2], .value = 3 },
            .{ .cue = cues[3], .value = -2 },
        });
        track.newtonian_path = try track.goals.add(&.{
            .{ .cue = cues[1], .value = 10 },
            .{ .cue = cues[2], .value = 2 },
            .{ .cue = cues[3], .value = 6 },
        });
    }

    /// A spring of overshoot 0.2 and a Newtonian move, built in `nodes`.
    fn build(track: *const Track, nodes: []Node) ![2]Id {
        var builder = Builder.init(nodes, .{
            .slab_count_max = 2 * (1 + motion.cursor_count),
            .cues = &track.cues,
            .goals = track.goals.table(),
        });
        const bouncy = try builder.spring(.{
            .from = -1,
            .goals = track.spring_path,
            .time = .{ .flicks = 352_800_000 },
            .overshoot = 0.2,
        });
        const newtonian = try builder.newtonian(.{
            .from = 0,
            .goals = track.newtonian_path,
            .speed = 12,
            .accel = 40,
            .decel = 30,
        });
        _ = builder.finish();
        return .{ bouncy, newtonian };
    }
};

// Locks the rule of section 8: 2.5 s of a spring and a Newtonian move at 240 Hz, read forwards
// with the cursor, backwards, in a scattered order, and each from a fresh slab, give the same
// bits.
test "a motion's cursor never changes a value" {
    var track: Track = undefined;
    try track.init();
    var nodes: [2]Node = undefined;
    const ids = try track.build(&nodes);
    const program: Program = .{
        .nodes = &nodes,
        .cues = &track.cues,
        .goals = track.goals.table(),
        .regions = &.{},
        .samples = &.{},
        .tracks = &Tracks.empty,
        .start = .{ .index = 0 },
        .simulated = false,
        .slab_count = 2 * (1 + motion.cursor_count),
    };
    const rate = Rate.from_hz(240).?;
    const frames_count = 600;
    var slab: [10]f64 = undefined;
    var state = State.init(program, &slab);
    var forward: [frames_count][2]f64 = undefined;
    for (&forward, 0..) |*values, frame| {
        state.eval(Time.from_ticks(@intCast(frame), rate).?);
        values.* = .{ state.value(ids[0]), state.value(ids[1]) };
    }

    var frame: usize = frames_count;
    while (frame > 0) {
        frame -= 1;
        state.eval(Time.from_ticks(@intCast(frame), rate).?);
        try testing.expectEqual(forward[frame], [2]f64{ state.value(ids[0]), state.value(ids[1]) });
    }
    var hop: usize = 0;
    for (0..frames_count) |_| {
        hop = (hop + 389) % frames_count;
        state.eval(Time.from_ticks(@intCast(hop), rate).?);
        try testing.expectEqual(forward[hop], [2]f64{ state.value(ids[0]), state.value(ids[1]) });
        var slab_fresh: [10]f64 = undefined;
        var fresh = State.init(program, &slab_fresh);
        fresh.eval(Time.from_ticks(@intCast(hop), rate).?);
        try testing.expectEqual(forward[hop], [2]f64{ fresh.value(ids[0]), fresh.value(ids[1]) });
    }
    try testing.expectEqual(@as(f64, -1), forward[0][0]);
    try testing.expectEqual(@as(f64, 6), forward[frames_count - 1][1]);
}

// Locks the demo of this step: stepping at 24, 60, 240, and 960 Hz through 2.5 s of retargets gives
// the same value at every instant the rates share, every 1/12 s. The tolerance is zero: a value
// depends on the time and the goals, never on the frames before it.
test "springs ignore the frame rate" {
    var track: Track = undefined;
    try track.init();
    var nodes: [2]Node = undefined;
    const ids = try track.build(&nodes);
    const program: Program = .{
        .nodes = &nodes,
        .cues = &track.cues,
        .goals = track.goals.table(),
        .regions = &.{},
        .samples = &.{},
        .tracks = &Tracks.empty,
        .start = .{ .index = 0 },
        .simulated = false,
        .slab_count = 2 * (1 + motion.cursor_count),
    };
    const rates_hz = [_]u32{ 24, 60, 240, 960 };
    var shared: [rates_hz.len][31][2]f64 = undefined;
    for (rates_hz, &shared) |hz, *values| {
        var slab: [10]f64 = undefined;
        var state = State.init(program, &slab);
        const per_shared = hz / 12;
        for (0..31 * per_shared) |frame| {
            state.eval(Time.from_ticks(@intCast(frame), Rate.from_hz(hz).?).?);
            if (frame % per_shared == 0) {
                values[frame / per_shared] = .{ state.value(ids[0]), state.value(ids[1]) };
            }
        }
    }
    for (shared[1..]) |values| try testing.expectEqual(shared[0], values);
}

// Locks that a cue move makes a cursor stale: a reader that has played past the second goal sees
// the move at its next eval, with the value a fresh reader computes, which differs from before.
test "moving a cue reaches a motion's cursor" {
    var track: Track = undefined;
    try track.init();
    var nodes: [2]Node = undefined;
    const ids = try track.build(&nodes);
    const program: Program = .{
        .nodes = &nodes,
        .cues = &track.cues,
        .goals = track.goals.table(),
        .regions = &.{},
        .samples = &.{},
        .tracks = &Tracks.empty,
        .start = .{ .index = 0 },
        .simulated = false,
        .slab_count = 2 * (1 + motion.cursor_count),
    };
    var slab: [10]f64 = undefined;
    var state = State.init(program, &slab);
    const time: Time = .{ .flicks = 13 * 70_560_000 };
    for (0..14) |tenth| state.eval(.{ .flicks = @as(i64, @intCast(tenth)) * 70_560_000 });
    state.eval(time);
    const before = [2]f64{ state.value(ids[0]), state.value(ids[1]) };

    try track.cues.move(.{ .index = 1 }, .{ .flicks = 3 * 70_560_000 });
    state.eval(time);
    const after = [2]f64{ state.value(ids[0]), state.value(ids[1]) };
    var slab_fresh: [10]f64 = undefined;
    var fresh = State.init(program, &slab_fresh);
    fresh.eval(time);
    try testing.expectEqual([2]f64{ fresh.value(ids[0]), fresh.value(ids[1]) }, after);
    try testing.expect(before[0] != after[0]);
    try testing.expect(before[1] != after[1]);
}

// Locks the layout of section 2 for a motion: 3 lanes of output then 4 f64 of cursor, so the next
// node starts at 7, and every lane holds the value.
test "a motion keeps its cursor after its output" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 0 });
    var entries: [1]Goal = undefined;
    var goals = motion.Goals.init(&entries);
    const path = try goals.add(&.{.{ .cue = cue, .value = 2 }});
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 10,
        .cues = &cues,
        .goals = goals.table(),
    });
    builder.extent = .{ .lanes = 3, .components = 1 };
    const move = try builder.newtonian(.{
        .from = 0,
        .goals = path,
        .speed = 1,
        .accel = 1,
        .decel = 1,
    });
    const after = try builder.constant(5);
    const program = builder.finish();
    try testing.expectEqual(@as(u32, 7), program.nodes[after.index].offset);
    try testing.expectEqual(@as(u32, 10), program.slab_count);
    var slab: [10]f64 = undefined;
    var state = State.init(program, &slab);
    state.eval(.{ .flicks = 705_600_000 });
    try testing.expectEqualSlices(f64, &@as([3]f64, @splat(0.5)), state.values(move));
}

// Locks each refusal of `spring` and `newtonian` by name, and that nothing refused was built.
test "the builder refuses a motion it cannot evaluate" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 0 });
    var entries: [2]Goal = undefined;
    var goals = motion.Goals.init(&entries);
    const path = try goals.add(&.{.{ .cue = cue, .value = 1 }});
    const beyond = try goals.add(&.{.{ .cue = .{ .index = 1 }, .value = 1 }});
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 10,
        .cues = &cues,
        .goals = goals.table(),
    });
    const second: Time = .{ .flicks = 705_600_000 };
    var spring: motion.Spring = .{ .from = 0, .goals = path, .time = second, .overshoot = 0 };
    const unknowns = [_]motion.Path{
        .{ .first = 0, .count = 0 },
        .{ .first = 1, .count = 2 },
        .{ .first = 3, .count = 1 },
    };
    for (unknowns) |unknown| {
        spring.goals = unknown;
        try testing.expectError(error.UnknownGoals, builder.spring(spring));
    }
    spring.goals = beyond;
    try testing.expectError(error.UnknownCue, builder.spring(spring));
    spring.goals = path;
    spring.from = std.math.inf(f64);
    try testing.expectError(error.NotFinite, builder.spring(spring));
    spring.from = 0;
    spring.time = .{ .flicks = 0 };
    try testing.expectError(error.InvalidDuration, builder.spring(spring));
    spring.time = second;
    for ([_]f64{ -0.1, 1, 2 }) |overshoot| {
        spring.overshoot = overshoot;
        try testing.expectError(error.InvalidOvershoot, builder.spring(spring));
    }
    spring.overshoot = std.math.nan(f64);
    try testing.expectError(error.NotFinite, builder.spring(spring));

    var newtonian: motion.Newtonian = .{
        .from = 0,
        .goals = path,
        .speed = 1,
        .accel = 1,
        .decel = 1,
    };
    newtonian.decel = 0;
    try testing.expectError(error.InvalidLimit, builder.newtonian(newtonian));
    newtonian.decel = 1;
    newtonian.speed = -1;
    try testing.expectError(error.InvalidLimit, builder.newtonian(newtonian));
    newtonian.speed = std.math.inf(f64);
    try testing.expectError(error.NotFinite, builder.newtonian(newtonian));
    try testing.expectEqual(@as(u32, 0), builder.node_count);
    newtonian.speed = 1;
    _ = try builder.newtonian(newtonian);
    spring.overshoot = 0.999;
    _ = try builder.spring(spring);
}
