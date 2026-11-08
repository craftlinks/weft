//! Tests of the graph: readers on one program, and noise.
//!
//! They read `graph.zig` and `state.zig` as a client would, plus the few internals that
//! `graph.zig` marks public for its reader and its tests.

const std = @import("std");
const motion = @import("../motion.zig");
const Noise = @import("../noise.zig").Noise;
const simulation = @import("../simulation.zig");
const time_module = @import("../time.zig");
const Time = time_module.Time;
const graph_module = @import("../graph.zig");
const testing = std.testing;
const Rate = @import("../time.zig").Rate;
const State = graph_module.State;
const tremolo_formula = @import("ops.zig").tremolo_formula;
const build_tremolo = @import("ops.zig").build_tremolo;
const carrier = @import("ops.zig").carrier;
const Builder = graph_module.Builder;
const Id = graph_module.Id;
const Node = graph_module.Node;
const Program = graph_module.Program;

const Reader = struct {
    program: Program,
    output: Id,
    /// Frames of this reader's own clock, which the other reader's does not share.
    rate: Rate,
    epoch_ticks: i64,
    mismatches: u32,

    fn run(reader: *Reader) void {
        var slab: [4]f64 = undefined;
        var state = State.init(reader.program, &slab);
        for (0..200_000) |index| {
            const tick = reader.epoch_ticks + @as(i64, @intCast(index));
            const time = Time.from_ticks(tick, reader.rate).?;
            state.eval(time);
            if (state.value(reader.output) != tremolo_formula(time)) reader.mismatches += 1;
        }
    }
};

// Locks the rule of section 1: two states on one program, at different rates and far-apart times
// on two threads, each match the formula on all 200,000 evals.
test "two states on one program never disturb each other" {
    var nodes: [4]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 4 });
    const output = try build_tremolo(&builder);
    const program = builder.finish();

    var video: Reader = .{
        .program = program,
        .output = output,
        .rate = Rate.from_hz(60).?,
        .epoch_ticks = 0,
        .mismatches = 0,
    };
    var audio: Reader = .{
        .program = program,
        .output = output,
        .rate = Rate.from_hz(48_000).?,
        .epoch_ticks = 86_400 * 48_000,
        .mismatches = 0,
    };
    const thread_video = try std.Thread.spawn(.{}, Reader.run, .{&video});
    const thread_audio = try std.Thread.spawn(.{}, Reader.run, .{&audio});
    thread_video.join();
    thread_audio.join();
    try testing.expectEqual(@as(u32, 0), video.mismatches);
    try testing.expectEqual(@as(u32, 0), audio.mismatches);
}

/// Two noises keyed 1 and 2 and summed, with `inserted` nodes built before them, including a noise
/// keyed 3. Returns the two noises.
fn build_noises(builder: *Builder, inserted: bool) Builder.Error![2]Id {
    if (inserted) {
        _ = try builder.wave(carrier);
        _ = try builder.noise(.{ .shape = .smooth, .hz = 5, .seed = 3 });
    }
    const first = try builder.noise(.{ .shape = .smooth, .hz = 0.7, .seed = 1 });
    const second = try builder.noise(.{ .shape = .steps, .hz = 4, .seed = 2 });
    _ = try builder.add(first, second);
    return .{ first, second };
}

// Locks the demo of section 7: inserting a wave and a third noise before two noises moves their
// ids but not their values, which match `Noise.derive` sample for sample; and another graph seed
// changes both.
test "inserting a node does not reshuffle the noises" {
    var nodes_plain: [3]Node = undefined;
    var builder_plain = Builder.init(&nodes_plain, .{ .slab_count_max = 3, .seed = 77 });
    const plain = try build_noises(&builder_plain, false);
    var slab_plain: [3]f64 = undefined;
    var state_plain = State.init(builder_plain.finish(), &slab_plain);

    var nodes_inserted: [5]Node = undefined;
    var builder_inserted = Builder.init(&nodes_inserted, .{ .slab_count_max = 5, .seed = 77 });
    const inserted = try build_noises(&builder_inserted, true);
    var slab_inserted: [5]f64 = undefined;
    var state_inserted = State.init(builder_inserted.finish(), &slab_inserted);
    try testing.expect(inserted[0].index != plain[0].index);

    var nodes_other: [3]Node = undefined;
    var builder_other = Builder.init(&nodes_other, .{ .slab_count_max = 3, .seed = 78 });
    const other = try build_noises(&builder_other, false);
    var slab_other: [3]f64 = undefined;
    var state_other = State.init(builder_other.finish(), &slab_other);

    const first: Noise = .{ .shape = .smooth, .hz = 0.7, .seed = 1 };
    var tick: i64 = 0;
    var differences: u32 = 0;
    while (tick < 10 * 48_000) : (tick += 997) {
        const time = Time.from_ticks(tick, Rate.from_hz(48_000).?).?;
        state_plain.eval(time);
        state_inserted.eval(time);
        state_other.eval(time);
        for (plain, inserted) |id_plain, id_inserted| {
            try testing.expectEqual(state_plain.value(id_plain), state_inserted.value(id_inserted));
        }
        try testing.expectEqual(first.derive(77).sample(time), state_plain.value(plain[0]));
        if (state_other.value(other[0]) != state_plain.value(plain[0])) differences += 1;
    }
    try testing.expect(differences > 400);
}

// Locks each refusal of `noise` by name, and the edges that are accepted: `Noise.hz_max` itself,
// and the smallest positive double.
test "the builder refuses a noise it cannot evaluate" {
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2 });
    var source: Noise = .{ .shape = .steps, .hz = std.math.nan(f64), .seed = 0 };
    try testing.expectError(error.NotFinite, builder.noise(source));
    source.hz = std.math.inf(f64);
    try testing.expectError(error.NotFinite, builder.noise(source));
    for ([_]f64{ 0, -0.0, -1, Noise.hz_max * 2 }) |hz| {
        source.hz = hz;
        try testing.expectError(error.InvalidRate, builder.noise(source));
    }
    try testing.expectEqual(@as(u32, 0), builder.node_count);
    source.hz = Noise.hz_max;
    _ = try builder.noise(source);
    source.hz = std.math.floatTrueMin(f64);
    _ = try builder.noise(source);
}

// Locks section 16 for a noise: in a region of 6 lanes, lane l is the noise whose seed is its
// node's seed hashed with l, so no two lanes are equal.
test "a noise in a lane region draws each lane from its own seed" {
    var nodes: [1]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 6 });
    builder.lanes = 6;
    const source: Noise = .{ .shape = .smooth, .hz = 2, .seed = 4 };
    const noise = try builder.noise(source);
    var slab: [6]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    const time = Time{ .flicks = 444_444_444 };
    state.eval(time);
    for (state.values(noise), 0..) |value, lane| {
        var expected = source.derive(0);
        expected.seed = graph_module.lane_seed(expected.seed, lane);
        try testing.expectEqual(expected.sample(time), value);
        for (state.values(noise)[0..lane]) |earlier| try testing.expect(earlier != value);
    }
}
