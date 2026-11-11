//! Tests of the graph: the functions of a value (steps 26 and 33, `graph.zig` section 17), `apply`
//! with each `Function`, and `minimum` and `maximum`: their values, signed zero, shapes, lanes,
//! refusals, classes, and range rules.
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
const elementary = @import("../elementary.zig");
const Cues = @import("../cue.zig").Cues;
const Time = @import("../time.zig").Time;

fn bits(value: f64) u64 {
    return @bitCast(value);
}

// Locks the values on small numbers: |-2.5| is 2.5, min(3, -1) is -1, max(3, -1) is 3, and on
// signed zero one answer either way round: |-0| is +0, min(-0, +0) and min(+0, -0) are -0, max of
// them +0, and equal inputs give that value.
test "abs, min, and max compute their values, with one answer for signed zero" {
    try testing.expectEqual(@as(f64, 2.5), Function.of(.abs, -2.5));
    try testing.expectEqual(bits(0), bits(Function.of(.abs, -0.0)));
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

/// Every function of step 33, a power of each parity among them.
const step_33_functions = [_]Function{
    .sin, .cos, .exp, .ln, .sqrt, .floor, .round, .{ .pow = 2 }, .{ .pow = 3 }, .{ .pow = 8 },
};

// Locks step 33's values through nodes: each function of a constant input is the elementary
// function's value, bit for bit, and `pow(x, 2)` is the node `x * x` builds, for x = -1.7.
test "each function of a value computes its value through a node" {
    const inputs = [_]f64{ -1.7, -0.5, -0.0, 0.5, 2.5, 1e6 };
    for (step_33_functions) |function| for (inputs) |x| {
        var nodes: [4]Node = undefined;
        var builder = Builder.init(&nodes, .{ .slab_count_max = 4 });
        const input = try builder.constant(x);
        const applied = try builder.apply(function, input);
        const product = try builder.multiply(input, input);
        var slab: [4]f64 = undefined;
        var state = State.init(builder.finish(), &slab);
        state.eval(.{ .flicks = 0 });
        try testing.expectEqual(bits(function.of(x)), bits(state.value(applied)));
        if (std.meta.eql(function, Function{ .pow = 2 })) {
            try testing.expectEqual(bits(state.value(product)), bits(state.value(applied)));
        }
    };
    try testing.expectEqual(@as(f64, -1), Function.of(.round, -0.5));
    try testing.expectEqual(@as(f64, 3), Function.of(.round, 2.5));
    try testing.expectEqual(@as(f64, -1), Function.of(.floor, -0.5));
    try testing.expectEqual(@as(f64, 0), Function.of(.sqrt, -4));
}

// Locks the power's refusal by name: 0, 1, 9, and 255 are `InvalidPower`, nothing is built, and
// 2 and 8 are taken.
test "the builder refuses a power outside 2 to 8" {
    var nodes: [4]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 4 });
    const one = try builder.constant(1);
    for ([_]u8{ 0, 1, 9, 255 }) |n| {
        try testing.expectError(error.InvalidPower, builder.apply(.{ .pow = n }, one));
    }
    try testing.expectEqual(@as(u32, 1), builder.node_count);
    _ = try builder.apply(.{ .pow = 2 }, one);
    _ = try builder.apply(.{ .pow = 8 }, one);
}

/// Input ranges for step 33's range test: inside one monotone stretch of the sine, across a peak,
/// across zero, wider than a turn, huge, at and below zero for `ln` and `sqrt`, across a half for
/// `round`, past e^709 for `exp`, and unbounded on either side or both.
const inf = std.math.inf(f64);
const wide_ranges = [_][2]f64{
    .{ 0.1, 1.2 }, .{ 1.0, 2.0 },     .{ -0.3, 0.4 },      .{ -2, 9 },         .{ 4, 4.5 },
    .{ -7, -6.5 }, .{ 1e6, 1e6 + 1 }, .{ 1e15, 1e15 + 8 }, .{ -1e300, 1e300 }, .{ -3, 0 },
    .{ -1, 1 },    .{ 0, 1e-300 },    .{ -2.5, 2.5 },      .{ 700, 720 },      .{ -800, -700 },
    .{ -inf, 2 },  .{ -0.5, inf },    .{ -inf, inf },      .{ 0.25, 0.25 },    .{ 3.14159, 3.1416 },
};

/// How many points across a range the range test reads, its ends and the turns' peaks between.
const wide_points = 513;

/// The points the range test sets an input to: evenly across a finite range, both ends, 0 where
/// it is inside, the sine's and cosine's extremes near the range, and for an unbounded end a run
/// of ever larger values out to 1e300, since an input holds finite values only.
fn wide_points_of(range: [2]f64, out: *[wide_points + 64]f64) []const f64 {
    var count: usize = 0;
    const low = if (std.math.isFinite(range[0])) range[0] else -1e300;
    const high = if (std.math.isFinite(range[1])) range[1] else 1e300;
    for (0..wide_points) |index| {
        const weight = @as(f64, @floatFromInt(index)) / (wide_points - 1);
        out[count] = if (index == wide_points - 1) high else low * (1 - weight) + high * weight;
        count += 1;
    }
    // An input holds finite values only, so an infinite end is read as 1e300 and beyond.
    out[count] = std.math.clamp(0, range[0], range[1]);
    count += 1;
    // The extremes of the sine and cosine within a few turns of the ends.
    for ([_]f64{ low, high }) |end| {
        if (@abs(end) > 1e9) continue;
        const base = @floor(end / std.math.tau) * std.math.tau;
        for (0..12) |k| {
            const x = base + @as(f64, @floatFromInt(k)) * (std.math.pi / 4.0) - std.math.tau;
            if (x >= range[0] and x <= range[1] and count < out.len) {
                out[count] = x;
                count += 1;
            }
        }
    }
    for ([_]f64{ 1e10, 1e100, 1e300 }) |far| {
        if (count + 2 > out.len) break;
        if (range[0] <= -far) {
            out[count] = -far;
            count += 1;
        }
        if (range[1] >= far) {
            out[count] = far;
            count += 1;
        }
    }
    return out[0..count];
}

/// Whether a range rule is exact, or within a margin of what it reaches.
fn exact(function: Function) bool {
    return switch (function) {
        .sqrt, .floor, .round, .pow => true,
        else => false,
    };
}

// Locks step 33's range rules (`range.zig`, section 2b) through nodes: for each function and each
// of the ranges above, an input set to each point across it never leaves the node's range (sound),
// and the least and largest values seen are its ends exactly for sqrt, floor, round, and pow, and
// within 1e-12 of its scale for the others, where the input is bounded and, for those, narrower
// than a turn. And the sine over [0.1, 1.2], inside one monotone
// stretch, stays below 1, while over [1, 2], across its peak, it reaches 1.
test "the ranges of the functions of a value are sound and tight" {
    var slab: [4]f64 = undefined;
    var buffer: [wide_points + 64]f64 = undefined;
    for (step_33_functions) |function| for (wide_ranges) |range_ends| {
        var nodes: [2]Node = undefined;
        var builder = Builder.init(&nodes, .{ .slab_count_max = 4 });
        const input = try builder.input(.{ .low = range_ends[0], .high = range_ends[1], .initial = std.math.clamp(0, range_ends[0], range_ends[1]) });
        const applied = try builder.apply(function, input);
        const program = builder.finish();
        var ranges: [2]Range = undefined;
        program.ranges(&ranges);
        const range = ranges[applied.index];
        var state = State.init(program, slab[0..program.slab_count]);
        var seen: Seen = .{};
        for (wide_points_of(range_ends, &buffer)) |x| {
            state.set_input(input, x);
            state.eval(.{ .flicks = 0 });
            const value = state.value(applied);
            errdefer std.debug.print("{any} of {e} over {any}: {e} outside [{e}, {e}]\n", .{
                function, x, range_ends, value, range.low, range.high,
            });
            try testing.expect(!std.math.isNan(value));
            try testing.expect(range.contains(value));
            seen.add(value);
        }
        errdefer std.debug.print("{any} over {any}: range [{e}, {e}], seen [{e}, {e}]\n", .{
            function, range_ends, range.low, range.high, seen.low, seen.high,
        });
        // An input cannot hold an infinity, so an unbounded range's ends cannot be reached.
        const bounded = std.math.isFinite(range_ends[0]) and std.math.isFinite(range_ends[1]);
        if (!bounded) continue;
        if (exact(function)) {
            try testing.expect(range.low == seen.low);
            try testing.expect(range.high == seen.high);
        } else if (!(range_ends[1] - range_ends[0] >= std.math.tau)) {
            // Over a turn or more, the points need not land on a peak, which a sine still has.
            const slack = 1e-12 * @max(1, @max(@abs(seen.low), @abs(seen.high)));
            try testing.expect(seen.low - range.low <= slack);
            try testing.expect(range.high - seen.high <= slack);
        }
    };
    const inside = range_module.sine(.{ .low = 0.1, .high = 1.2 });
    try testing.expect(inside.high < 0.95);
    try testing.expect(inside.low > 0.09);
    try testing.expectEqual(@as(f64, 1), range_module.sine(.{ .low = 1, .high = 2 }).high);
}

// Locks the worked ranges of `range.zig`, section 2b: pow(x, 2) over [-1, 1] is [0, 1] where
// x * x is [-1, 1]; pow(x, 3) over [-2, 1] is [-8, 1]; sqrt over [-4, 9] is [0, 3]; floor and
// round over [-0.5, 2.5] are [-1, 2] and [-1, 3]; exp and ln of an unbounded input are finite,
// [0, e^709] and [ln 2^-1074, ln of the largest double], within their margins; and sin and cos
// of a range wider than a turn, or unbounded, are [-1, 1].
test "the functions of a value have worked ranges" {
    const unit: Range = .{ .low = -1, .high = 1 };
    try testing.expectEqual(Range{ .low = 0, .high = 1 }, range_module.power(unit, 2));
    try testing.expectEqual(unit, range_module.multiply(unit, unit));
    try testing.expectEqual(Range{ .low = -8, .high = 1 }, range_module.power(.{ .low = -2, .high = 1 }, 3));
    const fns = struct {
        fn floor(x: f64) f64 {
            return @floor(x);
        }
    };
    try testing.expectEqual(Range{ .low = 0, .high = 3 }, range_module.monotone(.{ .low = -4, .high = 9 }, elementary.square_root));
    const halves: Range = .{ .low = -0.5, .high = 2.5 };
    try testing.expectEqual(Range{ .low = -1, .high = 2 }, range_module.monotone(halves, fns.floor));
    try testing.expectEqual(Range{ .low = -1, .high = 3 }, range_module.monotone(halves, elementary.round_half_away));
    const exp_all = range_module.exponential(Range.unbounded);
    try testing.expectEqual(@as(f64, 0), exp_all.low);
    try testing.expectApproxEqRel(elementary.exponential(709), exp_all.high, 1e-14);
    const ln_all = range_module.logarithm(Range.unbounded);
    try testing.expectApproxEqRel(@as(f64, -744.4400719213812), ln_all.low, 1e-14);
    try testing.expectApproxEqRel(@as(f64, 709.782712893384), ln_all.high, 1e-14);
    try testing.expectEqual(unit, range_module.sine(.{ .low = 0, .high = 7 }));
    try testing.expectEqual(unit, range_module.cosine(Range.unbounded));
    try testing.expectEqual(unit, range_module.sine(.{ .low = -inf, .high = 0 }));
}

// Locks the class of section 17: a function of a value has its input's class, so floor of a wave
// is pure and its program seekable with no steps, and floor of a chase is simulated.
test "a function of a value has its input's class" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    _ = try cues.add(.{ .flicks = 0 });
    var nodes: [4]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 16, .cues = &cues });
    const wave = try builder.wave(.{ .shape = .sine, .hz = 1 });
    const stepped = try builder.apply(.floor, wave);
    const chased = try builder.chase(.{ .target = wave, .from = 0, .time = .{ .flicks = 705_600_000 }, .overshoot = 0 });
    const chase_floor = try builder.apply(.round, chased);
    const program = builder.finish();
    var classes: [4]graph_module.Class = undefined;
    program.classes(&classes);
    try testing.expectEqual(graph_module.Class.pure, classes[stepped.index]);
    try testing.expectEqual(graph_module.Class.simulated, classes[chase_floor.index]);
}
