//! Waves: sine, triangle, saw, and square, each a pure function of time.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Pure Functions of Time
//! A wave holds no state, so a reader can ask for any time in any order and a run can never differ
//! from another one. All four shapes are bipolar, in [-1, 1], and start a cycle at time zero.
//! `Time.turns` turns the time into a position in the cycle, and everything here works in turns.
//!
//! ## 2. The Sine
//! The sine is `elementary.sine`, which Weft computes itself so that native and wasm agree bit for
//! bit, and which works in turns, so its zeros and peaks are exact.
//!
//! ## 3. TigerStyle Invariants
//! - No allocation, no state, no libc, and no loops of its own: safe on an audio thread.
//! - Every shape returns a value in [-1, 1] for a position in [0, 1).

const std = @import("std");
const assert = std.debug.assert;
const Time = @import("time.zig").Time;
const elementary = @import("elementary.zig");

pub const Shape = enum {
    /// Starts at 0 and rises; 1 at a quarter of the cycle, -1 at three quarters.
    sine,
    /// Passes through 0, 1, 0, -1 at the quarters of the cycle, with straight lines between.
    triangle,
    /// Rises from -1 towards 1 over the cycle, then falls back at once.
    saw,
    /// 1 for the first half of the cycle and -1 for the second.
    square,

    /// The shape's value at `turns` into its cycle, in [0, 1), which is in [-1, 1]. An oscillator
    /// reads it at a phase it keeps; a wave at the phase of its time.
    pub fn at(shape: Shape, turns: f64) f64 {
        assert(turns >= 0);
        assert(turns < 1);
        const result = switch (shape) {
            .sine => elementary.sine(turns),
            .triangle => triangle_at(turns),
            .saw => saw_at(turns),
            .square => square_at(turns),
        };
        assert(result >= -1);
        assert(result <= 1);
        return result;
    }
};

pub const Wave = struct {
    shape: Shape,
    hz: f64,
    /// How much later each lane of a graph's lane region reads it (`graph.zig`, section 16). A
    /// sample ignores it.
    stagger: Time = .{ .flicks = 0 },

    /// The value of the wave at `time`, in [-1, 1].
    pub fn sample(wave: Wave, time: Time) f64 {
        assert(std.math.isFinite(wave.hz));
        const turns = time.turns(wave.hz);
        const result = wave.shape.at(turns);
        assert(result >= -1);
        assert(result <= 1);
        return result;
    }
};

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
