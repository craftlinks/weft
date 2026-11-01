//! Easing: cubic Bezier curves from progress to eased progress.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. One Curve
//! An ease is the curve from (0, 0) to (1, 1) with two control points, as in CSS, and the named
//! eases are just values of it. So a client can write any ease, and the language has one thing to
//! describe. `linear` is a curve too, and it is computed by returning its input.
//!
//! ## 2. The Solver
//! The curve is given by a parameter: x(s) and y(s). A progress is an x, so finding y means solving
//! x(s) = progress first. With both x controls in [0, 1], x(s) never falls, so there is exactly one
//! answer, and `Ease.valid` refuses anything else. The y controls are free, so a curve can
//! overshoot.
//!
//! `solve` is Newton's method inside a bracket that always holds the answer. A Newton step that
//! leaves the bracket, or that failed to halve the miss, is replaced by a bisection. That covers
//! the two cases where plain Newton stalls: a flat start, where x1 is 0, and a flat middle, where
//! x1 is 1 and x2 is 0.
//!
//! ## 3. Realtime Safety
//! An ease runs on a reader's hot path, so the loop is capped at `solve_iterations_max`, and a test
//! locks how far below the cap real curves stay. The smallest progress a tween can ask for is one
//! flick of the longest duration, `progress_smallest`. Below that, on a flat start, the cap can end
//! the search early, with a value that is still in range and off by far less than any step of time.
//! It uses only f64 arithmetic, so native and wasm agree bit for bit, as they do for the sine.
//!
//! ## 4. TigerStyle Invariants
//! - `apply` is pure, and returns exactly 0 at 0 and exactly 1 at 1 for every valid ease.
//! - No allocation, no state, and one bounded loop.

const std = @import("std");
const assert = std.debug.assert;

const solve_iterations_max = 64;

/// How close x(s) must come to the target, relative to it: about eight units in the last place.
/// The rounding of x(s) follows its intermediate sums, which can be larger than the target, and it
/// reaches about four units of the target. A goal below that noise is never met, and the search
/// then reads a correct answer as a stall and bisects away from it.
const solve_tolerance: f64 = 0x1p-49;

/// One flick of a duration of 2^63 flicks.
const progress_smallest: f64 = 0x1p-63;

pub const Ease = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,

    pub const linear: Ease = .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1 };
    pub const in: Ease = .{ .x1 = 0.42, .y1 = 0, .x2 = 1, .y2 = 1 };
    pub const out: Ease = .{ .x1 = 0, .y1 = 0, .x2 = 0.58, .y2 = 1 };
    pub const in_out: Ease = .{ .x1 = 0.42, .y1 = 0, .x2 = 0.58, .y2 = 1 };

    /// Whether `apply` can use this curve: finite, with both x controls in [0, 1].
    pub fn valid(ease: Ease) bool {
        if (!(ease.x1 >= 0)) return false;
        if (!(ease.x1 <= 1)) return false;
        if (!(ease.x2 >= 0)) return false;
        if (!(ease.x2 <= 1)) return false;
        if (!std.math.isFinite(ease.y1)) return false;
        return std.math.isFinite(ease.y2);
    }

    /// The eased value of `progress`, which is in [0, 1].
    pub fn apply(ease: Ease, progress: f64) f64 {
        assert(progress >= 0);
        assert(progress <= 1);
        if (progress == 0) return 0;
        if (progress == 1) return 1;
        // The two coordinates are the same polynomial, so the curve is the line y = x.
        if (ease.x1 == ease.y1) {
            if (ease.x2 == ease.y2) return progress;
        }
        const solution = solve(ease.x1, ease.x2, progress);
        return curve(solution.parameter, ease.y1, ease.y2);
    }
};

/// One coordinate of the curve at parameter `s`, with controls `a` and `b` between 0 and 1.
fn curve(s: f64, a: f64, b: f64) f64 {
    const rest = 1 - s;
    return s * (3 * rest * (rest * a + s * b) + s * s);
}

fn curve_slope(s: f64, a: f64, b: f64) f64 {
    const rest = 1 - s;
    return 3 * (rest * rest * a + 2 * rest * s * (b - a) + s * s * (1 - b));
}

const Solution = struct {
    parameter: f64,
    iterations: u32,
};

/// The `s` where x(s) is `target`, by bracketed Newton. Section 2 explains the fallback.
fn solve(x1: f64, x2: f64, target: f64) Solution {
    assert(target > 0);
    assert(target < 1);
    var low: f64 = 0;
    var high: f64 = 1;
    var parameter = target;
    var miss_previous = std.math.inf(f64);
    for (1..solve_iterations_max + 1) |iteration| {
        const miss = curve(parameter, x1, x2) - target;
        if (@abs(miss) <= solve_tolerance * target) {
            return .{ .parameter = parameter, .iterations = @intCast(iteration) };
        }
        if (miss > 0) high = parameter else low = parameter;

        // A slope of zero gives an infinite or NaN step, which the comparisons below reject.
        const newton = parameter - miss / curve_slope(parameter, x1, x2);
        const middle = low + (high - low) / 2;
        const stalled = @abs(miss) > miss_previous / 2;
        const inside = newton > low and newton < high;
        const next = if (inside and !stalled) newton else middle;
        miss_previous = @abs(miss);
        // The bracket has closed to adjacent doubles, so nothing is left to find.
        if (next <= low or next >= high) {
            return .{ .parameter = parameter, .iterations = @intCast(iteration) };
        }
        parameter = next;
    }
    return .{ .parameter = parameter, .iterations = solve_iterations_max };
}

const testing = std.testing;

// Locks the ends of every kind of curve: exactly 0 and exactly 1, including one that overshoots
// on the way and one with a flat middle.
test "every ease starts at exactly 0 and lands at exactly 1" {
    const eases = [_]Ease{
        .linear,
        .in,
        .out,
        .in_out,
        .{ .x1 = 0.34, .y1 = 1.56, .x2 = 0.64, .y2 = 1 },
        .{ .x1 = 1, .y1 = 0, .x2 = 0, .y2 = 1 },
    };
    for (eases) |ease| {
        try testing.expectEqual(@as(f64, 0), ease.apply(0));
        try testing.expectEqual(@as(f64, 1), ease.apply(1));
    }
}

// Locks that linear returns its input bit for bit, with no solver in the way, for a line with any
// controls on it.
test "a curve on the line y = x returns its input" {
    const on_line = Ease{ .x1 = 0.2, .y1 = 0.2, .x2 = 0.9, .y2 = 0.9 };
    for ([_]f64{ 1e-300, 0.1, 0.3, 0.7, 1 - 1e-16 }) |progress| {
        try testing.expectEqual(progress, Ease.linear.apply(progress));
        try testing.expectEqual(progress, on_line.apply(progress));
    }
}

// Locks worked values at the quarters, computed apart from this code by bisecting the exact
// rational curve 90 times: in at a half is 0.31536, out is its mirror, 0.68464, and in-out is 0.5
// at a half. The last row is an overshooting curve, which peaks above 1.
test "the named eases give their worked values" {
    const rows = [_]struct { ease: Ease, values: [3]f64 }{
        .{ .ease = .in, .values = .{
            0.09346465071882486, 0.3153568125725393, 0.6218618691748902,
        } },
        .{ .ease = .out, .values = .{
            0.3781381308251098, 0.6846431874274607, 0.9065353492811752,
        } },
        .{ .ease = .in_out, .values = .{
            0.12916193104731982, 0.5, 0.8708380689526802,
        } },
        .{ .ease = .{ .x1 = 0.34, .y1 = 1.56, .x2 = 0.64, .y2 = 1 }, .values = .{
            0.8162891986924717, 1.0874006702186978, 1.0596468599640332,
        } },
    };
    for (rows) |row| {
        for (row.values, [_]f64{ 0.25, 0.5, 0.75 }) |value, progress| {
            try testing.expectApproxEqAbs(value, row.ease.apply(progress), 2e-15);
        }
    }
}

// Locks the mirror symmetry of the presets: out is in, turned through a half turn.
test "out mirrors in" {
    var index: u32 = 1;
    while (index < 1000) : (index += 1) {
        const progress = @as(f64, @floatFromInt(index)) / 1000;
        const mirror = 1 - Ease.in.apply(1 - progress);
        try testing.expectApproxEqAbs(mirror, Ease.out.apply(progress), 4e-15);
    }
}

// Locks that a curve whose y controls stay in [0, 1] never falls, so a tween never runs backwards.
test "a curve with its controls in range never falls" {
    var before: f64 = 0;
    var index: u32 = 1;
    while (index <= 4096) : (index += 1) {
        const value = Ease.in_out.apply(@as(f64, @floatFromInt(index)) / 4096);
        try testing.expect(value >= before);
        before = value;
    }
}

// Locks the solver's bound. Over every pair of x controls in tenths, including the flat cases of
// section 2, 1,000 evenly spaced targets take at most 12 iterations, and the extremes a tween can
// reach take at most 40, under the cap of 64. Every one lands within the tolerance. With a goal
// inside the rounding noise, cases like x1 = 0.8, x2 = 0.3, target 0.3275 take 34 and not 8.
test "the solver stays under its iteration bound" {
    const targets_extra = [_]f64{ progress_smallest, 1e-15, 1e-9, 1 - 1e-9, 1 - 1e-15 };
    var iterations_even_max: u32 = 0;
    var iterations_extreme_max: u32 = 0;
    for (0..11) |tenth_first| {
        for (0..11) |tenth_second| {
            const x1 = @as(f64, @floatFromInt(tenth_first)) / 10;
            const x2 = @as(f64, @floatFromInt(tenth_second)) / 10;
            for (0..1000 + targets_extra.len) |index| {
                const target = if (index < targets_extra.len)
                    targets_extra[index]
                else
                    (@as(f64, @floatFromInt(index - targets_extra.len)) + 0.5) / 1000;
                const solution = solve(x1, x2, target);
                if (index < targets_extra.len) {
                    iterations_extreme_max = @max(iterations_extreme_max, solution.iterations);
                } else {
                    iterations_even_max = @max(iterations_even_max, solution.iterations);
                }
                const miss = @abs(curve(solution.parameter, x1, x2) - target);
                try testing.expect(miss <= solve_tolerance * target);
            }
        }
    }
    try testing.expect(iterations_even_max <= 12);
    try testing.expect(iterations_extreme_max <= 40);
}

// Locks the cap itself, on the hardest case: a curve flat at its start, at a progress no tween can
// reach. The search stops at 64 iterations and the answer is in range and off by under 1e-30.
test "the cap ends the search with a usable answer" {
    const solution = solve(0, 0, 1e-300);
    try testing.expectEqual(@as(u32, solve_iterations_max), solution.iterations);
    try testing.expect(solution.parameter > 0);
    try testing.expect(curve(solution.parameter, 0, 0) < 1e-30);
    const value = (Ease{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 1 }).apply(1e-300);
    try testing.expect(value >= 0);
    try testing.expect(value < 1e-10);
}

// Locks what `valid` refuses: x controls outside [0, 1] and anything not finite, while y controls
// may leave [0, 1].
test "valid refuses a curve that could fall back on itself" {
    try testing.expect(Ease.linear.valid());
    try testing.expect((Ease{ .x1 = 0, .y1 = -2, .x2 = 1, .y2 = 3 }).valid());
    try testing.expect(!(Ease{ .x1 = -0.1, .y1 = 0, .x2 = 1, .y2 = 1 }).valid());
    try testing.expect(!(Ease{ .x1 = 0, .y1 = 0, .x2 = 1.1, .y2 = 1 }).valid());
    const nan = std.math.nan(f64);
    try testing.expect(!(Ease{ .x1 = nan, .y1 = 0, .x2 = 1, .y2 = 1 }).valid());
    try testing.expect(!(Ease{ .x1 = 0, .y1 = 0, .x2 = nan, .y2 = 1 }).valid());
    try testing.expect(!(Ease{ .x1 = 0, .y1 = nan, .x2 = 1, .y2 = 1 }).valid());
    try testing.expect(!(Ease{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = std.math.inf(f64) }).valid());
}
