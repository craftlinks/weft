//! Tests of the graph: ranges, classes, live input, and recordings.
//!
//! They read `graph.zig` and `state.zig` as a client would, plus the few internals that
//! `graph.zig` marks public for its reader and its tests.

const std = @import("std");
const assert = std.debug.assert;
const Cue = @import("../cue.zig").Cue;
const Cues = @import("../cue.zig").Cues;
const event_module = @import("../event.zig");
const Event = event_module.Event;
const motion = @import("../motion.zig");
const Goal = motion.Goal;
const range_module = @import("../range.zig");
const Class = range_module.Class;
const Range = range_module.Range;
const recording_module = @import("../recording.zig");
const Recording = recording_module.Recording;
const Sample = recording_module.Sample;
const noise_hash = @import("../noise.zig").hash;
const simulation = @import("../simulation.zig");
const time_module = @import("../time.zig");
const Time = time_module.Time;
const track_module = @import("../track.zig");
const Tracks = track_module.Tracks;
const TrackId = track_module.TrackId;
const graph_module = @import("../graph.zig");
const testing = std.testing;
const Rate = @import("../time.zig").Rate;
const flicks_per_second = @import("../time.zig").flicks_per_second;
const State = graph_module.State;
const events_test = @import("events.zig");
const build_tremolo = @import("ops.zig").build_tremolo;
const events_at_once = @import("events.zig").events_at_once;
const carrier = @import("ops.zig").carrier;
const cue_table_at_zero = @import("events.zig").cue_table_at_zero;
const Builder = graph_module.Builder;
const Crossing = graph_module.Crossing;
const Id = graph_module.Id;
const Input = graph_module.Input;
const Node = graph_module.Node;
const Program = graph_module.Program;
const flicks_per_second_float = graph_module.flicks_per_second_float;

/// The ranges of a finished program, for the tests of section 12.
pub fn ranges_of(program: *const Program, out: []Range) []const Range {
    program.ranges(out);
    return out[0..program.nodes.len];
}

// Locks the worked ranges: exact for a wave, a sum of two, and `x * x`, which interval arithmetic
// gives as [-1, 1]; a one-goal spring at 16.3% overshoot reaches 1.163 and not below its start; a
// critical spring with three goals is the hull of its goals; a Newtonian move is its hull widened
// by its stopping distance, speed^2 / (2 decel) = 2.
test "worked ranges are exact or within their margin" {
    var cue_times: [3]Time = undefined;
    var cues = Cues.init(&cue_times);
    for (0..3) |index| {
        _ = try cues.add(.{ .flicks = @as(i64, @intCast(index)) * flicks_per_second });
    }
    var goal_entries: [5]Goal = undefined;
    var goals = motion.Goals.init(&goal_entries);
    const one = try goals.add(&.{.{ .cue = .{ .index = 0 }, .value = 1 }});
    const three = try goals.add(&.{
        .{ .cue = .{ .index = 0 }, .value = 1 },
        .{ .cue = .{ .index = 1 }, .value = -0.5 },
        .{ .cue = .{ .index = 2 }, .value = 0.25 },
    });
    const glide = try goals.add(&.{.{ .cue = .{ .index = 0 }, .value = 2 }});
    var nodes: [8]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 64,
        .cues = &cues,
        .goals = goals.table(),
    });
    const wave = try builder.wave(carrier);
    const sum = try builder.add(wave, wave);
    const square = try builder.multiply(wave, wave);
    const os = range_module.overshoot(0.5);
    // The overshoot that gives a damping ratio of 0.5 exactly.
    const second: Time = .{ .flicks = flicks_per_second };
    const bouncy = try builder.spring(.{
        .from = 0,
        .goals = one,
        .time = second,
        .overshoot = os,
    });
    const critical = try builder.spring(.{
        .from = 0,
        .goals = three,
        .time = second,
        .overshoot = 0,
    });
    const newtonian = try builder.newtonian(.{
        .from = 0,
        .goals = glide,
        .speed = 4,
        .accel = 2,
        .decel = 4,
    });
    const program = builder.finish();
    var out: [8]Range = undefined;
    const result = ranges_of(&program, &out);
    try testing.expectEqual(Range{ .low = -1, .high = 1 }, result[wave.index]);
    try testing.expectEqual(Range{ .low = -2, .high = 2 }, result[sum.index]);
    try testing.expectEqual(Range{ .low = -1, .high = 1 }, result[square.index]);
    try testing.expectApproxEqAbs(@as(f64, 0.163), os, 0.0005);
    try testing.expect(result[bouncy.index].high >= 1 + os);
    try testing.expectApproxEqAbs(1 + os, result[bouncy.index].high, 1e-10);
    try testing.expect(result[bouncy.index].low <= 0);
    try testing.expectApproxEqAbs(@as(f64, 0), result[bouncy.index].low, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, -0.5), result[critical.index].low, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 1), result[critical.index].high, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, -2), result[newtonian.index].low, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 4), result[newtonian.index].high, 1e-10);
}

/// A critical chase of `1 + gain * delay(chase)`, from 0, returning the chase.
fn build_loop(builder: *Builder, gain: f64, overshoot: f64) Builder.Error!Id {
    const echo = try builder.delay(0);
    const scaled = try builder.multiply(echo, try builder.constant(gain));
    const target = try builder.add(try builder.constant(1), scaled);
    const result = try builder.chase(.{
        .target = target,
        .from = 0,
        .time = .{ .flicks = flicks_per_second / 2 },
        .overshoot = overshoot,
    });
    try builder.close(echo, result);
    return result;
}

// Locks the fixed point of a delay's loop: a critical chase of 1 - 0.8 times its own delay has a
// finite range that holds [0, 1], and one of 1 + 1.25 times its delay, which grows without end,
// has an infinite one.
test "a loop through a delay has a finite range only when it settles" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var nodes: [6]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 32, .cues = &cues });
    const settling = try build_loop(&builder, -0.8, 0);
    const program = builder.finish();
    var out: [6]Range = undefined;
    const result = ranges_of(&program, &out);
    try testing.expect(std.math.isFinite(result[settling.index].low));
    try testing.expect(std.math.isFinite(result[settling.index].high));
    try testing.expect(result[settling.index].covers(.{ .low = 0, .high = 1 }));
    try testing.expect(result[settling.index].high < 1 + 1e-9);

    var nodes_growing: [6]Node = undefined;
    var growing_builder = Builder.init(&nodes_growing, .{ .slab_count_max = 32, .cues = &cues });
    const growing = try build_loop(&growing_builder, 1.25, 0);
    const growing_program = growing_builder.finish();
    const growing_result = ranges_of(&growing_program, &out);
    try testing.expectEqual(std.math.inf(f64), growing_result[growing.index].high);
}

// Locks that classes rise through inputs, a delay's included: a wave plus a spring is exact, a
// chase plus an input is live, and a delay closed onto a live node is live, as is what reads it.
// The report names the first live node and the first simulated one.
test "classes rise through inputs, and the report names the live node" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var goal_entries: [1]Goal = undefined;
    var goals = motion.Goals.init(&goal_entries);
    const path = try goals.add(&.{.{ .cue = .{ .index = 0 }, .value = 1 }});
    var nodes: [10]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 64,
        .cues = &cues,
        .goals = goals.table(),
    });
    const wave = try builder.wave(carrier);
    const second: Time = .{ .flicks = flicks_per_second };
    const spring = try builder.spring(.{
        .from = 0,
        .goals = path,
        .time = second,
        .overshoot = 0,
    });
    const exact = try builder.add(wave, spring);
    const echo = try builder.delay(0);
    const after_echo = try builder.add(echo, wave);
    const chased = try builder.chase(.{
        .target = wave,
        .from = 0,
        .time = second,
        .overshoot = 0,
    });
    const live = try builder.input(.{ .low = -1, .high = 1 });
    const mixed = try builder.add(chased, live);
    try builder.close(echo, mixed);
    const program = builder.finish();
    var classes: [10]Class = undefined;
    program.classes(&classes);
    try testing.expectEqual(Class.pure, classes[wave.index]);
    try testing.expectEqual(Class.exact, classes[spring.index]);
    try testing.expectEqual(Class.exact, classes[exact.index]);
    try testing.expectEqual(Class.simulated, classes[chased.index]);
    try testing.expectEqual(Class.live, classes[mixed.index]);
    try testing.expectEqual(Class.live, classes[echo.index]);
    try testing.expectEqual(Class.live, classes[after_echo.index]);
    const report = program.report();
    try testing.expect(!report.seekable);
    try testing.expectEqual(live, report.live.?);
    try testing.expect(report.stepped);
    try testing.expectEqual(echo, report.first_simulated.?);

    var pure_nodes: [4]Node = undefined;
    var pure_builder = Builder.init(&pure_nodes, .{ .slab_count_max = 8 });
    _ = try build_tremolo(&pure_builder);
    const pure_report = pure_builder.finish().report();
    try testing.expect(pure_report.seekable);
    try testing.expect(!pure_report.stepped);
    try testing.expectEqual(@as(?Id, null), pure_report.live);
}

// Locks the input's contract: a value outside its range reads as the nearest end, it keeps the
// value set last through a checkpoint restore, since it has no past, and a backward read while
// recording counts a drop and keeps the table in order.
test "an input is clamped, keeps its value, and records forward only" {
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 8, .cues = &cues });
    const live = try builder.input(.{ .low = 0, .high = 1, .initial = 0.5 });
    const chased = try builder.chase(.{
        .target = live,
        .from = 0,
        .time = .{ .flicks = flicks_per_second },
        .overshoot = 0,
    });
    const program = builder.finish();
    var out: [2]Range = undefined;
    try testing.expectEqual(Range{ .low = 0, .high = 1 }, ranges_of(&program, &out)[live.index]);
    var slab: [8]f64 = undefined;
    var checkpoints: [4 * 8]f64 = undefined;
    var state = State.init_with_checkpoints(program, &slab, &checkpoints);
    var entries: [8]Sample = undefined;
    var recording = Recording.init(&entries);
    state.record(live, &recording);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqual(@as(f64, 0.5), state.value(live));
    state.set_input(live, 2);
    state.eval(.{ .flicks = 3 * flicks_per_second });
    try testing.expectEqual(@as(f64, 1), state.value(live));
    try testing.expect(recording.complete());
    state.set_input(live, -3);
    state.eval(.{ .flicks = flicks_per_second + flicks_per_second / 3 });
    try testing.expectEqual(@as(f64, 0), state.value(live));
    try testing.expect(state.value(chased) > 0);
    try testing.expect(!recording.complete());
    const table = recording.table();
    for (table[1..], table[0 .. table.len - 1]) |later, earlier| {
        try testing.expect(later.time.flicks >= earlier.time.flicks);
    }
}

/// The value a recorded run sets for read `index`, a seeded draw in [-1.5, 1.5], so some are
/// clamped.
fn live_value(index: u64) f64 {
    const bits = noise_hash(0x11fe, index);
    return @as(f64, @floatFromInt(bits >> 11)) * 0x1p-53 * 3 - 1.5;
}

/// An input, or a recording of one, feeding a chase and a crossing, starting at a cue half a step
/// after 0.25 s. Returns the source, the chase, and the crossing.
fn build_listener(builder: *Builder, clip: ?recording_module.Clip) Builder.Error![3]Id {
    const source = if (clip) |played|
        try builder.recorded(played)
    else
        try builder.input(.{ .low = -1, .high = 1 });
    const chased = try builder.chase(.{
        .target = source,
        .from = 0,
        .time = .{ .flicks = flicks_per_second / 3 },
        .overshoot = 0.1,
    });
    const gate = try builder.crossing(.{ .input = chased, .level = 0.2, .direction = .both });
    return .{ source, chased, gate };
}

// Locks the page's third check: a live input set each read at 60 Hz for 10 s, recorded, then
// played back by a `recorded` node in its place and read at the same times, gives every value
// bit for bit. The recording is seekable: read in a drawn order it gives the same values, and its
// events are the same however the range is split.
test "a recorded run equals the live run, value for value" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = flicks_per_second / 4 + simulation.step.flicks / 2 });
    const reads = 600;
    var live_nodes: [3]Node = undefined;
    var live_builder = Builder.init(&live_nodes, .{ .slab_count_max = 16, .cues = &cues });
    const live_ids = try build_listener(&live_builder, null);
    const live_program = live_builder.finish();
    var slab: [16]f64 = undefined;
    var checkpoints: [12 * 16]f64 = undefined;
    var state = State.init_with_checkpoints(live_program, &slab, &checkpoints);
    var entries: [2 * reads]Sample = undefined;
    var recording = Recording.init(&entries);
    state.record(live_ids[0], &recording);
    var values: [reads][3]f64 = undefined;
    const rate = Rate.from_hz(60).?;
    for (&values, 0..) |*row, index| {
        state.set_input(live_ids[0], live_value(index));
        state.eval(Time.from_ticks(@intCast(index), rate).?);
        for (row, live_ids) |*value, id| value.* = state.value(id);
    }
    try testing.expect(recording.complete());

    var sample_entries: [2 * reads]Sample = undefined;
    var samples = recording_module.Samples.init(&sample_entries);
    const clip = try samples.add(recording.table());
    var nodes: [3]Node = undefined;
    var builder = Builder.init(&nodes, .{
        .slab_count_max = 16,
        .cues = &cues,
        .samples = samples.table(),
    });
    const ids = try build_listener(&builder, clip);
    const program = builder.finish();
    try testing.expect(program.report().seekable);
    var replay_slab: [16]f64 = undefined;
    var replay_checkpoints: [12 * 16]f64 = undefined;
    var replay = State.init_with_checkpoints(program, &replay_slab, &replay_checkpoints);
    for (values, 0..) |row, index| {
        replay.eval(Time.from_ticks(@intCast(index), rate).?);
        for (row, ids) |value, id| try testing.expectEqual(value, replay.value(id));
    }
    var prng = std.Random.DefaultPrng.init(8);
    var seek = State.init(program, &replay_slab);
    for (0..200) |_| {
        const index = prng.random().uintLessThan(usize, reads);
        seek.eval(Time.from_ticks(@intCast(index), rate).?);
        for (values[index], ids) |value, id| try testing.expectEqual(value, seek.value(id));
    }
    const end: Time = .{ .flicks = 10 * flicks_per_second };
    const whole = try events_at_once(program, end, &events_test.events_whole);
    try testing.expect(whole.len > 0);
    const split: events_test.Split = .{ .drawn = 5 };
    const joined = try events_test.events_split(program, end, split, 6, &events_test.events_joined);
    try testing.expectEqualSlices(Event, whole, joined);
}

// Locks the refusals of an input and a recorded node by name, and that nothing is built.
test "the builder refuses an input or a recording it cannot evaluate" {
    var sample_entries: [1]Sample = .{.{ .time = .{ .flicks = 0 }, .value = 1 }};
    var nodes: [1]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 4, .samples = &sample_entries });
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    try testing.expectError(error.NotFinite, builder.input(.{ .low = nan }));
    try testing.expectError(error.NotFinite, builder.input(.{ .high = nan }));
    try testing.expectError(error.NotFinite, builder.input(.{ .initial = inf }));
    const reversed: Input = .{ .low = 1, .high = 0, .initial = 0.5 };
    try testing.expectError(error.InvalidRange, builder.input(reversed));
    try testing.expectError(error.InvalidRange, builder.input(.{ .low = 1, .high = 2 }));
    try testing.expectError(error.UnknownSamples, builder.recorded(.{ .first = 0, .count = 0 }));
    try testing.expectError(error.UnknownSamples, builder.recorded(.{ .first = 0, .count = 2 }));
    try testing.expectError(error.UnknownSamples, builder.recorded(.{ .first = 2, .count = 1 }));
    try testing.expectEqual(@as(u32, 0), builder.node_count);
    const played = try builder.recorded(.{ .first = 0, .count = 1 });
    const program = builder.finish();
    var out: [1]Range = undefined;
    try testing.expectEqual(Range.point(1), ranges_of(&program, &out)[played.index]);
}

/// One graph drawn for the randomized range test: its tables, nodes, and the inputs to set.
const Drawn = struct {
    cue_times: [3]Time,
    cues: Cues,
    goal_entries: [24]Goal,
    goals: motion.Goals,
    region_entries: [16]simulation.Region,
    regions: simulation.Regions,
    sample_entries: [32]Sample,
    samples: recording_module.Samples,
    track_entries: [2]track_module.Track,
    track_samples: [2][64]Sample,
    tracks: Tracks,
    nodes: [nodes_max]Node,
    program: Program,

    const nodes_max = 12;
    const slab_count_max = 256;

    fn init(drawn: *Drawn, random: std.Random) !void {
        drawn.cues = Cues.init(&drawn.cue_times);
        inline for (.{ 1, 3, 6 }) |half_seconds| {
            _ = try drawn.cues.add(.{ .flicks = @divExact(half_seconds * flicks_per_second, 2) });
        }
        drawn.goals = motion.Goals.init(&drawn.goal_entries);
        drawn.regions = simulation.Regions.init(&drawn.region_entries);
        drawn.samples = recording_module.Samples.init(&drawn.sample_entries);
        // Tables first, since the builder holds them as slices.
        var paths: [8]motion.Path = undefined;
        for (&paths) |*path| {
            const count = random.intRangeAtMost(u32, 1, 3);
            var goals: [3]Goal = undefined;
            for (goals[0..count], 0..) |*goal, index| {
                goal.* = .{ .cue = .{ .index = @intCast(index) }, .value = between(random, -2, 2) };
            }
            path.* = try drawn.goals.add(goals[0..count]);
        }
        var spans: [8]simulation.Span = undefined;
        for (&spans) |*span| {
            const count = random.intRangeAtMost(u32, 1, 2);
            var regions: [2]simulation.Region = undefined;
            for (regions[0..count]) |*region| {
                region.* = .{ .low = between(random, -2, 2), .high = between(random, -2, 2) };
            }
            span.* = try drawn.regions.add(regions[0..count]);
        }
        var clips: [8]recording_module.Clip = undefined;
        for (&clips) |*clip| {
            const count = random.intRangeAtMost(u32, 1, 4);
            var samples: [4]Sample = undefined;
            var flicks: i64 = 0;
            for (samples[0..count]) |*sample| {
                flicks += random.intRangeLessThan(i64, 0, flicks_per_second);
                sample.* = .{ .time = .{ .flicks = flicks }, .value = between(random, -2, 2) };
            }
            clip.* = try drawn.samples.add(samples[0..count]);
        }
        drawn.tracks = Tracks.init(&drawn.track_entries);
        for (&drawn.track_samples) |*samples| {
            const low = between(random, -2, 1);
            const high = low + between(random, 0, 3);
            _ = try drawn.tracks.add(samples, low, high, between(random, low, high));
        }
        var builder = Builder.init(&drawn.nodes, .{
            .slab_count_max = slab_count_max,
            .cues = &drawn.cues,
            .goals = drawn.goals.table(),
            .regions = drawn.regions.table(),
            .samples = drawn.samples.table(),
            .tracks = &drawn.tracks,
            .seed = random.int(u64),
        });
        const count = random.intRangeAtMost(u32, 2, nodes_max - 1);
        while (builder.node_count < count) {
            try draw_node(&builder, random, &paths, &spans, &clips);
        }
        drawn.program = builder.finish();
    }

    /// Adds one drawn node, or two for a bounce. A delay is closed at once onto a node before it,
    /// or onto itself, so the randomized graphs have no loop that can grow without end; the loop
    /// test below covers loops.
    fn draw_node(
        builder: *Builder,
        random: std.Random,
        paths: []const motion.Path,
        spans: []const simulation.Span,
        clips: []const recording_module.Clip,
    ) !void {
        const any: Id = .{ .index = random.uintLessThan(u32, @max(builder.node_count, 1)) };
        const cue: Cue = .{ .index = random.uintLessThan(u32, 3) };
        const seconds = struct {
            fn of(r: std.Random, low: f64, high: f64) Time {
                const flicks = between(r, low, high) * flicks_per_second_float;
                return .{ .flicks = @intFromFloat(flicks) };
            }
        }.of;
        const other: Id = .{ .index = random.uintLessThan(u32, @max(builder.node_count, 1)) };
        const choice = if (builder.node_count == 0) 0 else random.uintLessThan(u32, 23);
        const from = struct {
            fn maybe(r: std.Random, id: Id) ?Id {
                return if (r.boolean()) id else null;
            }
        }.maybe;
        _ = switch (choice) {
            0 => try builder.constant(between(random, -2, 2)),
            1 => try builder.add(any, other),
            2 => try builder.multiply(any, other),
            3 => try builder.map_range(.{
                .input = any,
                .input_low = between(random, -1, 1),
                .input_high = between(random, 1.5, 3),
                .output_low = between(random, -3, 3),
                .output_high = between(random, -3, 3),
            }),
            4 => try builder.wave(.{
                .shape = random.enumValue(@import("../wave.zig").Shape),
                .hz = between(random, 0.1, 5),
            }),
            5 => try builder.noise(.{
                .shape = random.enumValue(@import("../noise.zig").Shape),
                .hz = between(random, 0.1, 5),
                .seed = random.int(u64),
            }),
            6 => try builder.tween(.{
                .from = between(random, -2, 2),
                .to = between(random, -2, 2),
                .duration = seconds(random, 0.1, 2),
                .ease = .{
                    .x1 = between(random, 0, 1),
                    .y1 = between(random, -0.5, 1.5),
                    .x2 = between(random, 0, 1),
                    .y2 = between(random, -0.5, 1.5),
                },
                .start = cue,
                .previous = if (random.boolean()) any else null,
            }),
            7 => try builder.spring(.{
                .from = between(random, -2, 2),
                .goals = paths[random.uintLessThan(usize, paths.len)],
                .time = seconds(random, 0.1, 1),
                .overshoot = between(random, 0, 0.6),
            }),
            8 => try builder.newtonian(.{
                .from = between(random, -2, 2),
                .goals = paths[random.uintLessThan(usize, paths.len)],
                .speed = between(random, 0.5, 4),
                .accel = between(random, 0.5, 8),
                .decel = between(random, 0.5, 8),
            }),
            9 => try builder.chase(.{
                .target = any,
                .from = between(random, -2, 2),
                .time = seconds(random, 0.1, 1),
                .overshoot = between(random, 0, 0.6),
            }),
            10 => try builder.follow(.{
                .from = between(random, -2, 2),
                .regions = spans[random.uintLessThan(usize, spans.len)],
                .pick = random.enumValue(simulation.Pick),
                .mover = if (random.boolean())
                    .{ .spring = .{
                        .time = seconds(random, 0.1, 1),
                        .overshoot = between(random, 0, 0.6),
                    } }
                else
                    .{ .newtonian = .{
                        .speed = between(random, 0.5, 4),
                        .accel = between(random, 0.5, 8),
                        .decel = between(random, 0.5, 8),
                    } },
                .tolerance = between(random, 0.01, 0.1),
                .pause_min = .{ .flicks = 0 },
                .pause_max = seconds(random, 0, 0.3),
                .seed = random.int(u64),
            }),
            11 => blk: {
                const buckets = random.intRangeAtMost(u32, 1, 8);
                const steps = buckets * random.intRangeAtMost(i64, 1, 200);
                break :blk try builder.shift(.{
                    .buckets = buckets,
                    .period = .{ .flicks = steps * simulation.step.flicks },
                    .low = between(random, -2, 2),
                    .high = between(random, -2, 2),
                    .odds = between(random, 0, 1),
                    .shape = random.enumValue(simulation.ShiftShape),
                    .seed = random.int(u64),
                });
            },
            12 => blk: {
                const echo = try builder.delay(between(random, -2, 2));
                const before: Id = if (echo.index == 0)
                    echo
                else
                    .{ .index = random.uintLessThan(u32, echo.index) };
                try builder.close(echo, before);
                break :blk echo;
            },
            13 => blk: {
                if (builder.nodes.len - builder.node_count < 2) break :blk try builder.constant(0);
                const low = between(random, -2, 1);
                const ids = try builder.bounce(.{
                    .low = low,
                    .high = low + between(random, 0.1, 2),
                    .speed = between(random, 0.2, 3),
                    .start = cue,
                });
                break :blk ids.position;
            },
            14 => try builder.crossing(.{
                .input = any,
                .level = between(random, -1, 1),
                .direction = random.enumValue(Crossing.Direction),
            }),
            15 => try builder.cues(.{
                .first = .{ .index = 0 },
                .count = random.intRangeAtMost(u32, 1, 3),
            }),
            16 => blk: {
                if (random.boolean()) break :blk try builder.input(.{});
                const low = between(random, -2, 0);
                const high = low + between(random, 0, 3);
                break :blk try builder.input(.{ .low = low, .high = high, .initial = low });
            },
            17 => try builder.recorded(clips[random.uintLessThan(usize, clips.len)]),
            18 => try builder.track(.{ .index = random.uintLessThan(u32, 2) }),
            19 => try builder.oscillator(.{
                .shape = random.enumValue(@import("../wave.zig").Shape),
                .rate = any,
                .phase = between(random, 0, 0.99),
            }),
            20 => try builder.chase(.{
                .target = any,
                .from = between(random, -2, 2),
                .time = seconds(random, 0.1, 1),
                .overshoot = between(random, 0, 0.6),
                .time_from = from(random, other),
                .overshoot_from = from(random, other),
            }),
            21 => try builder.follow(.{
                .from = between(random, -2, 2),
                .regions = spans[random.uintLessThan(usize, spans.len)],
                .pick = random.enumValue(simulation.Pick),
                .mover = .{ .spring = .{
                    .time = seconds(random, 0.1, 1),
                    .overshoot = between(random, 0, 0.6),
                } },
                .tolerance = between(random, 0.01, 0.1),
                .pause_min = .{ .flicks = 0 },
                .pause_max = seconds(random, 0, 0.3),
                .seed = random.int(u64),
                .mover_from = .{ .time = from(random, any), .overshoot = from(random, other) },
            }),
            22 => try builder.follow(.{
                .from = between(random, -2, 2),
                .regions = spans[random.uintLessThan(usize, spans.len)],
                .pick = random.enumValue(simulation.Pick),
                .mover = .{ .newtonian = .{
                    .speed = between(random, 0.5, 4),
                    .accel = between(random, 0.5, 8),
                    .decel = between(random, 0.5, 8),
                } },
                .tolerance = between(random, 0.01, 0.1),
                .pause_min = .{ .flicks = 0 },
                .pause_max = seconds(random, 0, 0.3),
                .seed = random.int(u64),
                .mover_from = .{
                    .speed = from(random, any),
                    .accel = from(random, other),
                    .decel = from(random, any),
                },
            }),
            else => try builder.add(any, any),
        };
    }

    /// Writes each track at a drawn time in [-1 s, 4 s), past its bounds now and then, which a
    /// write clamps. A full track refuses, which changes nothing.
    fn write_tracks(drawn: *Drawn, random: std.Random) void {
        for (0..drawn.tracks.count) |index| {
            if (random.boolean()) continue;
            const track = drawn.tracks.at(.{ .index = @intCast(index) });
            const flicks = random.intRangeLessThan(i64, -flicks_per_second, 4 * flicks_per_second);
            const value = between(random, track.low - 1, track.high + 1);
            const id: TrackId = .{ .index = @intCast(index) };
            drawn.tracks.write(id, .{ .flicks = flicks }, value) catch |err| {
                assert(err == error.TrackFull);
            };
        }
    }

    /// Sets every input of `state` to a drawn value, past its range now and then.
    fn set_inputs(drawn: *const Drawn, state: *State, random: std.Random) void {
        for (drawn.program.nodes, 0..) |*node, index| switch (node.op) {
            .input => |op| {
                const low = if (std.math.isFinite(op.low)) op.low else -5;
                const high = if (std.math.isFinite(op.high)) op.high else 5;
                state.set_input(.{ .index = @intCast(index) }, between(random, low - 1, high + 1));
            },
            else => {},
        };
    }
};

fn between(random: std.Random, low: f64, high: f64) f64 {
    const weight = random.float(f64);
    return low * (1 - weight) + high * weight;
}

/// Checks that every value of every node of `state`'s last eval is in its range.
fn expect_in_ranges(state: *const State, ranges: []const Range, graph: usize, time: Time) !void {
    for (state.program.nodes, ranges, 0..) |*node, range, index| {
        for (state.values(.{ .index = @intCast(index) })) |value| {
            if (range.contains(value)) continue;
            std.debug.print("graph {d}, node {d} ({t}) at {d} flicks: {e} outside [{e}, {e}]\n", .{
                graph, index, node.op, time.flicks, value, range.low, range.high,
            });
            return error.TestUnexpectedResult;
        }
    }
}

// Locks the page's first check: in 2,000 drawn graphs over every op, each read forwards at 60 Hz,
// then backwards and at drawn times, with its inputs set to drawn values, some past their range,
// and its tracks written between reads (step 9.5), no value ever leaves its node's range.
test "no sampled value leaves its range" {
    var prng = std.Random.DefaultPrng.init(0x7a6e);
    const random = prng.random();
    var drawn: Drawn = undefined;
    var slab: [Drawn.slab_count_max]f64 = undefined;
    var checkpoints: [4 * Drawn.slab_count_max]f64 = undefined;
    var out: [Drawn.nodes_max]Range = undefined;
    const rate = Rate.from_hz(60).?;
    for (0..2000) |graph| {
        try drawn.init(random);
        const ranges = ranges_of(&drawn.program, &out);
        const used = drawn.program.slab_count;
        var state = State.init_with_checkpoints(
            drawn.program,
            slab[0..used],
            checkpoints[0 .. 4 * @as(usize, used)],
        );
        // Forwards over 4 s from just before zero, then backwards, then at drawn times.
        var tick: i64 = -6;
        while (tick < 240) : (tick += 7) {
            drawn.set_inputs(&state, random);
            drawn.write_tracks(random);
            const time = Time.from_ticks(tick, rate).?;
            state.eval(time);
            try expect_in_ranges(&state, ranges, graph, time);
        }
        for (0..12) |_| {
            drawn.set_inputs(&state, random);
            drawn.write_tracks(random);
            const flicks = random.intRangeLessThan(i64, -flicks_per_second, 4 * flicks_per_second);
            const time: Time = .{ .flicks = flicks };
            state.eval(time);
            try expect_in_ranges(&state, ranges, graph, time);
        }
    }
}

// Locks the loop half of the first check: 300 drawn loops, a chase of c + g times its own delay
// with |g| below 1 and any overshoot, read for 6 s, never leave their ranges, and when the chase
// is critical the range is finite.
test "a loop through a delay never leaves its range" {
    var prng = std.Random.DefaultPrng.init(0x100b);
    const random = prng.random();
    var times: [1]Time = undefined;
    const cues = try cue_table_at_zero(&times);
    var out: [6]Range = undefined;
    for (0..300) |graph| {
        var nodes: [6]Node = undefined;
        var builder = Builder.init(&nodes, .{ .slab_count_max = 32, .cues = &cues });
        const overshoot = if (random.boolean()) 0 else between(random, 0, 0.5);
        const echo = try builder.delay(between(random, -1, 1));
        const gain = try builder.constant(between(random, -0.95, 0.95));
        const scaled = try builder.multiply(echo, gain);
        const target = try builder.add(try builder.constant(between(random, -1, 1)), scaled);
        const chased = try builder.chase(.{
            .target = target,
            .from = between(random, -1, 1),
            .time = .{ .flicks = @intFromFloat(between(random, 0.1, 1) * flicks_per_second_float) },
            .overshoot = overshoot,
        });
        try builder.close(echo, chased);
        const program = builder.finish();
        const ranges = ranges_of(&program, &out);
        if (overshoot == 0) {
            try testing.expect(std.math.isFinite(ranges[chased.index].low));
            try testing.expect(std.math.isFinite(ranges[chased.index].high));
        }
        var slab: [32]f64 = undefined;
        var state = State.init(program, &slab);
        var tick: i64 = 0;
        while (tick < 360) : (tick += 1) {
            const time = Time.from_ticks(tick, Rate.from_hz(60).?).?;
            state.eval(time);
            try expect_in_ranges(&state, ranges, graph, time);
        }
    }
}
