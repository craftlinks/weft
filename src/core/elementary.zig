//! Elementary functions: sine and cosine in turns, a decaying exponential, and a logarithm.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Weft Has Its Own
//! Regress requires the same bits on native and wasm. `@sin`, `@exp`, and `@log` lower to calls,
//! and which function answers depends on the link: compiler-rt in a freestanding build, glibc in a
//! client that links libc. So Weft computes them here, from additions, multiplications, divisions,
//! and floors of f64 alone. IEEE 754 defines those exactly on every target, and Zig does not fuse
//! them unless asked. Square roots come from `@sqrt`, which IEEE 754 also defines exactly.
//!
//! ## 2. The Sine Works in Turns
//! A quarter of a turn is an exact number, so the reduction to [-1/8, 1/8] of a turn loses nothing,
//! and the zeros and peaks of the wave are exact. Only then is the remainder scaled to radians for
//! the polynomial. The cosine shares the reduction, a quarter of a turn on.
//!
//! ## 3. The Exponential and the Logarithm
//! `exp` splits its argument into a whole number of factors of 2 and a remainder within half of
//! ln 2, and `log` splits its argument into a power of 2 and a mantissa within a factor of sqrt 2
//! of 1. The power of 2 is exact either way. ln 2 is split in two, a high part with 20 bits so that
//! its multiples are exact and a low part for the rest, so the reduction loses almost nothing.
//!
//! ## 4. The Polynomials
//! Every series is a Taylor series, or for the logarithm the series of artanh, cut where the next
//! term falls below half a unit in the last place over its whole range. The coefficients are
//! worked out at compile time, so there are no literal constants to trust. A minimax fit would need
//! fewer terms, at the cost of a table of numbers no reader can check.
//!
//! ## 5. TigerStyle Invariants
//! - No allocation, no state, no libc, and fixed-length loops: safe on an audio thread.
//! - `sine_cosine` returns values in [-1, 1], and `exp` returns values in [0, 1].

const std = @import("std");
const assert = std.debug.assert;

pub const SineCosine = struct {
    sine: f64,
    cosine: f64,
};

/// The sine and cosine of `turns` of a cycle, which is in [0, 1).
pub fn sine_cosine(turns: f64) SineCosine {
    assert(turns >= 0);
    assert(turns < 1);
    // The nearest quarter: octants 7 and 0 are around 0 and 1, octants 1 and 2 around a quarter.
    const octant: u32 = @intFromFloat(turns * 8);
    const quarter: u32 = (octant + 1) / 2;
    const quarter_turns = @as(f64, @floatFromInt(quarter)) / 4;
    const radians = (turns - quarter_turns) * std.math.tau;
    assert(@abs(radians) <= std.math.pi / 4.0 + 1e-15);
    const s = sine_series(radians);
    const c = cosine_series(radians);
    // `0 - value` and not `-value`: a sine of exactly zero must be +0, whichever way it falls.
    const result: SineCosine = switch (quarter) {
        0, 4 => .{ .sine = s, .cosine = c },
        1 => .{ .sine = c, .cosine = 0 - s },
        2 => .{ .sine = 0 - s, .cosine = 0 - c },
        3 => .{ .sine = 0 - c, .cosine = s },
        else => unreachable,
    };
    assert(@abs(result.sine) <= 1);
    assert(@abs(result.cosine) <= 1);
    return result;
}

/// The sine of `turns` of a cycle, which is in [0, 1).
pub fn sine(turns: f64) f64 {
    return sine_cosine(turns).sine;
}

/// Below this, `exp` returns 0: e^-708 is within a factor of 2 of the smallest normal double.
const exp_floor: f64 = -708;

/// e^x for x at most 0, or 0 below `exp_floor`.
pub fn exp(x: f64) f64 {
    assert(!std.math.isNan(x));
    assert(x <= 0);
    if (x < exp_floor) return 0;
    const twos = @floor(x * std.math.log2e + 0.5);
    const remainder = (x - twos * ln2_high) - twos * ln2_low;
    assert(@abs(remainder) <= std.math.ln2 / 2.0 + 1e-12);
    const power: i64 = @intFromFloat(twos);
    assert(power >= -1022);
    assert(power <= 0);
    const scale: f64 = @bitCast(@as(u64, @intCast(power + 1023)) << 52);
    const result = polynomial(&exp_terms, remainder) * scale;
    assert(result >= 0);
    assert(result <= 1);
    return result;
}

/// ln x for x above 0 and finite.
pub fn log(x: f64) f64 {
    assert(x > 0);
    assert(std.math.isFinite(x));
    // A subnormal is scaled into the normal range first, and the scale taken off the exponent.
    const subnormal = x < std.math.floatMin(f64);
    const normal = if (subnormal) x * 0x1p54 else x;
    const bits: u64 = @bitCast(normal);
    var exponent: i64 = @as(i64, @intCast(bits >> 52)) - 1023;
    if (subnormal) exponent -= 54;
    var mantissa: f64 = @bitCast((bits & ((1 << 52) - 1)) | (@as(u64, 1023) << 52));
    assert(mantissa >= 1);
    assert(mantissa < 2);
    if (mantissa > std.math.sqrt2) {
        mantissa /= 2;
        exponent += 1;
    }
    // ln m = 2 artanh(s), with s = (m - 1) / (m + 1), and m - 1 is exact.
    const s = (mantissa - 1) / (mantissa + 1);
    assert(@abs(s) < 0.1716);
    const log_mantissa = 2 * s * polynomial(&artanh_terms, s * s);
    const twos: f64 = @floatFromInt(exponent);
    return twos * ln2_high + (twos * ln2_low + log_mantissa);
}

/// ln 2 with its low 32 bits cleared, so a multiple by up to 2^32 is exact.
const ln2_high: f64 = @bitCast(@as(u64, @bitCast(@as(f64, std.math.ln2))) & ~low_32_bits);
const low_32_bits: u64 = (1 << 32) - 1;
/// The rest of ln 2, worked out in comptime precision. Without the cast, the subtraction would be
/// an f64 one, and it would keep the rounding of ln 2 that the split exists to avoid.
const ln2_low: f64 = std.math.ln2 - @as(comptime_float, ln2_high);

const sine_terms_count = 8;
const cosine_terms_count = 9;
const exp_terms_count = 15;
const artanh_terms_count = 11;
const sine_terms: [sine_terms_count]f64 = series_terms(sine_terms_count, 1, 2, -1);
const cosine_terms: [cosine_terms_count]f64 = series_terms(cosine_terms_count, 0, 2, -1);
const exp_terms: [exp_terms_count]f64 = series_terms(exp_terms_count, 0, 1, 1);
const artanh_terms: [artanh_terms_count]f64 = artanh_series_terms(artanh_terms_count);

comptime {
    assert(sine_terms[0] == 1);
    assert(sine_terms[1] == -1.0 / 6.0);
    assert(cosine_terms[0] == 1);
    assert(cosine_terms[1] == -1.0 / 2.0);
    assert(exp_terms[0] == 1);
    assert(exp_terms[2] == 1.0 / 2.0);
    assert(artanh_terms[1] == 1.0 / 3.0);
    // The factorial of the last term and the next must each be an exact f64.
    assert(factorial(18) < 1 << 53);
    // The high part of ln 2 has 20 bits after its leading one, so its multiples by an exponent
    // are exact.
    assert(@as(u64, @bitCast(ln2_high)) & low_32_bits == 0);
    assert(@abs(@as(comptime_float, ln2_high) + ln2_low - std.math.ln2) < 1e-30);
}

/// 1 / n! for every `step`-th n from `power_first`, each `sign` times the one before.
fn series_terms(
    comptime count: u32,
    comptime power_first: u32,
    comptime step: u32,
    comptime sign_change: f64,
) [count]f64 {
    var terms: [count]f64 = undefined;
    var sign: f64 = 1;
    for (&terms, 0..) |*term, index| {
        term.* = sign / @as(f64, @floatFromInt(factorial(power_first + step * index)));
        sign *= sign_change;
    }
    return terms;
}

/// 1 / (2n + 1), the series of artanh(s) / s in powers of s^2.
fn artanh_series_terms(comptime count: u32) [count]f64 {
    var terms: [count]f64 = undefined;
    for (&terms, 0..) |*term, index| term.* = 1.0 / @as(f64, @floatFromInt(2 * index + 1));
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
    assert(!std.math.isNan(x));
    var result: f64 = 0;
    for (0..terms.len) |index| result = result * x + terms[terms.len - 1 - index];
    return result;
}

const testing = std.testing;

/// The sine or cosine of `turns` of a cycle in f128, far beyond f64: the plain series with 40
/// terms, whose first omitted term is below 1e-40 for any angle in a cycle.
fn series_reference(turns: f64, power_first: u32) f128 {
    const radians = @as(f128, turns) * std.math.tau;
    var term: f128 = if (power_first == 1) radians else 1;
    var sum = term;
    for (1..40) |index| {
        const n: f128 = @floatFromInt(2 * index + power_first - 1);
        term = -term * radians * radians / (n * (n + 1));
        sum += term;
    }
    return sum;
}

// Locks the sine and cosine against an f128 reference over 2^13 points of a cycle: within 2.5e-16,
// which is about 1 unit in the last place at the peak. `@sin` is no reference: its argument
// rounds first.
test "the sine and cosine are accurate across a cycle" {
    const points_count: u32 = 1 << 13;
    for (0..points_count) |index| {
        const turns = (@as(f64, @floatFromInt(index)) + 0.37) / points_count;
        const result = sine_cosine(turns);
        try testing.expect(@abs(@as(f128, result.sine) - series_reference(turns, 1)) < 2.5e-16);
        try testing.expect(@abs(@as(f128, result.cosine) - series_reference(turns, 0)) < 2.5e-16);
    }
}

// Locks the symmetry the reduction gives: half a turn apart is the exact negative, bit for bit,
// and a sine and cosine square and sum to 1 within 3 ulp.
test "the sine is symmetric to the last bit" {
    const points_count: u32 = 1 << 12;
    for (0..points_count) |index| {
        const turns = @as(f64, @floatFromInt(index)) / (points_count * 2);
        try testing.expectEqual(0 - sine(turns), sine(turns + 0.5));
        const result = sine_cosine(turns);
        const sum = result.sine * result.sine + result.cosine * result.cosine;
        try testing.expectApproxEqAbs(@as(f64, 1), sum, 7e-16);
    }
}

// Locks the exact landmarks of the cosine: 1, 0, -1, 0 at the quarters, with each zero +0.
test "the cosine lands exactly on its quarters" {
    const expected = [_]f64{ 1, 0, -1, 0 };
    for (expected, 0..) |value, quarter| {
        const cosine = sine_cosine(@as(f64, @floatFromInt(quarter)) / 4).cosine;
        try testing.expectEqual(@as(u64, @bitCast(value)), @as(u64, @bitCast(cosine)));
    }
}

/// The distance between `value` and an f128 `reference`, in units of the last place of `value`.
fn ulps(value: f64, reference: f128) f128 {
    const magnitude = @max(@abs(value), std.math.floatMin(f64));
    const unit: f128 = @floatCast(std.math.floatEps(f64) * magnitude);
    return @abs(@as(f128, value) - reference) / unit;
}

// Locks `exp` against f128 over [-708, 0] at 2^16 points, and at its landmarks: within 1 unit in
// the last place (0.74 measured), exactly 1 at 0, and 0 below the floor, including at minus
// infinity.
test "exp is accurate down to its floor" {
    const points_count: u32 = 1 << 16;
    var worst: f128 = 0;
    for (0..points_count + 1) |index| {
        const x = -708 * @as(f64, @floatFromInt(index)) / points_count;
        worst = @max(worst, ulps(exp(x), @exp(@as(f128, x))));
    }
    try testing.expect(worst < 1);
    try testing.expectEqual(@as(f64, 1), exp(0));
    try testing.expectEqual(@as(f64, 1), exp(-0.0));
    try testing.expectEqual(@as(f64, 0), exp(-708.5));
    try testing.expectEqual(@as(f64, 0), exp(-std.math.inf(f64)));
}

// Locks `log` against f128 at 2^16 points spread over every exponent from subnormal to the
// largest double, and its landmarks: within 1.5 units in the last place (1.11 measured, near 1,
// where the division that forms s rounds), exactly 0 at 1, and exactly ln 2 at 2 and -ln 2 at a
// half.
test "log is accurate from the smallest double to the largest" {
    const points_count: u32 = 1 << 16;
    var worst: f128 = 0;
    for (0..points_count) |index| {
        const fraction = @as(f64, @floatFromInt(index)) / points_count;
        const x = std.math.pow(f64, 2, -1074 + fraction * 2097) * (1 + fraction / 3);
        if (x == 0 or !std.math.isFinite(x)) continue;
        worst = @max(worst, ulps(log(x), @log(@as(f128, x))));
    }
    try testing.expect(worst < 1.5);
    try testing.expectEqual(@as(f64, 0), log(1));
    try testing.expectEqual(@as(f64, -std.math.ln2), log(0.5));
    try testing.expectEqual(@as(f64, std.math.ln2), log(2));
}
