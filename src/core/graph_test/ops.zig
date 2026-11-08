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
    builder.lanes = 6;
    try testing.expectError(error.SlabCapacityExceeded, builder.lane());
    try testing.expectEqual(@as(u32, 0), builder.node_count);
    try testing.expectEqual(@as(u32, 0), builder.slab_count);
    builder.lanes = 5;
    _ = try builder.lane();
    try testing.expectEqual(@as(u32, 5), builder.slab_count);
    builder.lanes = graph_module.lanes_max;
    try testing.expectError(error.SlabCapacityExceeded, builder.lane());
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

// Locks the layout of sections 2 and 16 with lanes above 1, which every op must loop over: 6
// lanes of `lane` at 0, two constants of one lane at 6 and 7, then 6 lanes a node at 8, 14, and
// 20, each a lane's own value with the constants broadcast. A thousand 2D values, a pack of two
// scalars over a thousand lanes, is 2,000 f64 at one offset.
test "each op loops over the extent of its node" {
    var nodes: [6]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 26 });
    builder.lanes = 6;
    const index = try builder.lane();
    const two = try builder.constant(2);
    const three = try builder.constant(3);
    builder.lanes = null;
    const sum = try builder.add(index, two);
    const product = try builder.multiply(three, sum);
    const mapped = try builder.map_range(.{
        .input = product,
        .input_low = 0,
        .input_high = 30,
        .output_low = 0,
        .output_high = 1,
    });
    const program = builder.finish();
    try testing.expectEqual(@as(u32, 26), program.slab_count);
    try testing.expectEqual(@as(u32, 7), program.nodes[three.index].offset);
    try testing.expectEqual(@as(u32, 20), program.nodes[mapped.index].offset);

    var slab: [26]f64 = undefined;
    var state = State.init(program, &slab);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqualSlices(f64, &.{ 2, 3, 4, 5, 6, 7 }, state.values(sum));
    try testing.expectEqualSlices(f64, &.{ 6, 9, 12, 15, 18, 21 }, state.values(product));
    try testing.expectEqualSlices(f64, &.{ 0.2, 0.3, 0.4, 0.5, 0.6, 0.7 }, state.values(mapped));

    var nodes_many: [3]Node = undefined;
    var builder_many = Builder.init(&nodes_many, .{ .slab_count_max = 4000 });
    builder_many.lanes = 1000;
    const first = try builder_many.lane();
    const second = try builder_many.noise(.{ .shape = .smooth, .hz = 1, .seed = 2 });
    const both = try builder_many.pack(&.{ first, second });
    try testing.expectEqual(@as(u32, 2000), builder_many.nodes[both.index].offset);
    try testing.expectEqual(@as(u32, 4000), builder_many.finish().slab_count);
}

// Locks the smallest program: no nodes, an empty slab, and an eval that does nothing.
test "an empty program evaluates" {
    var builder = Builder.init(&.{}, .{ .slab_count_max = 0 });
    var state = State.init(builder.finish(), &.{});
    state.eval(.{ .flicks = 0 });
    try testing.expectEqual(@as(usize, 0), state.slab.len);
}

// Locks section 15: a pack of three scalars, a pick of each component, a vector plus a vector,
// a vector times a scalar broadcast, a map per component, and the ranges of a pack and a pick.
test "pack, pick, and arithmetic per component" {
    var nodes: [12]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 32 });
    const one = try builder.constant(1);
    const two = try builder.constant(2);
    const three = try builder.constant(3);
    const vector = try builder.pack(&.{ one, two, three });
    const doubled = try builder.multiply(vector, two);
    const sum = try builder.add(vector, doubled);
    const mapped = try builder.map_range(.{ .input = sum, .input_low = 0, .input_high = 9, .output_low = 0, .output_high = 1 });
    const middle = try builder.pick(sum, 1);
    const scalar_sum = try builder.add(middle, one);
    const program = builder.finish();
    try testing.expectEqual(@as(u32, 3), program.nodes[vector.index].extent.components);
    try testing.expectEqual(@as(u32, 3), program.nodes[doubled.index].extent.components);
    try testing.expectEqual(@as(u32, 1), program.nodes[middle.index].extent.components);
    var slab: [32]f64 = undefined;
    var state = State.init(program, &slab);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqualSlices(f64, &.{ 1, 2, 3 }, state.values(vector));
    try testing.expectEqualSlices(f64, &.{ 2, 4, 6 }, state.values(doubled));
    try testing.expectEqualSlices(f64, &.{ 3, 6, 9 }, state.values(sum));
    try testing.expectEqualSlices(f64, &.{ 3.0 / 9.0, 6.0 / 9.0, 1 }, state.values(mapped));
    try testing.expectEqual(@as(f64, 6), state.value(middle));
    try testing.expectEqual(@as(f64, 7), state.value(scalar_sum));
    var ranges: [12]graph_module.Range = undefined;
    program.ranges(ranges[0..program.nodes.len]);
    try testing.expectEqual(graph_module.Range{ .low = 1, .high = 3 }, ranges[vector.index]);
    const picked = try builder_pick_of_pack();
    try testing.expectEqual(graph_module.Range{ .low = 2, .high = 2 }, picked);
}

/// The range of a pick of a pack's second input: that input's own, not the pack's hull.
fn builder_pick_of_pack() !graph_module.Range {
    var nodes: [4]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 8 });
    const one = try builder.constant(1);
    const two = try builder.constant(2);
    const both = try builder.pack(&.{ one, two });
    _ = try builder.pick(both, 1);
    const program = builder.finish();
    var ranges: [4]graph_module.Range = undefined;
    program.ranges(&ranges);
    return ranges[3];
}

// Locks section 15's refusals: two vectors of different sizes, a vector where an op reads one
// value, a pack of one or of five, a pack of a vector, and a component past the end.
test "the builder refuses a shape that does not fit" {
    var nodes: [8]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 32 });
    const one = try builder.constant(1);
    const two = try builder.pack(&.{ one, one });
    const three = try builder.pack(&.{ one, one, one });
    try testing.expectError(error.ShapeMismatch, builder.add(two, three));
    try testing.expectError(error.ShapeMismatch, builder.multiply(three, two));
    try testing.expectError(error.ShapeMismatch, builder.pack(&.{one}));
    try testing.expectError(error.ShapeMismatch, builder.pack(&.{ one, one, one, one, one }));
    try testing.expectError(error.ShapeMismatch, builder.pack(&.{ one, two }));
    try testing.expectError(error.ShapeMismatch, builder.pick(two, 2));
    try testing.expectError(error.ShapeMismatch, builder.chase(.{ .target = two, .from = 0, .time = .{ .flicks = 705_600_000 }, .overshoot = 0 }));
}
