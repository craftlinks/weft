//! Waves: sine, triangle, saw, and square, each a pure function of time.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Pure Functions of Time
//! A wave holds no state, so a reader can ask for any time in any order and a run can never differ
//! from another one. All four shapes are bipolar, in [-1, 1], and start a cycle at time zero.
//! `Time.turns` turns the time into a position in the cycle, and everything here works in turns.
//!
//! ## 2. Why Weft Has Its Own Sine
//! Regress requires the same bits on native and wasm. `@sin` lowers to a call of `sin`, and which
//! `sin` answers depends on the link: compiler-rt in a freestanding build, glibc in a client that
//! links libc. So Weft computes its sine here, from additions and multiplications of f64 alone.
//! IEEE 754 defines those exactly on every target, and Zig does not fuse them unless asked.
//!
//! The sine works in turns for a second reason. A quarter of a turn is an exact number, so the
//! reduction to [-1/8, 1/8] of a turn loses nothing, and the zeros and peaks of the wave are exact.
//! Only then is the remainder scaled to radians for the polynomial.
//!
//! ## 3. The Polynomials
//! The sine and cosine of the remainder are Taylor series, cut where the next term falls below
//! half a unit in the last place at pi / 4. The coefficients are 1 / n! worked out at compile time,
//! so there are no literal constants to trust. A minimax fit would need one fewer term, at the
//! cost of a table of numbers no reader can check.
//!
//! ## 4. TigerStyle Invariants
//! - No allocation, no state, no libc, and one fixed-length loop: safe on an audio thread.
//! - Every shape returns a value in [-1, 1] for a position in [0, 1).

const std = @import("std");
const assert = std.debug.assert;
const Time = @import("time.zig").Time;

pub const Shape = enum {
    /// Starts at 0 and rises; 1 at a quarter of the cycle, -1 at three quarters.
    sine,
    /// Passes through 0, 1, 0, -1 at the quarters of the cycle, with straight lines between.
    triangle,
    /// Rises from -1 towards 1 over the cycle, then falls back at once.
    saw,
    /// 1 for the first half of the cycle and -1 for the second.
    square,
};

pub const Wave = struct {
    shape: Shape,
    hz: f64,

    /// The value of the wave at `time`, in [-1, 1].
    pub fn sample(wave: Wave, time: Time) f64 {
        assert(std.math.isFinite(wave.hz));
        const turns = time.turns(wave.hz);
        const result = switch (wave.shape) {
            .sine => sine_at(turns),
            .triangle => triangle_at(turns),
            .saw => saw_at(turns),
            .square => square_at(turns),
        };
        assert(result >= -1);
        assert(result <= 1);
        return result;
    }
};

fn sine_at(turns: f64) f64 {
    assert(turns >= 0);
    assert(turns < 1);
    // The nearest quarter: octants 7 and 0 are around 0 and 1, octants 1 and 2 around a quarter.
    const octant: u32 = @intFromFloat(turns * 8);
    const quarter: u32 = (octant + 1) / 2;
    const quarter_turns = @as(f64, @floatFromInt(quarter)) / 4;
    const radians = (turns - quarter_turns) * std.math.tau;
    assert(@abs(radians) <= std.math.pi / 4.0 + 1e-15);
    // `0 - value` and not `-value`: a sine of exactly zero must be +0, whichever way it falls.
    return switch (quarter) {
        0, 4 => sine_series(radians),
        1 => cosine_series(radians),
        2 => 0 - sine_series(radians),
        3 => 0 - cosine_series(radians),
        else => unreachable,
    };
}

fn triangle_at(turns: f64) f64 {
    assert(turns >= 0);
    assert(turns < 1);
    if (turns < 0.25) return turns * 4;
    if (turns < 0.75) return 2 - turns * 4;
    return turns * 4 - 4;
}

fn saw_at(turns: f64) f64 {
    assert(turns >= 0);
    assert(turns < 1);
    return turns * 2 - 1;
}

fn square_at(turns: f64) f64 {
    assert(turns >= 0);
    assert(turns < 1);
    if (turns < 0.5) return 1;
    return -1;
}

const sine_terms_count = 8;
const cosine_terms_count = 9;
const sine_terms: [sine_terms_count]f64 = series_terms(sine_terms_count, 1);
const cosine_terms: [cosine_terms_count]f64 = series_terms(cosine_terms_count, 0);

comptime {
    assert(sine_terms[0] == 1);
    assert(sine_terms[1] == -1.0 / 6.0);
    assert(cosine_terms[0] == 1);
    assert(cosine_terms[1] == -1.0 / 2.0);
    // The factorial of the last term and the next must each be an exact f64.
    assert(factorial(18) < 1 << 53);
}

/// 1 / n!, with alternating signs, for every second n from `power_first`.
fn series_terms(comptime count: u32, comptime power_first: u32) [count]f64 {
    var terms: [count]f64 = undefined;
    var sign: f64 = 1;
    for (&terms, 0..) |*term, index| {
        term.* = sign / @as(f64, @floatFromInt(factorial(power_first + 2 * index)));
        sign = -sign;
    }
    return terms;
}

fn factorial(comptime n: u64) u64 {
    var result: u64 = 1;
    for (1..n + 1) |factor| result *= factor;
    return result;
}

fn sine_series(radians: f64) f64 {
    return radians * polynomial(&sine_terms, radians * radians);
}

fn cosine_series(radians: f64) f64 {
    return polynomial(&cosine_terms, radians * radians);
}

/// Horner's rule: the sum of `terms[n] * x^n`.
fn polynomial(terms: []const f64, x: f64) f64 {
    assert(terms.len > 0);
    assert(x >= 0);
    var result: f64 = 0;
    for (0..terms.len) |index| result = result * x + terms[terms.len - 1 - index];
    return result;
}

const testing = std.testing;
const Rate = @import("time.zig").Rate;

/// The time of `numerator / denominator` of a second.
fn time_at(numerator: i64, denominator: u32) Time {
    return Time.from_ticks(numerator, Rate.from_hz(denominator).?).?;
}

// Locks the exact landmarks of each shape at 1 Hz, in quarters of a second: the quarters of a sine
// are exactly 0, 1, 0, -1, not nearly so, and the zero at a half is +0.
test "each shape lands exactly on its quarters" {
    const expected = [_]struct { shape: Shape, values: [4]f64 }{
        .{ .shape = .sine, .values = .{ 0, 1, 0, -1 } },
        .{ .shape = .triangle, .values = .{ 0, 1, 0, -1 } },
        .{ .shape = .saw, .values = .{ -1, -0.5, 0, 0.5 } },
        .{ .shape = .square, .values = .{ 1, 1, -1, -1 } },
    };
    for (expected) |row| {
        const wave = Wave{ .shape = row.shape, .hz = 1 };
        for (row.values, 0..) |value, quarter| {
            const time = time_at(@intCast(quarter), 4);
            const bits: u64 = @bitCast(wave.sample(time));
            try testing.expectEqual(@as(u64, @bitCast(value)), bits);
        }
    }
}

// Locks the sides of the discontinuities: a square and a saw just before a whole cycle.
test "the saw and the square turn over at the end of the cycle" {
    const late = time_at(47_999, 48_000);
    try testing.expectEqual(@as(f64, -1), (Wave{ .shape = .square, .hz = 1 }).sample(late));
    const saw = (Wave{ .shape = .saw, .hz = 1 }).sample(late);
    try testing.expectApproxEqAbs(@as(f64, 1), saw, 1e-4);
}

/// The sine of `turns` of a cycle in f128, far beyond f64: the plain series with 40 terms, whose
/// first omitted term is below 1e-40 for any angle in a cycle.
fn sine_reference(turns: f64) f128 {
    const radians = @as(f128, turns) * std.math.tau;
    var term = radians;
    var sum = radians;
    for (1..40) |index| {
        const n: f128 = @floatFromInt(2 * index);
        term = -term * radians * radians / (n * (n + 1));
        sum += term;
    }
    return sum;
}

// Locks the sine against an f128 reference over 2^13 points of a cycle: within 2.5e-16, which is
// about 1 unit in the last place at the peak. `@sin` is no reference: its argument rounds first.
test "the sine is accurate across a cycle" {
    const points_count: u32 = 1 << 13;
    for (0..points_count) |index| {
        const turns = (@as(f64, @floatFromInt(index)) + 0.37) / points_count;
        const difference = @as(f128, sine_at(turns)) - sine_reference(turns);
        try testing.expect(@abs(difference) < 2.5e-16);
    }
}

// Locks the symmetry the reduction gives: half a turn apart is the exact negative, bit for bit,
// and a quarter of a turn apart is a cosine that squares and sums to 1 within 3 ulp.
test "the sine is symmetric to the last bit" {
    const points_count: u32 = 1 << 12;
    for (0..points_count) |index| {
        const turns = @as(f64, @floatFromInt(index)) / (points_count * 2);
        try testing.expectEqual(0 - sine_at(turns), sine_at(turns + 0.5));
        const sine = sine_at(turns);
        const cosine = sine_at(@mod(turns + 0.25, 1));
        try testing.expectApproxEqAbs(@as(f64, 1), sine * sine + cosine * cosine, 7e-16);
    }
}

// Locks the rule that a wave is a pure function: frames read backwards and at random match frames
// read forwards, bit for bit.
test "the order of reading changes nothing" {
    const wave = Wave{ .shape = .sine, .hz = 0.7 };
    var forward: [240]f64 = undefined;
    for (&forward, 0..) |*value, frame| value.* = wave.sample(time_at(@intCast(frame), 60));

    var frame: i64 = forward.len;
    while (frame > 0) {
        frame -= 1;
        const index: usize = @intCast(frame);
        try testing.expectEqual(forward[index], wave.sample(time_at(frame, 60)));
    }

    var hop: usize = 0;
    for (0..forward.len) |_| {
        hop = (hop + 101) % forward.len;
        try testing.expectEqual(forward[hop], wave.sample(time_at(@intCast(hop), 60)));
    }
}

// Locks one second of 440 Hz at 48 kHz against a day later, for every shape, bit for bit, and the
// count of cycles: 440 rising zero crossings of the sine, one of them the start.
test "a wave at a day matches the wave at zero" {
    const day_ticks: i64 = 86_400 * 48_000;
    for (std.enums.values(Shape)) |shape| {
        const wave = Wave{ .shape = shape, .hz = 440 };
        var rising: u32 = 0;
        var before: f64 = -1;
        for (0..48_000) |tick| {
            const value = wave.sample(time_at(@intCast(tick), 48_000));
            const later = wave.sample(time_at(day_ticks + @as(i64, @intCast(tick)), 48_000));
            try testing.expectEqual(value, later);
            if (before < 0 and value >= 0) rising += 1;
            before = value;
        }
        if (shape == .sine) try testing.expectEqual(@as(u32, 440), rising);
    }
}
