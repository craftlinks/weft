//! Ranges and signal classes: what a client can prove about a program without sampling it.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Conservative, Never Wrong
//! Every node has a range its values never leave, at any time, for any cue placement, in any read
//! order. A range can be wider than the truth, but a stated bound is never wrong. `graph.zig` works
//! one out for each op in a forward pass, from the ranges of its inputs; this file holds the
//! arithmetic and the bounds of the motions.
//!
//! ## 2. Exact Where Rounding Is Monotone
//! A range is computed with the same f64 operations `eval` uses, at the ends. IEEE rounding is
//! monotone, so where the operation is too, the computed ends are the exact bounds: a sum of two
//! ranges, the corner products of a multiply, a constant, a wave's [-1, 1]. Where an op's form is
//! not monotone under rounding, such as an interpolation `a * (1 - w) + b * w`, or where it runs a
//! closed form or many steps, the range is moved out by a margin relative to the scale of the
//! values involved: `margin_rounding` for a form of a few operations, `margin_motion` for the
//! closed forms of a spring or a Newtonian move. NaN from an infinite end, such as `inf - inf`, is
//! the unbounded end.
//!
//! Interval arithmetic treats every input as independent, so `x * x` over [-1, 1] is [-1, 1] and
//! not [0, 1]. That is wide, and never wrong.
//!
//! ## 2a. Functions of a Value
//! abs, min, and max round nothing, and each is monotone in each input where its sign is fixed,
//! so their ranges are exact for independent inputs, with no margin (step 26). `minimum(a, b)` is
//! the smaller low and the smaller high, `maximum` the larger of each, and `abs` the input itself
//! at or above 0, the input negated at or below 0, and from 0 to the larger magnitude across 0.
//! Each end is reached where the inputs are at their own ends, so a test can find it by sampling.
//! The ends use `graph.minimum` and `graph.maximum`, so a signed zero at an end is the same on
//! every target.
//!
//! ## 3. Springs
//! A spring is a linear second-order system from rest, driven by a goal that is piecewise constant:
//! goals at cues, a target held over each step, or a follower's goals. It holds its start at rest
//! before its first goal, so the start counts as input too. With the input inside [c - r, c + r]
//! for all time, the distance from c is the convolution of the impulse response h with the input's
//! distance from c, so it is at most r times the integral of |h|. A critically damped h is never
//! negative and its integral is 1, so the range is the hull of the inputs. An underdamped h has
//! lobes that shrink by the peak overshoot `os` each half period, and its integral is 1, so the
//! integral of |h| is (1 + os) / (1 - os): 1.3896 at a damping ratio of 0.5, where `os` is 16.3%.
//! One move from rest overshoots by exactly `os` of the move, which is tighter, so a spring with
//! one goal uses that instead.
//!
//! ## 4. Newtonian Moves
//! A Newtonian move never goes faster than its `speed`: each plan peaks at the larger of `speed`
//! and the speed it starts with, which by induction is at most `speed`. It only passes a goal when
//! it is too fast to stop, by at most its stopping distance, `speed^2 / (2 * decel)`. So its range
//! is the hull of its inputs, widened by that distance.
//!
//! ## 5. Classes
//! Every node belongs to one of four classes, by how a reader reaches a time: pure, a function of
//! the time; exact, folding over the goal changes before it; simulated, stepping from a
//! checkpoint; live, reading a value supplied each read, which has no past. A node's class is the
//! highest of its own op's and its inputs'. A program with a live node is not seekable: a backward
//! read works, but cannot give the past again.
//!
//! ## 6. TigerStyle Invariants
//! - No allocation and no state. Every function here is pure.
//! - `low <= high` for every range made here, and neither end is NaN.

const std = @import("std");
const assert = std.debug.assert;
const elementary = @import("elementary.zig");
const graph = @import("graph.zig");
const Id = graph.Id;

const inf = std.math.inf(f64);

/// The margin, relative to the scale of the values, for a form of a few operations: eight units
/// in the last place.
pub const margin_rounding: f64 = 0x1p-50;

/// The margin, relative to the scale of the values, for the closed forms of a motion and for a
/// simulation's many steps.
pub const margin_motion: f64 = 0x1p-40;

pub const Range = struct {
    low: f64,
    high: f64,

    pub const unbounded: Range = .{ .low = -inf, .high = inf };

    pub fn point(value: f64) Range {
        assert(std.math.isFinite(value));
        return .{ .low = value, .high = value };
    }

    /// The range from two ends in either order. A NaN end is unbounded.
    pub fn of(a: f64, b: f64) Range {
        if (std.math.isNan(a) or std.math.isNan(b)) return unbounded;
        return .{ .low = @min(a, b), .high = @max(a, b) };
    }

    pub fn contains(range: Range, value: f64) bool {
        range.assert_valid();
        return value >= range.low and value <= range.high;
    }

    /// Whether every value of `inner` is in `range`.
    pub fn covers(range: Range, inner: Range) bool {
        range.assert_valid();
        inner.assert_valid();
        return inner.low >= range.low and inner.high <= range.high;
    }

    pub fn hull(a: Range, b: Range) Range {
        a.assert_valid();
        b.assert_valid();
        return .{ .low = @min(a.low, b.low), .high = @max(a.high, b.high) };
    }

    /// The larger magnitude of the two ends, the scale a margin is relative to.
    pub fn scale(range: Range) f64 {
        range.assert_valid();
        return @max(@abs(range.low), @abs(range.high));
    }

    /// `range` moved out by `margin` of `magnitude` at each end, and by the smallest normal, so a
    /// range at zero widens too. An infinite magnitude leaves the ends as they are, since the range
    /// it came from is already unbounded where it matters.
    pub fn widen(range: Range, magnitude: f64, margin: f64) Range {
        range.assert_valid();
        assert(magnitude >= 0);
        assert(margin > 0);
        if (!std.math.isFinite(magnitude)) return range;
        const by = magnitude * margin + std.math.floatMin(f64);
        return .{ .low = range.low - by, .high = range.high + by };
    }

    pub fn assert_valid(range: Range) void {
        assert(!std.math.isNan(range.low));
        assert(!std.math.isNan(range.high));
        assert(range.low <= range.high);
    }
};

/// The range of `a + b`. Exact, since rounding is monotone; an end that is NaN, `inf - inf`, is
/// unbounded.
pub fn add(a: Range, b: Range) Range {
    const low = a.low + b.low;
    const high = a.high + b.high;
    return .{
        .low = if (std.math.isNan(low)) -inf else low,
        .high = if (std.math.isNan(high)) inf else high,
    };
}

/// The range of `a * b`: the least and largest corner products. Exact, since rounding is monotone
/// for each sign. A NaN corner, `0 * inf`, makes the range unbounded.
pub fn multiply(a: Range, b: Range) Range {
    const corners = [_]f64{ a.low * b.low, a.low * b.high, a.high * b.low, a.high * b.high };
    var result: Range = .{ .low = inf, .high = -inf };
    for (corners) |corner| {
        if (std.math.isNan(corner)) return Range.unbounded;
        result.low = @min(result.low, corner);
        result.high = @max(result.high, corner);
    }
    return result;
}

/// The range of `|a|`, as section 2a explains. Exact.
pub fn abs(a: Range) Range {
    a.assert_valid();
    if (a.low >= 0) return a;
    if (a.high <= 0) return .{ .low = -a.high, .high = -a.low };
    const result: Range = .{ .low = 0, .high = graph.maximum(-a.low, a.high) };
    assert(result.high > 0);
    return result;
}

/// The range of the smaller of `a` and `b`, as section 2a explains. Exact.
pub fn minimum(a: Range, b: Range) Range {
    a.assert_valid();
    b.assert_valid();
    return .{ .low = graph.minimum(a.low, b.low), .high = graph.minimum(a.high, b.high) };
}

/// The range of the larger of `a` and `b`, as section 2a explains. Exact.
pub fn maximum(a: Range, b: Range) Range {
    a.assert_valid();
    b.assert_valid();
    return .{ .low = graph.maximum(a.low, b.low), .high = graph.maximum(a.high, b.high) };
}

/// The peak overshoot of a move from rest at damping ratio `zeta`, which section 3 explains.
pub fn overshoot(zeta: f64) f64 {
    assert(zeta > 0);
    assert(zeta <= 1);
    if (zeta == 1) return 0;
    const result = elementary.exp(-std.math.pi * zeta / @sqrt((1 - zeta) * (1 + zeta)));
    assert(result >= 0);
    assert(result < 1);
    return result;
}

/// The range of a spring at damping ratio `zeta` whose inputs, its start included, stay in
/// `inputs`, as section 3 explains.
pub fn spring(inputs: Range, zeta: f64) Range {
    inputs.assert_valid();
    if (!std.math.isFinite(inputs.low) or !std.math.isFinite(inputs.high)) return Range.unbounded;
    const os = overshoot(zeta);
    if (os == 0) return inputs.widen(inputs.scale(), margin_motion);
    const centre = inputs.low / 2 + inputs.high / 2;
    const radius = (inputs.high - inputs.low) / 2 * ((1 + os) / (1 - os));
    const result = Range.of(centre - radius, centre + radius).hull(inputs);
    return result.widen(result.scale(), margin_motion);
}

/// The range of a spring at damping ratio `zeta` making one move from rest, from `from` to `goal`:
/// the two, and past the goal by its overshoot of the move.
pub fn spring_one(from: f64, goal: f64, zeta: f64) Range {
    assert(std.math.isFinite(from));
    assert(std.math.isFinite(goal));
    const past = overshoot(zeta) * (goal - from);
    const result = Range.of(from, goal + past).hull(Range.of(from, goal));
    return result.widen(result.scale(), margin_motion);
}

/// The range of a spring follower whose damping ratio changes from step to step and whose omega
/// does not, with its start and regions in `inputs`, arriving within `tolerance`. Its amplitude
/// about its goal, `A^2 = e^2 + (e' / omega)^2`, never grows while its goal holds, whatever the
/// damping, since `d(A^2)/dt = -4 zeta e'^2 / omega`. It changes goal only after arriving, when
/// `A <= tolerance (1 + 1 / omega)`, and a new goal is at most the hull's width W away, so from
/// then on `A <= W + 2 tolerance (1 + 1 / omega)`. The first goal starts at rest, within W. So it
/// stays within that of the hull. Looser than `spring`, which needs a constant law, and as sound.
pub fn follower_damping(inputs: Range, tolerance: f64, omega: f64) Range {
    inputs.assert_valid();
    assert(tolerance >= 0);
    assert(omega > 0);
    if (!std.math.isFinite(inputs.low) or !std.math.isFinite(inputs.high)) return Range.unbounded;
    const reach = (inputs.high - inputs.low) + 2 * tolerance * (1 + 1 / omega);
    const result: Range = .{ .low = inputs.low - reach, .high = inputs.high + reach };
    return result.widen(result.scale(), margin_motion);
}

/// The range of a Newtonian move with these limits whose inputs, its start included, stay in
/// `inputs`, as section 4 explains.
pub fn newtonian(inputs: Range, speed: f64, decel: f64) Range {
    inputs.assert_valid();
    assert(speed > 0);
    assert(decel > 0);
    const stopping = speed * speed / (2 * decel);
    const result: Range = .{ .low = inputs.low - stopping, .high = inputs.high + stopping };
    return result.widen(result.scale(), margin_motion);
}

/// How a reader reaches a node's value at a time, in increasing order of cost, as section 5
/// explains.
pub const Class = enum(u8) {
    /// A function of the time.
    pure,
    /// Exact between goal changes: a fold over the goal changes before the time.
    exact,
    /// On the fixed step, from a checkpoint.
    simulated,
    /// Supplied each read, with no past.
    live,

    pub fn max(a: Class, b: Class) Class {
        return if (@backingInt(a) >= @backingInt(b)) a else b;
    }
};

/// Whether a program can be reached at any time, and if not, which node is why.
pub const Report = struct {
    /// No live node: every time can be reached, and reached again with the same values.
    seekable: bool,
    /// The first live node, the reason it is not.
    live: ?Id,
    /// A read can cost steps, which checkpoints bound.
    stepped: bool,
    /// The first simulated node, the reason it is stepped.
    first_simulated: ?Id,
};

const testing = std.testing;

// Locks the arithmetic: sums and corner products are exact, NaN ends are unbounded, and a widened
// range at zero still widens.
test "interval arithmetic is exact where rounding is monotone" {
    const wave: Range = .{ .low = -1, .high = 1 };
    try testing.expectEqual(Range{ .low = -2, .high = 2 }, add(wave, wave));
    try testing.expectEqual(wave, multiply(wave, wave));
    const half: Range = .{ .low = 0.25, .high = 0.5 };
    try testing.expectEqual(Range{ .low = -0.5, .high = 0.5 }, multiply(wave, half));
    try testing.expectEqual(Range.unbounded, add(Range.unbounded, Range.unbounded));
    try testing.expectEqual(Range.unbounded, multiply(Range.point(0), Range.unbounded));
    const zero = Range.point(0).widen(0, margin_rounding);
    try testing.expect(zero.low < 0);
    try testing.expect(zero.high > 0);
}

// Locks the worked ranges of section 2a: |[-3, 2]| is [0, 3], |[-3, -1]| is [1, 3], |[1, 2]| is
// itself, an unbounded side stays unbounded, and min and max of [-1, 1] and [0, 2] are [-1, 1]
// and [0, 2]; a range ending at -0 gives -0 where both lows are a zero.
test "abs, min, and max have exact ranges" {
    try testing.expectEqual(Range{ .low = 0, .high = 3 }, abs(.{ .low = -3, .high = 2 }));
    try testing.expectEqual(Range{ .low = 1, .high = 3 }, abs(.{ .low = -3, .high = -1 }));
    try testing.expectEqual(Range{ .low = 1, .high = 2 }, abs(.{ .low = 1, .high = 2 }));
    try testing.expectEqual(Range{ .low = 0, .high = inf }, abs(.{ .low = -inf, .high = 2 }));
    try testing.expectEqual(Range{ .low = 0, .high = inf }, abs(Range.unbounded));
    const wave: Range = .{ .low = -1, .high = 1 };
    const above: Range = .{ .low = 0, .high = 2 };
    try testing.expectEqual(Range{ .low = -1, .high = 1 }, minimum(wave, above));
    try testing.expectEqual(Range{ .low = 0, .high = 2 }, maximum(wave, above));
    try testing.expectEqual(Range{ .low = -inf, .high = 1 }, minimum(Range.unbounded, wave));
    try testing.expectEqual(Range{ .low = -1, .high = inf }, maximum(Range.unbounded, wave));
    const zeros = minimum(.{ .low = 0, .high = 1 }, .{ .low = -0.0, .high = 1 });
    try testing.expect(std.math.signbit(zeros.low));
    const plus = maximum(.{ .low = -0.0, .high = 1 }, .{ .low = 0, .high = 1 });
    try testing.expect(!std.math.signbit(plus.low));
}

// Locks the worked values of section 3: 16.3% at a damping ratio of 0.5, a factor of 1.3896, and
// a critical spring's range is the hull of its inputs, within its margin.
test "a spring's range includes its overshoot" {
    const os = overshoot(0.5);
    try testing.expectApproxEqAbs(@as(f64, 0.163), os, 0.0005);
    try testing.expectApproxEqAbs(@as(f64, 1.3896), (1 + os) / (1 - os), 0.0001);
    const one = spring_one(0, 1, 0.5);
    try testing.expect(one.low <= 0);
    try testing.expectApproxEqAbs(@as(f64, 0), one.low, 1e-11);
    try testing.expectApproxEqAbs(1 + os, one.high, 1e-11);
    const critical = spring(.{ .low = -0.5, .high = 1 }, 1);
    try testing.expectApproxEqAbs(@as(f64, -0.5), critical.low, 1e-11);
    try testing.expectApproxEqAbs(@as(f64, 1), critical.high, 1e-11);
    const moving = spring(.{ .low = 0, .high = 1 }, 0.5);
    try testing.expectApproxEqAbs(0.5 - 0.5 * (1 + os) / (1 - os), moving.low, 1e-11);
    const glide = newtonian(.{ .low = 0, .high = 2 }, 4, 4);
    try testing.expectApproxEqAbs(@as(f64, -2), glide.low, 1e-10);
    try testing.expectApproxEqAbs(@as(f64, 4), glide.high, 1e-10);
}
