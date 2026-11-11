//! Tests of the graph: the functions of a value (step 26, `graph.zig` section 17), `apply` with
//! `abs`, and `minimum` and `maximum`: their values, signed zero, shapes, lanes, refusals, and
//! range rules.
//!
//! They read `graph.zig`, `state.zig`, and `range.zig` as a client would.

const std = @import("std");
const testing = std.testing;
const graph_module = @import("../graph.zig");
const range_module = @import("../range.zig");
const Range = range_module.Range;
const State = graph_module.State;
const Builder = graph_module.Builder;
const Function = graph_module.Function;
const Id = graph_module.Id;
const Node = graph_module.Node;
const Program = graph_module.Program;

fn bits(value: f64) u64 {
    return @bitCast(value);
}

// Locks the values on small numbers: |-2.5| is 2.5, min(3, -1) is -1, max(3, -1) is 3, and on
// signed zero one answer either way round: |-0| is +0, min(-0, +0) and min(+0, -0) are -0, max of
// them +0, and equal inputs give that value.
test "abs, min, and max compute their values, with one answer for signed zero" {
    try testing.expectEqual(@as(f64, 2.5), Function.abs.of(-2.5));
    try testing.expectEqual(bits(0), bits(Function.abs.of(-0.0)));
    try testing.expectEqual(@as(f64, -1), graph_module.minimum(3, -1));
    try testing.expectEqual(@as(f64, 3), graph_module.maximum(3, -1));
    const zero = bits(0.0);
    const negative_zero = bits(-0.0);
    try testing.expectEqual(negative_zero, bits(graph_module.minimum(-0.0, 0.0)));
    try testing.expectEqual(negative_zero, bits(graph_module.minimum(0.0, -0.0)));
    try testing.expectEqual(zero, bits(graph_module.maximum(-0.0, 0.0)));
    try testing.expectEqual(zero, bits(graph_module.maximum(0.0, -0.0)));
    try testing.expectEqual(negative_zero, bits(graph_module.maximum(-0.0, -0.0)));
    try testing.expectEqual(zero, bits(graph_module.minimum(0.0, 0.0)));
    try testing.expectEqual(@as(f64, 0.75), graph_module.minimum(0.75, 0.75));

    // The same answers from nodes, through a pass.
    var nodes: [8]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 8 });
    const minus_zero = try builder.constant(-0.0);
    const plus_zero = try builder.constant(0.0);
    const low = try builder.minimum(plus_zero, minus_zero);
    const high = try builder.maximum(minus_zero, plus_zero);
    const absolute = try builder.apply(.abs, minus_zero);
    const three = try builder.constant(3);
    const below = try builder.minimum(three, try builder.constant(-1));
    var slab: [8]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqual(negative_zero, bits(state.value(low)));
    try testing.expectEqual(zero, bits(state.value(high)));
    try testing.expectEqual(zero, bits(state.value(absolute)));
    try testing.expectEqual(@as(f64, -1), state.value(below));
}

// Locks section 17's shapes and lanes: abs of the vector (-1, 2) is (1, 2); min and max of it
// with the scalar 0.5 broadcast are (-1, 0.5) and (0.5, 2); and over four lanes of `lane`,
// |lane - 1.5| is 1.5, 0.5, 0.5, 1.5, and max with a one-lane 1 is 1, 1, 2, 3.
test "abs, min, and max work per component and per lane, a scalar broadcast" {
    var nodes: [16]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 64 });
    const vector = try builder.pack(&.{ try builder.constant(-1), try builder.constant(2) });
    const half = try builder.constant(0.5);
    const absolute = try builder.apply(.abs, vector);
    const low = try builder.minimum(vector, half);
    const high = try builder.maximum(half, vector);
    builder.lanes = 4;
    const index = try builder.lane();
    builder.lanes = null;
    const centred = try builder.add(index, try builder.constant(-1.5));
    const distance = try builder.apply(.abs, centred);
    const floor = try builder.maximum(index, try builder.constant(1));
    var slab: [64]f64 = undefined;
    const program = builder.finish();
    var state = State.init(program, slab[0..program.slab_count]);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqualSlices(f64, &.{ 1, 2 }, state.values(absolute));
    try testing.expectEqualSlices(f64, &.{ -1, 0.5 }, state.values(low));
    try testing.expectEqualSlices(f64, &.{ 0.5, 2 }, state.values(high));
    try testing.expectEqualSlices(f64, &.{ 1.5, 0.5, 0.5, 1.5 }, state.values(distance));
    try testing.expectEqualSlices(f64, &.{ 1, 1, 2, 3 }, state.values(floor));
    try testing.expectEqual(@as(u32, 2), state.extent(absolute).components);
    try testing.expectEqual(@as(u32, 4), state.extent(distance).lanes);
    try testing.expect(state.extent(distance).laned);
}

// Locks the refusals by name, each leaving the builder as it was: a node not built yet, a vec2
// with a vec3, and three lanes with four.
test "the builder refuses abs, min, and max of what does not fit" {
    var nodes: [16]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 64 });
    const one = try builder.constant(1);
    const unknown: Id = .{ .index = 9 };
    try testing.expectError(error.UnknownNode, builder.apply(.abs, unknown));
    try testing.expectError(error.UnknownNode, builder.minimum(one, unknown));
    try testing.expectError(error.UnknownNode, builder.maximum(unknown, one));
    const pair = try builder.pack(&.{ one, one });
    const triple = try builder.pack(&.{ one, one, one });
    try testing.expectError(error.ShapeMismatch, builder.minimum(pair, triple));
    try testing.expectError(error.ShapeMismatch, builder.maximum(triple, pair));
    builder.lanes = 3;
    const three = try builder.lane();
    builder.lanes = 4;
    const four = try builder.lane();
    builder.lanes = null;
    const count = builder.node_count;
    const slab_count = builder.slab_count;
    try testing.expectError(error.LaneMismatch, builder.minimum(three, four));
    try testing.expectError(error.LaneMismatch, builder.maximum(four, three));
    try testing.expectEqual(count, builder.node_count);
    try testing.expectEqual(slab_count, builder.slab_count);
}

/// The end ranges the range tests draw inputs from: across zero, at or above it, at or below it,
/// touching it at either end, a point, and a signed zero.
const input_ranges = [_][2]f64{
    .{ -3, 2 },      .{ -0.25, 0.75 }, .{ 0.5, 4 },    .{ -4, -0.5 },
    .{ 0, 1.5 },     .{ -1.5, 0 },     .{ -2, -2 },    .{ 0.125, 0.125 },
    .{ -0.0, 0.25 }, .{ -1, -0.0 },    .{ -0.0, 0.0 }, .{ -7.5, 7.5 },
};

/// Points across `[low, high]`, both ends and 0 included where it is inside.
const points_per_input = 17;

fn points(range: [2]f64) [points_per_input + 1]f64 {
    var result: [points_per_input + 1]f64 = undefined;
    for (result[0..points_per_input], 0..) |*point, index| {
        const weight = @as(f64, @floatFromInt(index)) / (points_per_input - 1);
        point.* = if (index == points_per_input - 1) range[1] else range[0] * (1 - weight) + range[1] * weight;
    }
    result[points_per_input] = std.math.clamp(0, range[0], range[1]);
    return result;
}

/// A program of two inputs and the three ops, and its ranges.
const Inputs = struct {
    nodes: [5]Node,
    program: Program,
    ranges: [5]Range,

    const a: Id = .{ .index = 0 };
    const b: Id = .{ .index = 1 };
    const absolute: Id = .{ .index = 2 };
    const low: Id = .{ .index = 3 };
    const high: Id = .{ .index = 4 };

    fn init(inputs: *Inputs, range_a: [2]f64, range_b: [2]f64) !void {
        var builder = Builder.init(&inputs.nodes, .{ .slab_count_max = 8 });
        const first = try builder.input(.{ .low = range_a[0], .high = range_a[1], .initial = range_a[0] });
        const second = try builder.input(.{ .low = range_b[0], .high = range_b[1], .initial = range_b[0] });
        try testing.expectEqual(a, first);
        try testing.expectEqual(b, second);
        try testing.expectEqual(absolute, try builder.apply(.abs, first));
        try testing.expectEqual(low, try builder.minimum(first, second));
        try testing.expectEqual(high, try builder.maximum(first, second));
        inputs.program = builder.finish();
        inputs.program.ranges(&inputs.ranges);
    }
};

/// The least and largest values seen of a node.
const Seen = struct {
    low: f64 = std.math.inf(f64),
    high: f64 = -std.math.inf(f64),

    fn add(seen: *Seen, value: f64) void {
        seen.low = @min(seen.low, value);
        seen.high = @max(seen.high, value);
    }
};

// Locks the range rules of `range.zig`, section 2a, through nodes: for every pair of the input
// ranges above, two inputs set to every pair of points across them, each op's value is inside its
// node's range at every point (sound), and its least and largest values are the range's ends,
// equal as numbers (exact). So |[-3, 2]| is [0, 3], min of [-3, 2] and [0.5, 4] is [-3, 2], and
// max of them is [0.5, 4], each end reached.
test "the ranges of abs, min, and max are sound and exact" {
    var inputs: Inputs = undefined;
    var slab: [8]f64 = undefined;
    for (input_ranges) |range_a| for (input_ranges) |range_b| {
        try inputs.init(range_a, range_b);
        var state = State.init(inputs.program, slab[0..inputs.program.slab_count]);
        var seen: [3]Seen = .{ .{}, .{}, .{} };
        for (points(range_a)) |x| for (points(range_b)) |y| {
            state.set_input(Inputs.a, x);
            state.set_input(Inputs.b, y);
            state.eval(.{ .flicks = 0 });
            for ([_]Id{ Inputs.absolute, Inputs.low, Inputs.high }, &seen) |id, *each| {
                const value = state.value(id);
                errdefer std.debug.print("node {d} at ({e}, {e}): {e} outside [{e}, {e}]\n", .{
                    id.index, x, y, value, inputs.ranges[id.index].low, inputs.ranges[id.index].high,
                });
                try testing.expect(inputs.ranges[id.index].contains(value));
                each.add(value);
            }
        };
        for ([_]Id{ Inputs.absolute, Inputs.low, Inputs.high }, seen) |id, each| {
            errdefer std.debug.print("node {d} over {any} and {any}\n", .{ id.index, range_a, range_b });
            try testing.expect(inputs.ranges[id.index].low == each.low);
            try testing.expect(inputs.ranges[id.index].high == each.high);
        }
    };
    try inputs.init(.{ -3, 2 }, .{ 0.5, 4 });
    try testing.expectEqual(Range{ .low = 0, .high = 3 }, inputs.ranges[Inputs.absolute.index]);
    try testing.expectEqual(Range{ .low = -3, .high = 2 }, inputs.ranges[Inputs.low.index]);
    try testing.expectEqual(Range{ .low = 0.5, .high = 4 }, inputs.ranges[Inputs.high.index]);
}

// Locks that a clamp built as min(max(x, low), high) has the exact range of its composition: a
// wave times 3 clamped to [-1, 0.25] is [-1, 0.25], and reaches both over a cycle; clamped to
// [-5, 5], wider than the wave, it is the wave's own [-3, 3].
test "a clamp composed of max and min has an exact range" {
    var nodes: [12]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 12 });
    const wave = try builder.wave(.{ .shape = .triangle, .hz = 1 });
    const loud = try builder.multiply(wave, try builder.constant(3));
    const tight = try builder.minimum(try builder.maximum(loud, try builder.constant(-1)), try builder.constant(0.25));
    const loose = try builder.minimum(try builder.maximum(loud, try builder.constant(-5)), try builder.constant(5));
    const program = builder.finish();
    var ranges: [12]Range = undefined;
    program.ranges(&ranges);
    try testing.expectEqual(Range{ .low = -1, .high = 0.25 }, ranges[tight.index]);
    try testing.expectEqual(Range{ .low = -3, .high = 3 }, ranges[loose.index]);
    var slab: [12]f64 = undefined;
    var state = State.init(program, slab[0..program.slab_count]);
    var seen: [2]Seen = .{ .{}, .{} };
    // A triangle at 1 Hz peaks at a quarter and bottoms at three quarters of a second.
    for (0..65) |step| {
        state.eval(.{ .flicks = @intCast(step * @divExact(705_600_000, 64)) });
        seen[0].add(state.value(tight));
        seen[1].add(state.value(loose));
    }
    try testing.expectEqual(@as(f64, -1), seen[0].low);
    try testing.expectEqual(@as(f64, 0.25), seen[0].high);
    try testing.expectEqual(@as(f64, -3), seen[1].low);
    try testing.expectEqual(@as(f64, 3), seen[1].high);
}
