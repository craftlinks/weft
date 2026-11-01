//! Time: a signed 64-bit count of flicks, the one clock every Weft reader shares.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Integers
//! A caller supplies the time, so a reader at 60 Hz and a reader at 48 kHz must land on the same
//! instants without either one accumulating rounding. A flick is 1/705,600,000 s, chosen so that
//! the common frame rates and audio rates are whole numbers of flicks. Adding or comparing times
//! is then exact, and a `Time` cannot wrap or drift the way a float of seconds does.
//!
//! ## 2. Rate
//! A `Rate` is a clock with a whole number of flicks per tick, and `Rate.from_hz` refuses any other
//! rate. Video frames and audio samples are both ticks of a `Rate`, so one call, `from_ticks`,
//! serves both. A tick count that would overflow is refused, not wrapped.
//!
//! ## 3. Where Rounding Happens
//! Rounding happens only where a formula meets a time, and there are two such places.
//! `seconds` is for formulas that need a duration. `turns` is for periodic formulas, and it does
//! not go through `seconds`: it splits the time into whole seconds and the part of a second, and
//! drops the whole cycles of each piece before adding them. The precision of a periodic signal
//! therefore does not decay with distance from zero as `hz * seconds` would. With a whole number
//! of Hz, the whole seconds contribute exactly nothing, so a signal one second later has the same
//! bits, however far it is from zero.
//!
//! ## 4. TigerStyle Invariants
//! - No allocation, no state, no libc: every function here is pure and safe on an audio thread.
//! - `turns` returns a value in [0, 1) for every time and every finite frequency.

const std = @import("std");
const assert = std.debug.assert;

pub const flicks_per_second: i64 = 705_600_000;

const flicks_per_second_float: f64 = @floatFromInt(flicks_per_second);

comptime {
    // 2^9 * 3^2 * 5^5 * 7^2: the factors that 44.1 kHz, 48 kHz, 96 kHz and the frame rates need.
    assert(flicks_per_second == (1 << 9) * 9 * 3125 * 49);
    // The whole seconds of any `Time` are an exact f64, which `turns` relies on.
    assert(@divFloor(std.math.minInt(i64), flicks_per_second) > -(1 << 53));
    assert(@divFloor(std.math.maxInt(i64), flicks_per_second) < (1 << 53));
    assert(@sizeOf(Time) == @sizeOf(i64));
}

/// A clock whose ticks are a whole number of flicks.
pub const Rate = struct {
    flicks_per_tick: u32,

    /// The rate of `hz` ticks per second, or null if a tick is not a whole number of flicks.
    pub fn from_hz(hz: u32) ?Rate {
        if (hz == 0) return null;
        if (@mod(flicks_per_second, @as(i64, hz)) != 0) return null;
        const flicks_per_tick: u32 = @intCast(@divExact(flicks_per_second, @as(i64, hz)));
        assert(flicks_per_tick > 0);
        assert(@as(i64, flicks_per_tick) * hz == flicks_per_second);
        return .{ .flicks_per_tick = flicks_per_tick };
    }
};

pub const Time = struct {
    flicks: i64,

    /// The time of a frame or a sample: `tick` ticks of `rate` after time zero, or null if that
    /// does not fit in an i64.
    pub fn from_ticks(tick: i64, rate: Rate) ?Time {
        assert(rate.flicks_per_tick > 0);
        const product = @mulWithOverflow(tick, @as(i64, rate.flicks_per_tick));
        if (product[1] != 0) return null;
        assert(@rem(product[0], @as(i64, rate.flicks_per_tick)) == 0);
        return .{ .flicks = product[0] };
    }

    /// Seconds since time zero, for formulas that need a duration.
    pub fn seconds(time: Time) f64 {
        const result = @as(f64, @floatFromInt(time.flicks)) / flicks_per_second_float;
        assert(std.math.isFinite(result));
        if (time.flicks == 0) assert(result == 0);
        return result;
    }

    /// How far a cycle of `hz` has run at this time, in [0, 1). Section 3 explains the split.
    pub fn turns(time: Time, hz: f64) f64 {
        assert(std.math.isFinite(hz));
        const whole: f64 = @floatFromInt(@divFloor(time.flicks, flicks_per_second));
        const part: f64 = @floatFromInt(@mod(time.flicks, flicks_per_second));
        const part_seconds = part / flicks_per_second_float;
        assert(part_seconds >= 0);
        assert(part_seconds < 1);
        const result = fraction(fraction(hz * whole) + hz * part_seconds);
        assert(result >= 0);
        assert(result < 1);
        return result;
    }

    /// The part of `value` above its floor. A tiny negative value would round to exactly 1, which
    /// is the same turn as 0, and a product that overflowed has no position in a cycle.
    fn fraction(value: f64) f64 {
        const result = value - @floor(value);
        if (result < 1) return result;
        return 0;
    }
};

const testing = std.testing;

// Locks that every rate Weft promises is a whole number of flicks and that `hz` ticks are exactly
// one second: 60 Hz is 11,760,000 flicks a frame, and 48 kHz is 14,700 flicks a sample.
test "time conversions are exact for every promised rate" {
    const rates_hz = [_]u32{ 24, 25, 30, 50, 60, 90, 120, 144, 240, 44_100, 48_000, 96_000 };
    for (rates_hz) |hz| {
        const rate = Rate.from_hz(hz).?;
        const second = Time.from_ticks(hz, rate).?;
        try testing.expectEqual(flicks_per_second, second.flicks);
        try testing.expectEqual(@as(f64, 1), second.seconds());
    }
    try testing.expectEqual(@as(u32, 11_760_000), Rate.from_hz(60).?.flicks_per_tick);
    try testing.expectEqual(@as(u32, 14_700), Rate.from_hz(48_000).?.flicks_per_tick);
}

// Locks a 128-frame block at 48 kHz at 1,881,600 flicks, so a block boundary is an exact time.
test "an audio block is an exact time" {
    const rate = Rate.from_hz(48_000).?;
    const block = Time.from_ticks(128, rate).?;
    try testing.expectEqual(@as(i64, 1_881_600), block.flicks);
    const second_block = Time.from_ticks(128 * 2, rate).?;
    try testing.expectEqual(block.flicks * 2, second_block.flicks);
}

// Locks the refused rates: zero, one with a factor of 11, and one with too many factors of 2.
test "a rate that is not a whole number of flicks is refused" {
    try testing.expectEqual(@as(?Rate, null), Rate.from_hz(0));
    try testing.expectEqual(@as(?Rate, null), Rate.from_hz(11));
    try testing.expectEqual(@as(?Rate, null), Rate.from_hz(1024));
    try testing.expectEqual(@as(u32, 1), Rate.from_hz(705_600_000).?.flicks_per_tick);
    try testing.expectEqual(@as(?Rate, null), Rate.from_hz(705_600_001));
}

// Locks the reach of an i64 at about 414 years (of 365.25 days) either side of zero, and that a
// tick beyond it is refused on both sides instead of wrapping.
test "time reaches 414 years and refuses to wrap" {
    const rate = Rate.from_hz(60).?;
    const tick_last = @divFloor(std.math.maxInt(i64), @as(i64, rate.flicks_per_tick));
    const last = Time.from_ticks(tick_last, rate).?;
    const years = last.seconds() / (365.25 * 86_400);
    try testing.expectApproxEqAbs(@as(f64, 414.2), years, 0.1);
    try testing.expectEqual(@as(?Time, null), Time.from_ticks(tick_last + 1, rate));
    try testing.expectEqual(@as(?Time, null), Time.from_ticks(-tick_last - 2, rate));
    try testing.expectEqual(-last.flicks, Time.from_ticks(-tick_last, rate).?.flicks);
}

// Locks the turns of 1 Hz at a quarter second either side of zero: 0.25, and 0.75 before zero,
// where a truncating division would give a negative turn.
test "turns are measured from the floor, before and after zero" {
    const rate = Rate.from_hz(4).?;
    try testing.expectEqual(@as(f64, 0.25), Time.from_ticks(1, rate).?.turns(1));
    try testing.expectEqual(@as(f64, 0.75), Time.from_ticks(-1, rate).?.turns(1));
    try testing.expectEqual(@as(f64, 0), Time.from_ticks(-4, rate).?.turns(1));
    try testing.expectEqual(@as(f64, 0.75), Time.from_ticks(1, rate).?.turns(-1));
}

// Locks the edge of `fraction`: one second at -1e-20 Hz is -1e-20 turns, and -1e-20 - floor(-1e-20)
// rounds to exactly 1, which must wrap to 0.
test "a tiny negative turn stays below one" {
    const second = Time{ .flicks = flicks_per_second };
    try testing.expectEqual(@as(f64, 0), second.turns(-1e-20));
}

// Locks a frequency of zero as a constant turn of zero, and that a product too large for a double
// still answers inside [0, 1).
test "turns stay in range at the extremes of frequency" {
    const far = Time{ .flicks = std.math.maxInt(i64) };
    try testing.expectEqual(@as(f64, 0), far.turns(0));
    const turns_huge = far.turns(std.math.floatMax(f64));
    try testing.expect(turns_huge >= 0);
    try testing.expect(turns_huge < 1);
}

// Locks the promise of section 3: with whole Hz, one second later is the same bits, at an hour, a
// day, and a century, where `hz * seconds` has already lost bits.
test "a whole frequency repeats bit for bit far from zero" {
    const rate = Rate.from_hz(48_000).?;
    const epochs_seconds = [_]i64{ 3600, 86_400, 3_155_760_000 };
    for (epochs_seconds) |epoch_seconds| {
        var tick: i64 = 0;
        while (tick < 4096) : (tick += 37) {
            const near = Time.from_ticks(tick, rate).?;
            const far = Time.from_ticks(epoch_seconds * 48_000 + tick, rate).?;
            try testing.expectEqual(near.turns(440), far.turns(440));
        }
    }
}

/// The exact turn of `numerator / denominator` Hz, in integers.
fn turns_exact(time: Time, numerator: i128, denominator: i128) f64 {
    const modulus = denominator * flicks_per_second;
    const cycles = @mod(time.flicks * numerator, modulus);
    return @as(f64, @floatFromInt(cycles)) / @as(f64, @floatFromInt(modulus));
}

/// The distance between two turns, the short way round the cycle.
fn turns_distance(a: f64, b: f64) f64 {
    const distance = @abs(a - b);
    return @min(distance, 1 - distance);
}

// Locks the error of `turns` against exact integer arithmetic, at 0.7 Hz and 261.63 Hz, whose f64
// values are themselves rounded: under 8e-12 turns at an hour and a day, which is -206 dB against
// a sine of amplitude 1.
test "a fractional frequency keeps its precision at an hour and a day" {
    const rate = Rate.from_hz(44_100).?;
    const epochs_seconds = [_]i64{ 3600, 86_400 };
    for (epochs_seconds) |epoch_seconds| {
        var tick: i64 = 0;
        while (tick < 44_100) : (tick += 97) {
            const time = Time.from_ticks(epoch_seconds * 44_100 + tick, rate).?;
            const slow = turns_distance(time.turns(0.7), turns_exact(time, 7, 10));
            const fast = turns_distance(time.turns(261.63), turns_exact(time, 26_163, 100));
            try testing.expect(slow < 8e-12);
            try testing.expect(fast < 8e-12);
        }
    }
}
