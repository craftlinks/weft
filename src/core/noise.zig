//! Noise: smooth and stepped random signals, each a pure function of a seed and time.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. No Generator
//! There is no random generator and no state. A noise is a lattice of values, one per cycle of its
//! frequency, and each value is a hash of the seed and the cycle's index. So a reader can ask for
//! any time in any order, two runs are the same run, and two readers of one seed agree.
//!
//! ## 2. The Hash
//! `hash` is the finalizer of SplitMix64 applied twice, once to each input, with wrapping integer
//! arithmetic only. Every target computes it the same way, and it does not depend on a hash in
//! `std`, whose output a later Zig could change under the goldens. Mixing the index before adding
//! the seed means two seeds give unrelated lattices, rather than one lattice shifted by a cell.
//!
//! A lattice value is the top 53 bits of the hash, scaled to [-1, 1). Every such value is an exact
//! f64, so the mapping from hash to value has no rounding.
//!
//! ## 3. Smooth and Steps
//! `steps` holds each lattice value for its whole cycle. `smooth` is a uniform cubic B-spline over
//! the lattice: four neighbouring values per cycle, joined with continuous velocity and
//! acceleration, so a motion driven by it never jerks and never pauses at a lattice point. The
//! spline does not pass through the lattice values, so its amplitude is lower than that of steps.
//!
//! The spline is evaluated by de Boor's algorithm, six interpolations of the form
//! `a * (1 - w) + b * w` with `w` in [0, 1]. With `a` and `b` in [-1, 1], that form cannot round
//! out of [-1, 1]: each product is at most its weight in magnitude, and the two weights round to a
//! sum of at most 1. So the result stays in range by construction and not only in practice. The
//! bound is 1 and not the larger of `|a|` and `|b|`, which the form can pass by a unit in the last
//! place.
//!
//! ## 4. Seeds in a Graph
//! A noise's own `seed` is used as it is. In a graph, the builder derives each node's seed from the
//! graph's seed and the node's `seed`, with `derive`, so changing the graph's seed gives a new take
//! of every noise at once. A node's `seed` is a stable id the caller chooses, not its position, so
//! inserting a node does not reshuffle the others.
//!
//! ## 5. TigerStyle Invariants
//! - No allocation, no state, no libc, and no loops: safe on an audio thread.
//! - Every shape returns a value in [-1, 1] for every time.

const std = @import("std");
const assert = std.debug.assert;
const time_module = @import("time.zig");
const Time = time_module.Time;

pub const Shape = enum {
    /// A cubic B-spline over the lattice, with continuous velocity and acceleration.
    smooth,
    /// Each lattice value, held for its whole cycle.
    steps,
};

pub const Noise = struct {
    shape: Shape,
    /// Lattice values per second, above 0 and at most `hz_max`.
    hz: f64,
    seed: u64,

    pub const hz_max = time_module.cycles_hz_max;

    /// The value of the noise at `time`, in [-1, 1].
    pub fn sample(noise: Noise, time: Time) f64 {
        assert(noise.hz > 0);
        assert(noise.hz <= hz_max);
        const cycles = time.cycles(noise.hz);
        const result = switch (noise.shape) {
            .smooth => smooth_at(noise.seed, cycles.whole, cycles.fraction),
            .steps => lattice(noise.seed, cycles.whole),
        };
        assert(result >= -1);
        assert(result <= 1);
        return result;
    }

    /// This noise as a node of a graph whose seed is `graph_seed`. Section 4 explains why.
    pub fn derive(noise: Noise, graph_seed: u64) Noise {
        var result = noise;
        result.seed = hash(graph_seed, noise.seed);
        assert(result.hz == noise.hz);
        return result;
    }
};

/// The SplitMix64 increment, 2^64 divided by the golden ratio, rounded to odd.
const gamma: u64 = 0x9e3779b97f4a7c15;

/// The finalizer of SplitMix64 (Steele, Lea, and Flood, 2014, with Stafford's "Mix13" constants)
/// after one increment, so `mix(0)` is the first output of SplitMix64 seeded with 0.
fn mix(value: u64) u64 {
    var z = value +% gamma;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// A 64-bit hash of a seed and a key. Section 2 explains its form.
pub fn hash(seed: u64, key: u64) u64 {
    return mix(seed +% mix(key));
}

/// The lattice value of cycle `index`, in [-1, 1).
fn lattice(seed: u64, index: i64) f64 {
    const bits = hash(seed, @bitCast(index)) >> 11;
    assert(bits < 1 << 53);
    // `bits * 2^-52` is exact and below 2, and taking 1 from it is exact.
    const result = @as(f64, @floatFromInt(bits)) * 0x1p-52 - 1;
    assert(result >= -1);
    assert(result < 1);
    return result;
}

/// The uniform cubic B-spline over cycles `index - 1` to `index + 2`, `fraction` of the way from
/// `index` to `index + 1`. De Boor's algorithm, as section 3 explains.
fn smooth_at(seed: u64, index: i64, fraction: f64) f64 {
    assert(fraction >= 0);
    assert(fraction < 1);
    const p0 = lattice(seed, index - 1);
    const p1 = lattice(seed, index);
    const p2 = lattice(seed, index + 1);
    const p3 = lattice(seed, index + 2);
    const q0 = interpolate(p0, p1, (fraction + 2) / 3);
    const q1 = interpolate(p1, p2, (fraction + 1) / 3);
    const q2 = interpolate(p2, p3, fraction / 3);
    const r0 = interpolate(q0, q1, (fraction + 1) / 2);
    const r1 = interpolate(q1, q2, fraction / 2);
    return interpolate(r0, r1, fraction);
}

/// The point `weight` of the way from `a` to `b`, both in [-1, 1], which stays in [-1, 1] as
/// section 3 explains. `a + (b - a) * weight` would not.
fn interpolate(a: f64, b: f64, weight: f64) f64 {
    assert(@abs(a) <= 1);
    assert(@abs(b) <= 1);
    assert(weight >= 0);
    assert(weight <= 1);
    const result = a * (1 - weight) + b * weight;
    assert(@abs(result) <= 1);
    return result;
}

const testing = std.testing;
const Rate = time_module.Rate;

/// The time of `numerator / denominator` of a second.
fn time_at(numerator: i64, denominator: u32) Time {
    return Time.from_ticks(numerator, Rate.from_hz(denominator).?).?;
}

// Locks the hash to SplitMix64 itself, as `std` implements it: `mix` of the n-th multiple of the
// increment is its (n + 1)-th output from seed 0, and the first is 0xe220a8397b1dcdaf.
test "the hash finalizer is SplitMix64" {
    try testing.expectEqual(@as(u64, 0xe220a8397b1dcdaf), mix(0));
    var reference = std.Random.SplitMix64.init(0);
    var state: u64 = 0;
    for (0..1000) |_| {
        try testing.expectEqual(reference.next(), mix(state));
        state +%= gamma;
    }
}

// Locks the extremes of the lattice mapping: a hash of all zeros is -1 and of all ones is
// 1 - 2^-52, and each step of the top 53 bits is 2^-52.
test "lattice values span [-1, 1) in exact steps" {
    try testing.expectEqual(@as(f64, -1), @as(f64, @floatFromInt(@as(u64, 0))) * 0x1p-52 - 1);
    const top: u64 = std.math.maxInt(u64) >> 11;
    const highest = @as(f64, @floatFromInt(top)) * 0x1p-52 - 1;
    try testing.expectEqual(1 - 0x1p-52, highest);
    const below = @as(f64, @floatFromInt(top - 1)) * 0x1p-52 - 1;
    try testing.expectEqual(0x1p-52, highest - below);
}

// Locks the demo of this step: one second of each shape at 48 kHz, read forwards, backwards, and
// in a scattered order, gives the same bits, as does a second reader of the same seed.
test "the order of reading changes nothing" {
    for (std.enums.values(Shape)) |shape| {
        const noise = Noise{ .shape = shape, .hz = 7.3, .seed = 41 };
        var forward: [48_000]f64 = undefined;
        for (&forward, 0..) |*value, tick| value.* = noise.sample(time_at(@intCast(tick), 48_000));

        var tick: i64 = forward.len;
        while (tick > 0) {
            tick -= 1;
            const index: usize = @intCast(tick);
            try testing.expectEqual(forward[index], noise.sample(time_at(tick, 48_000)));
        }

        const twin = Noise{ .shape = shape, .hz = 7.3, .seed = 41 };
        var hop: usize = 0;
        for (0..forward.len) |_| {
            hop = (hop + 7919) % forward.len;
            try testing.expectEqual(forward[hop], twin.sample(time_at(@intCast(hop), 48_000)));
        }
    }
}

const Statistics = struct {
    min: f64,
    max: f64,
    mean: f64,
    deviation: f64,
};

/// Statistics of 40,000 samples of `noise` at 100 Hz, from `tick_first` at 48 kHz. A stride of
/// 1,201 ticks is just over 2.5 cycles, and coprime to the 480 ticks of a cycle, so the samples
/// cover 100,000 cycles and every part of a cycle.
fn statistics_of(shape: Shape, seed: u64, tick_first: i64) Statistics {
    const noise = Noise{ .shape = shape, .hz = 100, .seed = seed };
    const stride_ticks = 1201;
    const count = 40_000;
    var min: f64 = 1;
    var max: f64 = -1;
    var sum: f64 = 0;
    var sum_squares: f64 = 0;
    for (0..count) |index| {
        const tick = tick_first + @as(i64, @intCast(index)) * stride_ticks;
        const value = noise.sample(time_at(tick, 48_000));
        min = @min(min, value);
        max = @max(max, value);
        sum += value;
        sum_squares += value * value;
    }
    const count_float: f64 = @floatFromInt(count);
    const mean = sum / count_float;
    return .{
        .min = min,
        .max = max,
        .mean = mean,
        .deviation = @sqrt(sum_squares / count_float - mean * mean),
    };
}

// Locks the rough statistics of each shape over 100,000 cycles, for three seeds a day apart:
// within [-1, 1], a mean within 0.01 of 0, and a deviation near its expected value. For steps
// that is a uniform's, 1/sqrt(3) = 0.577. For smooth it is 0.400: the uniform's variance times
// 151/315, the integral of the squared cubic B-spline.
test "noise stays in range, centred, with the expected spread" {
    const seeds = [_]u64{ 0, 1, 0xdead_beef };
    for (seeds, 0..) |seed, index| {
        const tick_first = @as(i64, @intCast(index)) * 86_400 * 48_000;
        const steps = statistics_of(.steps, seed, tick_first);
        try testing.expect(steps.min >= -1);
        try testing.expect(steps.max < 1);
        try testing.expect(@abs(steps.mean) < 0.01);
        try testing.expectApproxEqAbs(1.0 / @sqrt(3.0), steps.deviation, 0.01);

        const smooth = statistics_of(.smooth, seed, tick_first);
        try testing.expect(smooth.min >= -1);
        try testing.expect(smooth.max <= 1);
        try testing.expect(@abs(smooth.mean) < 0.01);
        try testing.expectApproxEqAbs(@sqrt(151.0 / 315.0 / 3.0), smooth.deviation, 0.01);
    }
}

// Locks the bound of section 3. A million interpolations between random ends in [-1, 1], with
// the ends themselves and equal ends among them, stay in [-1, 1]. A tighter bound would be wrong:
// both ends -0.4808093018525951 at a weight of 0.13959020253881432 give a value past them.
test "an interpolation cannot round out of [-1, 1]" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    for (0..1_000_000) |index| {
        const a = switch (index % 4) {
            0 => -1,
            1 => 1,
            else => random.float(f64) * 2 - 1,
        };
        const b = if (index % 3 == 0) a else random.float(f64) * 2 - 1;
        const weight = random.float(f64);
        try testing.expect(@abs(interpolate(a, b, weight)) <= 1);
    }
    const end: f64 = -0.4808093018525951;
    try testing.expect(interpolate(end, end, 0.13959020253881432) < end);
}

// Locks that steps hold each lattice value for exactly a cycle: at 2 Hz the value changes between
// the last flick before a half second and the half second, and nowhere inside the half.
test "steps change only at a cycle boundary" {
    const noise = Noise{ .shape = .steps, .hz = 2, .seed = 5 };
    const half: i64 = @divExact(time_module.flicks_per_second, 2);
    for (0..8) |index| {
        const start = @as(i64, @intCast(index)) * half;
        const held = noise.sample(.{ .flicks = start });
        try testing.expectEqual(held, noise.sample(.{ .flicks = start + half - 1 }));
        try testing.expectEqual(held, noise.sample(.{ .flicks = start + 12_345_678 }));
        try testing.expect(held != noise.sample(.{ .flicks = start + half }));
    }
}

// Locks the continuity of smooth across cycle boundaries. At the last fraction below 1 of each of
// 1,000 cycles, the spline is within 4e-15 of the next cycle's start, which is rounding and not a
// step. In time, a flick either side of a boundary at 3 Hz differs by under 1e-7, about the slope
// of the spline times the 4.3e-9 cycles a flick lasts.
test "smooth noise is continuous across cycles" {
    var largest: f64 = 0;
    for (0..1000) |index| {
        const cycle = @as(i64, @intCast(index)) - 500;
        const end = smooth_at(9, cycle, 1 - 0x1p-53);
        largest = @max(largest, @abs(smooth_at(9, cycle + 1, 0) - end));
    }
    try testing.expect(largest < 4e-15);

    const noise = Noise{ .shape = .smooth, .hz = 3, .seed = 9 };
    const cycle_flicks: i64 = @divExact(time_module.flicks_per_second, 3);
    for (0..1000) |index| {
        const boundary = (@as(i64, @intCast(index)) - 500) * cycle_flicks;
        const before = noise.sample(.{ .flicks = boundary - 1 });
        try testing.expect(@abs(noise.sample(.{ .flicks = boundary }) - before) < 1e-7);
    }
}

// Locks that seeds give unrelated lattices: across 4,096 cycles, seeds 0 and 1, and seed 0 against
// itself one cycle on, correlate by less than 0.05.
test "neighbouring seeds and cycles are unrelated" {
    const count = 4096;
    var sum_seeds: f64 = 0;
    var sum_shift: f64 = 0;
    for (0..count) |index| {
        const cycle: i64 = @intCast(index);
        const a = lattice(0, cycle);
        sum_seeds += a * lattice(1, cycle);
        sum_shift += a * lattice(0, cycle + 1);
    }
    // A uniform on [-1, 1) has a variance of 1/3.
    const variance_sum: f64 = @as(f64, count) / 3;
    try testing.expect(@abs(sum_seeds / variance_sum) < 0.05);
    try testing.expect(@abs(sum_shift / variance_sum) < 0.05);
}

// Locks the extremes: the fastest noise at the first and last flicks, and a noise at 1e-6 Hz,
// which spends 11 days in each cycle, all answer inside [-1, 1].
test "noise answers at the ends of time and frequency" {
    for (std.enums.values(Shape)) |shape| {
        for ([_]f64{ Noise.hz_max, 1e-6 }) |hz| {
            const noise = Noise{ .shape = shape, .hz = hz, .seed = 3 };
            for ([_]i64{ std.math.minInt(i64), 0, std.math.maxInt(i64) }) |flicks| {
                const value = noise.sample(.{ .flicks = flicks });
                try testing.expect(@abs(value) <= 1);
            }
        }
    }
}

// Locks `derive`: the seed changes with the graph's seed, deterministically, and nothing else
// does.
test "a derived seed depends on the graph seed and the node seed" {
    const noise = Noise{ .shape = .smooth, .hz = 2, .seed = 7 };
    const first = noise.derive(1);
    try testing.expectEqual(first, noise.derive(1));
    try testing.expect(first.seed != noise.derive(2).seed);
    const neighbour = Noise{ .shape = .smooth, .hz = 2, .seed = 8 };
    try testing.expect(first.seed != neighbour.derive(1).seed);
    try testing.expectEqual(noise.shape, first.shape);
    try testing.expectEqual(noise.hz, first.hz);
}
