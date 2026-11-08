//! Tests of the graph: tweens and cues.
//!
//! They read `graph.zig` and `state.zig` as a client would, plus the few internals that
//! `graph.zig` marks public for its reader and its tests.

const std = @import("std");
const Cue = @import("../cue.zig").Cue;
const Cues = @import("../cue.zig").Cues;
const Ease = @import("../ease.zig").Ease;
const motion = @import("../motion.zig");
const simulation = @import("../simulation.zig");
const time_module = @import("../time.zig");
const Time = time_module.Time;
const graph_module = @import("../graph.zig");
const testing = std.testing;
const State = graph_module.State;
const swell = @import("ops.zig").swell;
const Builder = graph_module.Builder;
const Node = graph_module.Node;
const Tween = graph_module.Tween;

/// One tween of 1.5 s starting at `cue`, over a table the test owns.
pub fn tween_of(from: f64, to: f64, cue: Cue, ease: Ease) Tween {
    return .{
        .from = from,
        .to = to,
        .duration = .{ .flicks = 3 * 352_800_000 },
        .ease = ease,
        .start = cue,
        .previous = null,
    };
}

// Locks the demo of this step for 0.1 to 0.3, neither an exact f64, and for -0, whose sign only
// survives if the end value is returned and not computed: before and at the cue is `from`, and at
// the last flick's end and an hour later is `to`, bit for bit.
test "a tween ends on its target value, bit for bit" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 705_600_000 });

    for ([_]f64{ 0.3, -0.0 }) |target| {
        var nodes: [1]Node = undefined;
        var builder = Builder.init(&nodes, .{ .slab_count_max = 1, .cues = &cues });
        const tween = try builder.tween(tween_of(0.1, target, cue, .in_out));
        var slab: [1]f64 = undefined;
        var state = State.init(builder.finish(), &slab);
        const end = cues.at(cue).flicks + 3 * 352_800_000;

        state.eval(.{ .flicks = 0 });
        try testing.expectEqual(@as(f64, 0.1), state.value(tween));
        state.eval(cues.at(cue));
        try testing.expectEqual(@as(f64, 0.1), state.value(tween));
        state.eval(.{ .flicks = end - 1 });
        try testing.expect(state.value(tween) != target);
        for ([_]i64{ end, end + 3600 * 705_600_000 }) |flicks| {
            state.eval(.{ .flicks = flicks });
            const bits: u64 = @bitCast(state.value(tween));
            try testing.expectEqual(@as(u64, @bitCast(target)), bits);
        }
    }
}

// Locks the worked middle of a tween from 10 to 20: halfway through, in-out has an eased progress
// of exactly a half, so the value is 15, and `in` at a half gives 10 + 10 * 0.3153568.
test "a tween follows its ease" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 0 });
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = &cues });
    const symmetric = try builder.tween(tween_of(10, 20, cue, .in_out));
    const slow_start = try builder.tween(tween_of(10, 20, cue, .in));
    var slab: [2]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    state.eval(.{ .flicks = 3 * 176_400_000 });
    try testing.expectApproxEqAbs(@as(f64, 15), state.value(symmetric), 1e-13);
    try testing.expectApproxEqAbs(@as(f64, 13.153568125725393), state.value(slow_start), 1e-13);
}

// Locks the demo of this step: after a move of `shift`, a reader sees the values it would have
// seen `shift` earlier, bit for bit, with no rebuild. That holds for one flick, for a shift
// backwards, and for a day, which would cost bits if the progress went through floating seconds.
test "moving a cue shifts its tween by exactly that time" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 0 });
    var nodes: [1]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 1, .cues = &cues });
    const tween = try builder.tween(tween_of(0.1, 0.7, cue, .in_out));
    var slab: [1]f64 = undefined;
    var state = State.init(builder.finish(), &slab);

    var expected: [64]f64 = undefined;
    for (&expected, 0..) |*value, index| {
        state.eval(.{ .flicks = @as(i64, @intCast(index)) * 23_456_789 - 7 });
        value.* = state.value(tween);
    }
    for ([_]i64{ 1, -12_345, 86_400 * 705_600_000 }) |shift| {
        try cues.move(cue, .{ .flicks = shift });
        for (expected, 0..) |value, index| {
            state.eval(.{ .flicks = @as(i64, @intCast(index)) * 23_456_789 - 7 + shift });
            try testing.expectEqual(value, state.value(tween));
        }
    }
}

// Locks a sequence of two tweens: 0 to 1 from t = 0 s for 1.5 s, then 5 to 2 from t = 2 s. The
// first holds 0 before it starts and 1 in the gap, and the second then jumps to its own `from` and
// holds its `to` afterwards.
test "a chain of tweens is a sequence, and a gap holds" {
    var times: [2]Time = undefined;
    var cues = Cues.init(&times);
    const first_cue = try cues.add(.{ .flicks = 0 });
    const second_cue = try cues.add(.{ .flicks = 2 * 705_600_000 });
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = &cues });
    const first = try builder.tween(tween_of(0, 1, first_cue, .linear));
    var second_tween = tween_of(5, 2, second_cue, .linear);
    second_tween.previous = first;
    const second = try builder.tween(second_tween);
    var slab: [2]f64 = undefined;
    var state = State.init(builder.finish(), &slab);

    const rows = [_]struct { flicks: i64, value: f64 }{
        .{ .flicks = -1, .value = 0 },
        .{ .flicks = 352_800_000, .value = 1.0 / 3.0 },
        .{ .flicks = 3 * 352_800_000, .value = 1 },
        .{ .flicks = 2 * 705_600_000 - 1, .value = 1 },
        .{ .flicks = 2 * 705_600_000, .value = 5 },
        .{ .flicks = 7 * 352_800_000, .value = 2 },
    };
    for (rows) |row| {
        state.eval(.{ .flicks = row.flicks });
        try testing.expectEqual(row.value, state.value(second));
    }
}

// Locks the decision of section 6: a tween starting while an earlier one runs wins from its start,
// so at t = 0.75 s, a sixth of the way into a second tween from 10 to 20, the output is 11.667 and
// not the first's 0.5. Moving the second cue onto the first gives the second from time zero, and
// moving it past that time restores the first.
test "a later tween wins an overlap" {
    var times: [2]Time = undefined;
    var cues = Cues.init(&times);
    const first_cue = try cues.add(.{ .flicks = 0 });
    const second_cue = try cues.add(.{ .flicks = 352_800_000 });
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = &cues });
    const first = try builder.tween(tween_of(0, 1, first_cue, .linear));
    var second_tween = tween_of(10, 20, second_cue, .linear);
    second_tween.previous = first;
    const second = try builder.tween(second_tween);
    var slab: [2]f64 = undefined;
    var state = State.init(builder.finish(), &slab);

    state.eval(.{ .flicks = 529_200_000 });
    try testing.expectEqual(@as(f64, 0.5), state.value(first));
    try testing.expectApproxEqAbs(@as(f64, 11.666666666666666), state.value(second), 1e-13);

    try cues.move(second_cue, .{ .flicks = 0 });
    state.eval(.{ .flicks = 0 });
    try testing.expectEqual(@as(f64, 10), state.value(second));
    try cues.move(second_cue, .{ .flicks = 2 * 705_600_000 });
    state.eval(.{ .flicks = 529_200_000 });
    try testing.expectEqual(@as(f64, 0.5), state.value(second));
}

// Locks that `previous` can be any signal: a tween follows a wave until its cue, sample for
// sample, and leaves it at its own `from`.
test "a tween can follow any signal until its cue" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 705_600_000 });
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = &cues });
    const wave = try builder.wave(swell);
    var source = tween_of(3, 4, cue, .linear);
    source.previous = wave;
    const tween = try builder.tween(source);
    var slab: [2]f64 = undefined;
    var state = State.init(builder.finish(), &slab);

    const time = Time{ .flicks = 123_456_789 };
    state.eval(time);
    try testing.expectEqual(swell.sample(time), state.value(tween));
    state.eval(cues.at(cue));
    try testing.expectEqual(@as(f64, 3), state.value(tween));
}

// Locks the far ends of an i64: a cue at the earliest time, read at the latest, is 2^64 - 1 flicks
// apart, which does not fit in an i64, and the tween must land and not wrap into its start. Its
// progress at 2^62 flicks in, half of a duration of 2^63 - 1, rounds to exactly a half.
test "a tween survives the full range of time" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = std.math.minInt(i64) });
    var nodes: [1]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 1, .cues = &cues });
    var source = tween_of(1, 2, cue, .linear);
    source.duration = .{ .flicks = std.math.maxInt(i64) };
    const tween = try builder.tween(source);
    var slab: [1]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    state.eval(.{ .flicks = std.math.maxInt(i64) });
    try testing.expectEqual(@as(f64, 2), state.value(tween));
    state.eval(.{ .flicks = -1 });
    try testing.expectEqual(@as(f64, 2), state.value(tween));
    state.eval(.{ .flicks = std.math.minInt(i64) + (1 << 62) });
    try testing.expectEqual(@as(f64, 1.5), state.value(tween));
}

// Locks each refusal of `tween` by name. The first is the case of a tween with no table at all.
test "the builder refuses a tween it cannot evaluate" {
    var nodes: [2]Node = undefined;
    var empty = Builder.init(&nodes, .{ .slab_count_max = 2 });
    const cue_none: Cue = .{ .index = 0 };
    try testing.expectError(error.UnknownCue, empty.tween(tween_of(0, 1, cue_none, .linear)));

    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 0 });
    var builder = Builder.init(&nodes, .{ .slab_count_max = 2, .cues = &cues });
    const nan = std.math.nan(f64);
    try testing.expectError(error.NotFinite, builder.tween(tween_of(nan, 1, cue, .linear)));
    try testing.expectError(error.NotFinite, builder.tween(tween_of(0, nan, cue, .linear)));

    var source = tween_of(0, 1, cue, .linear);
    source.duration = .{ .flicks = 0 };
    try testing.expectError(error.InvalidDuration, builder.tween(source));
    source.duration = .{ .flicks = -1 };
    try testing.expectError(error.InvalidDuration, builder.tween(source));

    source = tween_of(0, 1, cue, .{ .x1 = 2, .y1 = 0, .x2 = 1, .y2 = 1 });
    try testing.expectError(error.InvalidEase, builder.tween(source));

    source = tween_of(0, 1, cue, .linear);
    source.previous = .{ .index = 0 };
    try testing.expectError(error.UnknownNode, builder.tween(source));
    try testing.expectEqual(@as(u32, 0), builder.node_count);
}

// Locks that a tween fills every lane of its extent, from itself and from `previous`.
test "a tween loops over the extent of its node" {
    var times: [1]Time = undefined;
    var cues = Cues.init(&times);
    const cue = try cues.add(.{ .flicks = 705_600_000 });
    var nodes: [2]Node = undefined;
    var builder = Builder.init(&nodes, .{ .slab_count_max = 12, .cues = &cues });
    builder.extent = .{ .lanes = 6, .components = 1 };
    const before = try builder.constant(7);
    var source = tween_of(1, 9, cue, .linear);
    source.previous = before;
    const tween = try builder.tween(source);
    var slab: [12]f64 = undefined;
    var state = State.init(builder.finish(), &slab);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqualSlices(f64, &@as([6]f64, @splat(7)), state.values(tween));
    state.eval(.{ .flicks = 3 * 705_600_000 });
    try testing.expectEqualSlices(f64, &@as([6]f64, @splat(9)), state.values(tween));
}
