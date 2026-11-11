//! Elementary functions: sine and cosine in turns, a decaying exponential, and a logarithm, and
//! the total functions of a value the graph's `apply` reads (section 4a).
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
//! ## 4a. Functions of a Value
//! `graph.Function` (step 33) reads these, and every one is total: any f64 a signal can hold,
//! infinities included, gives a finite value or the infinity it was given, never NaN, and never
//! an assert. A NaN, which reaches a pure node only after an overflow upstream, such as
//! `inf - inf`, passes through as NaN, as it does through a sum, so `State.finite` still says
//! so. Each is a function of its input alone, so the range rules in `range.zig` evaluate
//! it at a range's ends.
//! - `sine_radians` and `cosine_radians` take radians, as a formula writes them. The angle is
//!   made positive (sine is odd and cosine even, so the sign is restored exactly), divided by
//!   tau, which is the one rounding, and the whole turns taken off, which is exact. So the same
//!   input gives the same bits everywhere, and accuracy falls with the size of the input: the
//!   division's error is an ulp of x / tau, about 1e-10 turns at 1e6 radians. From 2^53 tau on,
//!   every input is a whole number of turns, so the sine is 0 and the cosine 1. An infinite input
//!   reads as 0 radians.
//! - `exponential` is `exp` below 0, the same bits, and the same reduction above it up to 709,
//!   where e^709 is about 8.2e307. Above that it holds e^709, so a value stays finite, as a loop
//!   saturates (`simulation.zig`, section 7); below -708 it is 0.
//! - `logarithm` is `log` for a positive finite input. Zero, a negative value, and minus infinity
//!   are held at the log of the smallest positive f64, 2^-1074, about -744.44, and plus infinity
//!   at the log of the largest, about 709.78.
//! - `square_root` is `@sqrt`, correctly rounded by IEEE 754 on every target, of a positive
//!   input, and 0 for any other: zero, minus zero, or a negative value.
//! - `round_half_away` rounds a half away from zero, as C's `round` does: -0.5 to -1, 0.5 to 1,
//!   1.5 to 2, 2.5 to 3, and keeps the sign of a zero, so -0.4 is -0. It is written from
//!   `@floor`, an exact subtraction, and an exact addition, not left to `@round`, whose lowering
//!   differs by target. `@floor` is IEEE 754's roundToIntegralTowardNegative everywhere.
//! - `power` multiplies x by itself n - 1 times, left to right, so `power(x, 2)` is `x * x` bit
//!   for bit. It overflows to an infinity as a product does.
//!
//! ## 5. TigerStyle Invariants
//! - No allocation, no state, no libc, and fixed-length loops: safe on an audio thread.
//! - `sine_cosine` returns values in [-1, 1], and `exp` returns values in [0, 1].
//! - The functions of section 4a return NaN only for NaN.

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
    const result = exp_reduced(x);
    assert(result >= 0);
    assert(result <= 1);
    return result;
}

/// Above this, `exponential` holds e^709, the largest whole power whose reduction keeps its scale
/// a normal double (section 4a).
pub const exp_ceiling: f64 = 709;

/// e^x for x from `exp_floor` to `exp_ceiling`: a whole number of factors of 2 and a remainder
/// within half of ln 2 (section 3).
fn exp_reduced(x: f64) f64 {
    assert(x >= exp_floor);
    assert(x <= exp_ceiling);
    const twos = @floor(x * std.math.log2e + 0.5);
    const remainder = (x - twos * ln2_high) - twos * ln2_low;
    assert(@abs(remainder) <= std.math.ln2 / 2.0 + 1e-12);
    const exponent: i64 = @intFromFloat(twos);
    assert(exponent >= -1022);
    assert(exponent <= 1023);
    const scale: f64 = @bitCast(@as(u64, @intCast(exponent + 1023)) << 52);
    return polynomial(&exp_terms, remainder) * scale;
}

/// e^x for any x: `exp` at or below 0, the same reduction up to `exp_ceiling`, and e^709 above
/// it (section 4a).
pub fn exponential(x: f64) f64 {
    if (std.math.isNan(x)) return x;
    if (x <= 0) return exp(x);
    const result = exp_reduced(if (x > exp_ceiling) exp_ceiling else x);
    assert(result >= 1);
    assert(std.math.isFinite(result));
    return result;
}

/// ln x for any x: `log` of a positive finite x, and held at the ends of the doubles otherwise
/// (section 4a).
pub fn logarithm(x: f64) f64 {
    if (std.math.isNan(x)) return x;
    if (!(x > 0)) return log_floor;
    if (x == std.math.inf(f64)) return log_ceiling;
    const result = log(x);
    assert(std.math.isFinite(result));
    return result;
}

/// `log` of the smallest and the largest positive doubles, worked out once, at compile time, by
/// the same function, so they are the bits a run would compute.
const log_floor: f64 = log_at_comptime(std.math.floatTrueMin(f64));
const log_ceiling: f64 = log_at_comptime(std.math.floatMax(f64));

fn log_at_comptime(comptime x: f64) f64 {
    @setEvalBranchQuota(10_000);
    return comptime log(x);
}

/// The square root of a positive x, and 0 for any other (section 4a).
pub fn square_root(x: f64) f64 {
    if (std.math.isNan(x)) return x;
    return if (x > 0) @sqrt(x) else 0;
}

/// x rounded to a whole number, a half away from zero, the sign of a zero kept (section 4a).
pub fn round_half_away(x: f64) f64 {
    if (std.math.isNan(x)) return x;
    const magnitude = @abs(x);
    // From 2^52 on, every double is whole, and an infinity is itself.
    if (!(magnitude < 0x1p52)) return x;
    const whole = @floor(magnitude);
    // Both exact: the fraction of a double below 2^52, and a whole number below 2^52 plus 1.
    const rounded = if (magnitude - whole >= 0.5) whole + 1 else whole;
    return if (std.math.signbit(x)) -rounded else rounded;
}

/// The fewest and the most factors `power` takes.
pub const power_min = 2;
pub const power_max = 8;

/// x to the whole power n, from `power_min` to `power_max`: x times itself n - 1 times, left to
/// right (section 4a).
pub fn power(x: f64, n: u8) f64 {
    assert(n >= power_min and n <= power_max);
    var result = x;
    for (1..n) |_| result = result * x;
    return result;
}

/// The sine of `x` radians (section 4a).
pub fn sine_radians(x: f64) f64 {
    if (std.math.isNan(x)) return x;
    if (!std.math.isFinite(x)) return 0;
    const value = sine_cosine(turns_of(@abs(x))).sine;
    return if (std.math.signbit(x)) -value else value;
}

/// The cosine of `x` radians (section 4a).
pub fn cosine_radians(x: f64) f64 {
    if (std.math.isNan(x)) return x;
    if (!std.math.isFinite(x)) return 1;
    return sine_cosine(turns_of(@abs(x))).cosine;
}

/// The part of a turn that `radians`, finite and at least 0, is past its whole turns: one
/// rounding in the division, and none in taking the whole turns off.
pub fn turns_of(radians: f64) f64 {
    assert(radians >= 0);
    assert(std.math.isFinite(radians));
    const turns = radians / std.math.tau;
    const result = turns - @floor(turns);
    assert(result >= 0);
    assert(result < 1);
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

// Locks section 4a's rounding: a half goes away from zero, -0.5 to -1, 0.5 to 1, 1.5 to 2, 2.5
// to 3, -2.5 to -3, the largest double below 0.5 to 0, -0.4 to -0; and it agrees with `@round`
// on this target for every one of them.
test "round takes a half away from zero" {
    const cases = [_][2]f64{
        .{ -0.5, -1 },               .{ 0.5, 1 },                 .{ 1.5, 2 },     .{ 2.5, 3 },
        .{ -2.5, -3 },               .{ -1.5, -2 },               .{ 0.4, 0 },     .{ -0.4, -0.0 },
        .{ 0.49999999999999994, 0 }, .{ 0x1p52 + 1, 0x1p52 + 1 }, .{ -0.0, -0.0 }, .{ 4503599627370495.5, 4503599627370496 },
    };
    for (cases) |case| {
        const got = round_half_away(case[0]);
        try testing.expectEqual(@as(u64, @bitCast(case[1])), @as(u64, @bitCast(got)));
        try testing.expectEqual(@as(u64, @bitCast(@round(case[0]))), @as(u64, @bitCast(got)));
    }
    try testing.expectEqual(std.math.inf(f64), round_half_away(std.math.inf(f64)));
}

// Locks the totals of section 4a: sqrt of -1, -0, and -inf is +0; ln of 0 and of -1 is the log of
// 2^-1074, about -744.44, and of +inf about 709.78; e^710 and e^inf are e^709; sin and cos of an
// infinity are 0 and 1; sin(-0) is -0; pow(x, 2) is x * x; and a NaN passes through each.
test "the functions of a value are total and finite" {
    for ([_]f64{ -1, -0.0, -std.math.inf(f64) }) |x| {
        try testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(square_root(x))));
    }
    try testing.expectEqual(@as(f64, 3), square_root(9));
    try testing.expectApproxEqAbs(@as(f64, -744.4400719213812), logarithm(0), 1e-12);
    try testing.expectEqual(logarithm(0), logarithm(-1));
    try testing.expectEqual(logarithm(0), logarithm(-std.math.inf(f64)));
    try testing.expectApproxEqAbs(@as(f64, 709.782712893384), logarithm(std.math.inf(f64)), 1e-12);
    try testing.expectEqual(exponential(709), exponential(710));
    try testing.expectEqual(exponential(709), exponential(std.math.inf(f64)));
    try testing.expectApproxEqRel(@as(f64, 8.218407461554972e307), exponential(709), 1e-15);
    try testing.expectEqual(exp(-1), exponential(-1));
    try testing.expectEqual(@as(f64, 0), exponential(-std.math.inf(f64)));
    try testing.expectApproxEqRel(@as(f64, std.math.e), exponential(1), 1e-15);
    try testing.expectEqual(@as(f64, 0), sine_radians(std.math.inf(f64)));
    try testing.expectEqual(@as(f64, 1), cosine_radians(-std.math.inf(f64)));
    try testing.expect(std.math.signbit(sine_radians(-0.0)));
    for ([_]f64{ 0.1, -1.7, 3e100 }) |x| try testing.expectEqual(x * x, power(x, 2));
    try testing.expectEqual(@as(f64, -3.375), power(-1.5, 3));
    const nan = std.math.nan(f64);
    const functions = [_]*const fn (f64) f64{ exponential, logarithm, square_root, round_half_away, sine_radians, cosine_radians };
    for (functions) |f| try testing.expect(std.math.isNan(f(nan)));
}

// Locks the radian sine and cosine against `@sin` and `@cos` of this target within 4e-16 from
// -10 to 10, and the oddness and evenness: sin(-x) is -sin(x) and cos(-x) is cos(x), bit for bit.
test "sine and cosine in radians are accurate and symmetric" {
    var x: f64 = -10;
    while (x <= 10) : (x += 0.0137) {
        try testing.expectApproxEqAbs(@sin(x), sine_radians(x), 4e-16 * @max(1, @abs(x)));
        try testing.expectApproxEqAbs(@cos(x), cosine_radians(x), 4e-16 * @max(1, @abs(x)));
        try testing.expectEqual(-sine_radians(x), sine_radians(-x));
        try testing.expectEqual(cosine_radians(x), cosine_radians(-x));
    }
}

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
