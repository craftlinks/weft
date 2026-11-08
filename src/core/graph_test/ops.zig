//! Tests of the graph: the ops, the builder's refusals, memory, and extents.
//!
//! They read `graph.zig` and `state.zig` as a client would, plus the few internals that
//! `graph.zig` marks public for its reader and its tests.

const std = @import("std");
const Cues = @import("../cue.zig").Cues;
const motion = @import("../motion.zig");
const simulation = @import("../simulation.zig");
const time_module = @import("../time.zig");
const Time = time_module.Time;
const track_module = @import("../track.zig");
const Tracks = track_module.Tracks;
const wave_module = @import("../wave.zig");
const Wave = wave_module.Wave;
const graph_module = @import("../graph.zig");
const testing = std.testing;
const Rate = @import("../time.zig").Rate;
const State = graph_module.State;
const Builder = graph_module.Builder;
const Id = graph_module.Id;
const MapRange = graph_module.MapRange;
const Node = graph_module.Node;
const Program = graph_module.Program;

pub const carrier = Wave{ .shape = .sine, .hz = 440 };
pub const swell = Wave{ .shape = .triangle, .hz = 0.7 };

/// A wave of 440 Hz scaled by a slower wave moved into [0.25, 1], returning the output node.
pub fn build_tremolo(builder: *Builder) Builder.Error!Id {
    const fast = try builder.wave(carrier);
    const slow = try builder.wave(swell);
    const depth = try builder.map_range(.{
        .input = slow,
        .input_low = -1,
        .input_high = 1,
        .output_low = 0.25,
        .output_high = 1,
    });
    return builder.multiply(fast, depth);
}

/// The same signal as `build_tremolo`, by hand.
pub fn tremolo_formula(time: Time) f64 {
    const position = (swell.sample(time) + 1) / 2;
    return carrier.sample(time) * (0.25 * (1 - position) + 1 * position);
}

// Locks the demo of this step: a wave scaled by a slower wave equals its formula bit for bit, over
// four seconds of 48 kHz ticks stepped by 1009, and at its worked start: sine(0) is 0, so the
// output at time zero is 0, while the depth is 0.625, halfway through the map.
test "a wave scaled by a slower wave matches its formula" {
    var nodes: [4]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 4 });
    const output = try build_tremolo(&builder);
    var slab: [4]f64 = undefined;
    var state = State.init(builder.finish(), &slab);

    state.eval(.{ .flicks = 0 });
    try testing.expectEqual(@as(f64, 0), state.value(output));
    try testing.expectEqual(@as(f64, 0.625), state.value(.{ .index = 2 }));

    const rate = Rate.from_hz(48_000).?;
    var tick: i64 = 0;
    while (tick < 4 * 48_000) : (tick += 1009) {
        const time = Time.from_ticks(tick, rate).?;
        state.eval(time);
        try testing.expectEqual(tremolo_formula(time), state.value(output));
    }
}

// Locks each op on small numbers: 3 + 4 = 7, 7 * 2 = 14, and 14 moved from [10, 20] to [0, -1],
// a reversed output, is -0.4.
test "each op computes its value" {
    var nodes: [6]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 6 });
    const three = try builder.constant(3);
    const four = try builder.constant(4);
    const seven = try builder.add(three, four);
    const two = try builder.constant(2);
    const fourteen = try builder.multiply(seven, two);
    const mapped = try builder.map_range(.{
        .input = fourteen,
        .input_low = 10,
        .input_high = 20,
        .output_low = 0,
        .output_high = -1,
    });
    var slab: [6]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqual(@as(f64, 7), state.value(seven));
    try testing.expectEqual(@as(f64, 14), state.value(fourteen));
    try testing.expectApproxEqAbs(@as(f64, -0.4), state.value(mapped), 1e-15);
}

// Locks the promise of `MapRange` on an output of [-0.3, 0.9], where `low + 1 * (high - low)` gives
// 0.8999999999999999: both ends land exactly, and an input outside the range is not clamped.
test "a map lands exactly on its ends and does not clamp" {
    var nodes: [6]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 6 });
    const map: MapRange = .{
        .input = undefined,
        .input_low = 0.1,
        .input_high = 0.7,
        .output_low = -0.3,
        .output_high = 0.9,
    };
    const inputs = [_]f64{ 0.1, 0.7, 1.3 };
    var outputs: [inputs.len]Id = undefined;
    for (inputs, &outputs) |input, *output| {
        var map_input = map;
        map_input.input = try builder.constant(input);
        output.* = try builder.map_range(map_input);
    }
    var slab: [6]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqual(@as(f64, -0.3), state.value(outputs[0]));
    try testing.expectEqual(@as(f64, 0.9), state.value(outputs[1]));
    try testing.expectApproxEqAbs(@as(f64, 2.1), state.value(outputs[2]), 1e-15);
}

// Locks each capacity refusal by name, at exactly one past the limit, and that a refused node
// leaves the builder as it was: the same counts, and a smaller node still fits.
test "the builder refuses a capacity overflow by name" {
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 8 });
    _ = try builder.constant(1);
    _ = try builder.constant(2);
    try testing.expectError(error.NodeCapacityExceeded, builder.constant(3));
    try testing.expectEqual(@as(u32, 2), builder.node_count);
    try testing.expectEqual(@as(u32, 2), builder.slab_count);

    builder = Builder.init(&nodes, .{ .slab_count_max = 5 });
    builder.extent = .{ .lanes = 3, .components = 2 };
    try testing.expectError(error.SlabCapacityExceeded, builder.constant(1));
    try testing.expectEqual(@as(u32, 0), builder.node_count);
    try testing.expectEqual(@as(u32, 0), builder.slab_count);
    builder.extent = .{ .lanes = 5, .components = 1 };
    _ = try builder.constant(1);
    try testing.expectEqual(@as(u32, 5), builder.slab_count);
    builder.extent = .{ .lanes = std.math.maxInt(u32), .components = std.math.maxInt(u32) };
    try testing.expectError(error.SlabCapacityExceeded, builder.constant(1));
}

// Locks that a cycle cannot be expressed: the only id a node could use to reach itself or a later
// node is one that does not exist yet.
test "a node cannot refer to itself or to a later node" {
    var nodes: [3]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 3 });
    const first = try builder.constant(1);
    const next: Id = .{ .index = 1 };
    try testing.expectError(error.UnknownNode, builder.add(first, next));
    try testing.expectError(error.UnknownNode, builder.multiply(next, first));
    const map: MapRange = .{
        .input = next,
        .input_low = 0,
        .input_high = 1,
        .output_low = 0,
        .output_high = 1,
    };
    try testing.expectError(error.UnknownNode, builder.map_range(map));
    try testing.expectEqual(@as(u32, 1), builder.node_count);
}

// Locks the refusal of values that `eval` could not use, and that a reversed input range is fine.
test "the builder refuses parameters it cannot evaluate" {
    var nodes: [3]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 3 });
    const inf = std.math.inf(f64);
    const nan = std.math.nan(f64);
    try testing.expectError(error.NotFinite, builder.constant(nan));
    try testing.expectError(error.NotFinite, builder.constant(inf));
    try testing.expectError(error.NotFinite, builder.wave(.{ .shape = .saw, .hz = nan }));

    const input = try builder.constant(0.5);
    var map: MapRange = .{
        .input = input,
        .input_low = 1,
        .input_high = 1,
        .output_low = 0,
        .output_high = 1,
    };
    try testing.expectError(error.InvalidRange, builder.map_range(map));
    map.input_low = -std.math.floatMax(f64);
    map.input_high = std.math.floatMax(f64);
    try testing.expectError(error.InvalidRange, builder.map_range(map));
    map.input_low = 2;
    map.input_high = 0;
    map.output_high = inf;
    try testing.expectError(error.NotFinite, builder.map_range(map));
    map.output_high = 1;
    _ = try builder.map_range(map);
}

// Locks the rule of section 3. The node array and a slab are copied as bytes, the originals are
// overwritten, and the copies give the same bits: the moved program evaluates, and the moved slab
// reads back as a checkpoint without another eval.
test "moving the memory changes nothing" {
    var nodes: [4]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 4 });
    const output = try build_tremolo(&builder);
    const program = builder.finish();
    var slab: [4]f64 = undefined;
    var state = State.init(program, &slab);
    const time = Time{ .flicks = 1_234_567_890 };
    state.eval(time);
    const expected = state.value(output);

    var nodes_moved: [4]Node = undefined;
    var slab_moved: [4]f64 = undefined;
    @memcpy(std.mem.asBytes(&nodes_moved), std.mem.asBytes(&nodes));
    @memcpy(std.mem.asBytes(&slab_moved), std.mem.asBytes(&slab));
    @memset(std.mem.asBytes(&nodes), 0xaa);
    @memset(std.mem.asBytes(&slab), 0xaa);

    const program_moved: Program = .{
        .nodes = &nodes_moved,
        .cues = &Cues.empty,
        .goals = &.{},
        .regions = &.{},
        .samples = &.{},
        .tracks = &Tracks.empty,
        .start = .{ .index = 0 },
        .simulated = false,
        .slab_count = program.slab_count,
    };
    var state_checkpoint: State = .{
        .program = program_moved,
        .slab = &slab_moved,
        .evaluated = true,
        .checkpoints = &.{},
        .checkpoints_filled = 0,
        .step = null,
        .generation = 0,
        .track_generation = 0,
        .steps_run = 0,
        .recordings = undefined,
        .recordings_count = 0,
    };
    try testing.expectEqual(expected, state_checkpoint.value(output));

    var slab_fresh: [4]f64 = undefined;
    var state_fresh = State.init(program_moved, &slab_fresh);
    state_fresh.eval(time);
    try testing.expectEqual(expected, state_fresh.value(output));
    state_checkpoint.eval(.{ .flicks = 0 });
    try testing.expectEqual(@as(f64, 0), state_checkpoint.value(output));
}

// Locks that a slab holds no history: an eval at a time gives the same bits whatever was evaluated
// before it, including a jump backwards.
test "eval depends only on the time" {
    var nodes: [4]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 4 });
    const output = try build_tremolo(&builder);
    var slab: [4]f64 = undefined;
    var state = State.init(builder.finish(), &slab);

    const time = Time{ .flicks = 987_654_321 };
    state.eval(time);
    const expected = state.value(output);
    state.eval(.{ .flicks = time.flicks * 3 });
    state.eval(.{ .flicks = -time.flicks });
    state.eval(time);
    try testing.expectEqual(expected, state.value(output));
}

// Locks the layout of section 2 with lanes and components above 1, which every op must loop over.
// 3 lanes of 2 components is 6 f64 per node, at offsets 0, 6, 12, 18, and 24, and a thousand 2D
// values is 2,000 f64 at one offset.
test "each op loops over the extent of its node" {
    var nodes: [5]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 30 });
    builder.extent = .{ .lanes = 3, .components = 2 };
    const two = try builder.constant(2);
    const three = try builder.constant(3);
    const sum = try builder.add(two, three);
    const product = try builder.multiply(sum, three);
    const mapped = try builder.map_range(.{
        .input = product,
        .input_low = 0,
        .input_high = 30,
        .output_low = 0,
        .output_high = 1,
    });
    const program = builder.finish();
    try testing.expectEqual(@as(u32, 30), program.slab_count);
    try testing.expectEqual(@as(u32, 24), program.nodes[mapped.index].offset);

    var slab: [30]f64 = undefined;
    var state = State.init(program, &slab);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqualSlices(f64, &@as([6]f64, @splat(5)), state.values(sum));
    try testing.expectEqualSlices(f64, &@as([6]f64, @splat(15)), state.values(product));
    try testing.expectEqualSlices(f64, &@as([6]f64, @splat(0.5)), state.values(mapped));

    var nodes_many: [2]Node = undefined;
    var builder_many = Builder.init(&nodes_many, .{ .slab_count_max = 4000 });
    builder_many.extent = .{ .lanes = 1000, .components = 2 };
    _ = try builder_many.wave(carrier);
    const second = try builder_many.wave(swell);
    try testing.expectEqual(@as(u32, 2000), builder_many.nodes[second.index].offset);
    try testing.expectEqual(@as(u32, 4000), builder_many.finish().slab_count);
}

// Locks the smallest program: no nodes, an empty slab, and an eval that does nothing.
test "an empty program evaluates" {
    var builder = Builder.init(&.{}, .{ .slab_count_max = 0 });
    var state = State.init(builder.finish(), &.{});
    state.eval(.{ .flicks = 0 });
    try testing.expectEqual(@as(usize, 0), state.slab.len);
}
