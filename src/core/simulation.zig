//! Simulated signals: a fixed step, seeded draws, a goal follower, and a shift register.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. One Fixed Step
//! Some signals have no closed form: a goal follower decides its next goal when it arrives, and a
//! shift register's buckets carry every change before them. They run on one internal step, `step`,
//! 1/480 s, the same for every graph and every reader. A reader's rate never reaches a simulation,
//! so a reader at 30 Hz and one at 240 Hz see the same states. 480 is a multiple of the common
//! frame rates, so those readers land on steps exactly; any other reader lands between two, and
//! `graph.zig` interpolates, as its section 9 explains.
//!
//! ## 2. Steps From a Start
//! A simulation starts at a cue, so moving the cue moves it, and steps n = 0, 1, 2, ... sit at the
//! start plus n steps. The state at step 0 depends only on the program, never on a time, so it can
//! be rebuilt at any moment and needs no memory. Every step after it is a function of the state
//! before it and of the step's index, so reaching a step from any earlier copy of the state gives
//! the same bits.
//!
//! ## 3. Draws Instead of a Generator
//! A random choice is a draw: a hash of the node's seed, the choice's purpose, and an index that
//! the simulation counts, such as the number of goals so far. The hash is `noise.hash`, so a draw
//! is the same on every target, and a node's seed is derived from the graph's as a noise's is. A
//! unit draw is the top 53 bits of a draw scaled into [0, 1), which is exact.
//!
//! ## 4. The Goal Follower
//! A follower moves toward a goal with an exact step 5 motion, one step at a time from wherever it
//! is, so a new goal keeps the velocity. Once both its distance to the goal and its speed are
//! within `tolerance`, it has arrived and draws a pause, a whole number of steps. When the pause
//! runs out it draws its next goal, from the next region in turn or from a drawn one, at a drawn
//! place inside it. It keeps settling during a pause, so its motion never freezes. Arriving is an
//! event, and `follower_step` says when it happens.
//!
//! ## 5. The Shift Register
//! A shift register holds `buckets` values and visits them in turn, once per `period`. Bucket
//! boundaries are integer flicks from the start, so a pass never drifts. Each time it enters a
//! bucket, the bucket two behind, the one behind the bucket it left, is replaced by a drawn value
//! when another draw is below `odds`. The buckets it reads around the present are never the one
//! being replaced, so a smooth shape does not jump. Odds of 0 repeat every period, and odds of 1
//! never repeat. A bucket lasts at least one step, so a step enters at most one bucket. Entering a
//! bucket is an event, at its boundary, `shift_boundary`, an exact integer of flicks.
//!
//! ## 6. TigerStyle Invariants
//! - No allocation and no locks. A step of a follower is one motion step and at most two draws; a
//!   step of a shift register crosses at most one boundary.
//! - The region table is immutable once built, and a refused `add` leaves it as it was.
//! - Every counter a slab holds as an f64 stays below 2^53, so it is exact.
//!
//! ## 7. Bounded State
//! A loop through a delay can grow without end: `chase(1 + fb * 1.5, ...)` doubles about every
//! quarter second. So every value a simulated node reads from another node, and every value it
//! stores, passes through `bounded`: NaN reads as 0, and anything else is clamped to
//! `state_bound`. A runaway loop climbs to the bound and stays there, the same bits in every build
//! mode, and comes back down when a track turns its gain back. The builder keeps every constant
//! that becomes a moving value or a goal within the bound too, so no motion starts outside it.
//!
//! The bound is 2^256, so that one step from a state at the bound cannot overflow:
//! - A spring step from an offset of at most 2^257 and a velocity of at most 2^256, with omega
//!   below 2^33 (a time of one flick), stays below about 2^330.
//! - A Newtonian plan forms `2 accel decel ahead`, at most about 2^770.
//! - A pure product of two saturated values is 2^512, still finite. Four can overflow, so a client
//!   checks `State.finite` after an `eval` of a program with a loop.

const std = @import("std");
const assert = std.debug.assert;
const motion = @import("motion.zig");
const noise = @import("noise.zig");
const time_module = @import("time.zig");
const Time = time_module.Time;

/// The one simulation step: 1/480 s.
pub const step: Time = .{ .flicks = 1_470_000 };

/// The step in seconds, for the closed forms of `motion.zig`.
pub const step_seconds: f64 = 1.0 / 480.0;

/// Steps between two checkpoints of a reader: one a second.
pub const checkpoint_interval: u64 = 480;

/// The most buckets a shift register can hold.
pub const buckets_max = 64;

/// The longest shift register period, so that its positions convert to f64 exactly.
pub const period_flicks_max: u64 = 1 << 53;

/// The longest pause of a follower, in steps: about 103 days.
pub const pause_steps_max: u64 = std.math.maxInt(u32);

const step_flicks: u64 = @intCast(step.flicks);

/// The most a simulated value can hold, either way, as section 7 explains.
pub const state_bound: f64 = 0x1p256;

/// A value as a simulated node reads or stores it: NaN as 0, and anything else clamped to
/// `state_bound` (section 7).
pub inline fn bounded(value: f64) f64 {
    // A simulated node reads and stores through this every step, and almost every value is
    // inside, so that is one compare that the branch predictor gets right. NaN fails it.
    if (@abs(value) <= state_bound) return value;
    if (value > 0) return state_bound;
    if (value < 0) return -state_bound;
    return 0;
}

/// Whether a builder constant may become a moving value or a goal (section 7).
pub fn within_bound(value: f64) bool {
    return std.math.isFinite(value) and @abs(value) <= state_bound;
}

/// `kinematics` with its position and velocity bounded.
pub fn bounded_kinematics(kinematics: motion.Kinematics) motion.Kinematics {
    return .{ .position = bounded(kinematics.position), .velocity = bounded(kinematics.velocity) };
}

comptime {
    assert(step.flicks * 480 == time_module.flicks_per_second);
    // A search for a goal reached starts from one step.
    assert(step.flicks == motion.reach_probe_flicks);
    assert(step_seconds * 480 == 1);
    // The bucket arithmetic of `shift_position` fits a u64.
    assert(period_flicks_max * buckets_max < std.math.maxInt(u64));
}

/// A range that a follower draws a goal from, low and high included.
pub const Region = struct {
    low: f64,
    high: f64,
};

/// A run of regions in a `Regions` table.
pub const Span = struct {
    first: u32,
    count: u32,
};

/// A bounded table of regions that followers refer to by `Span`.
pub const Regions = struct {
    entries: []Region,
    count: u32,

    pub const Error = error{
        /// The array the caller gave `init` is full.
        RegionCapacityExceeded,
        /// A span with no regions.
        NoRegions,
        /// A region end that is infinite, NaN, or past `state_bound`.
        NotFinite,
    };

    pub fn init(entries: []Region) Regions {
        assert(entries.len <= std.math.maxInt(u32));
        return .{ .entries = entries, .count = 0 };
    }

    /// Copies `run` to the end of the table, as one span.
    pub fn add(regions: *Regions, run: []const Region) Error!Span {
        assert(regions.count <= regions.entries.len);
        if (run.len == 0) return error.NoRegions;
        if (run.len > regions.entries.len - regions.count) return error.RegionCapacityExceeded;
        for (run) |region| {
            if (!within_bound(region.low)) return error.NotFinite;
            if (!within_bound(region.high)) return error.NotFinite;
        }
        const span: Span = .{ .first = regions.count, .count = @intCast(run.len) };
        @memcpy(regions.entries[span.first..][0..span.count], run);
        regions.count += span.count;
        return span;
    }

    /// The regions so far.
    pub fn table(regions: *const Regions) []const Region {
        assert(regions.count <= regions.entries.len);
        return regions.entries[0..regions.count];
    }
};

/// How a follower moves toward its goal.
pub const Mover = union(enum) {
    /// A spring, as `motion.Spring` describes one.
    spring: struct { time: Time, overshoot: f64 },
    /// A Newtonian move, as `motion.Newtonian` describes one.
    newtonian: struct { speed: f64, accel: f64, decel: f64 },
};

/// How a follower chooses the region of its next goal.
pub const Pick = enum {
    /// The regions in turn, from the first.
    cycle,
    /// A drawn region each time.
    random,
};

pub const ShiftShape = enum {
    /// Each bucket, held while it is visited.
    steps,
    /// From each bucket toward the next.
    linear,
    /// Modulator's quadratic: through the midpoints between buckets, with a continuous slope.
    smooth,
};

/// A parameter that is constant, in `Follower.params`.
pub const no_param = std.math.maxInt(u32);

/// A goal follower as a graph node holds it.
pub const Follower = struct {
    from: f64,
    /// Within this of the goal, and at most this fast, is arrived. At least 0.
    tolerance: f64,
    seed: u64,
    /// The law of its constant parameters, which the graph overrides from `params`.
    law: motion.Law,
    /// The node indices its law's parameters come from, or `no_param`: a spring's time and
    /// overshoot, or a Newtonian move's speed, accel, and decel (`graph.zig`, section 14).
    params: [3]u32 = @splat(no_param),
    regions: Span,
    pause_min_steps: u32,
    pause_max_steps: u32,
    pick: Pick,
};

/// A shift register as a graph node holds it.
pub const ShiftRegister = struct {
    low: f64,
    high: f64,
    /// The chance in [0, 1] that the bucket two behind is replaced as a bucket is entered.
    odds: f64,
    seed: u64,
    /// One pass over every bucket, in flicks, at least `buckets` steps.
    period_flicks: u64,
    buckets: u32,
    shape: ShiftShape,
};

// The purpose of each draw, so two choices with the same index are unrelated.
const purpose_region: u64 = 0;
const purpose_goal: u64 = 1;
const purpose_pause: u64 = 2;
const purpose_fill: u64 = 3;
const purpose_odds: u64 = 4;
const purpose_replace: u64 = 5;

/// The draw of `purpose` number `index` for `seed`. Section 3 explains why.
fn draw(seed: u64, purpose: u64, index: u64) u64 {
    assert(purpose <= purpose_replace);
    return noise.hash(noise.hash(seed, purpose), index);
}

/// A draw scaled into [0, 1), exactly.
fn unit(bits: u64) f64 {
    const result = @as(f64, @floatFromInt(bits >> 11)) * 0x1p-53;
    assert(result >= 0);
    assert(result < 1);
    return result;
}

/// The point `weight` of the way from `low` to `high`, which lands on both ends exactly.
fn between(low: f64, high: f64, weight: f64) f64 {
    assert(weight >= 0);
    assert(weight <= 1);
    return low * (1 - weight) + high * weight;
}

/// A follower's state between steps.
pub const FollowerState = struct {
    kinematics: motion.Kinematics,
    goal: f64,
    /// Goals drawn so far, which is the index of the next one.
    drawn: u64,
    /// Steps of pause left, or 0 while moving.
    pause_left: u64,
};

/// The state of a follower at step 0: at `from`, at rest, heading for its first goal.
pub fn follower_start(follower: *const Follower, regions: []const Region) FollowerState {
    assert(follower.regions.count > 0);
    assert(follower.regions.first + follower.regions.count <= regions.len);
    const state: FollowerState = .{
        .kinematics = .{ .position = follower.from, .velocity = 0 },
        .goal = follower.from,
        .drawn = 0,
        .pause_left = 0,
    };
    return follower_retarget(follower, regions, state);
}

/// The result of one step of a follower: its state, and whether it arrived at this step, which is
/// an event.
pub const FollowerStep = struct {
    state: FollowerState,
    arrived: bool,
};

/// The state of a follower one step after `state`, moving by `law`, as section 4 explains. The law
/// is the follower's own, or one from its parameters' nodes at this step.
pub fn follower_step(
    follower: *const Follower,
    regions: []const Region,
    law: motion.Law,
    state: FollowerState,
) FollowerStep {
    assert(state.drawn > 0);
    assert(state.pause_left <= pause_steps_max);
    var next = state;
    next.kinematics = bounded_kinematics(motion.advance(law, state.kinematics, state.goal, step_seconds));
    if (state.pause_left > 0) {
        next.pause_left = state.pause_left - 1;
        if (next.pause_left == 0) next = follower_retarget(follower, regions, next);
        return .{ .state = next, .arrived = false };
    }
    if (!follower_arrived(follower, next.kinematics, state.goal)) {
        return .{ .state = next, .arrived = false };
    }
    next.pause_left = follower_pause(follower, state.drawn);
    if (next.pause_left == 0) next = follower_retarget(follower, regions, next);
    return .{ .state = next, .arrived = true };
}

fn follower_arrived(follower: *const Follower, kinematics: motion.Kinematics, goal: f64) bool {
    assert(follower.tolerance >= 0);
    assert(std.math.isFinite(kinematics.position));
    if (@abs(kinematics.position - goal) > follower.tolerance) return false;
    return @abs(kinematics.velocity) <= follower.tolerance;
}

/// `state` with its next goal drawn, which section 4 explains.
fn follower_retarget(
    follower: *const Follower,
    regions: []const Region,
    state: FollowerState,
) FollowerState {
    const span = regions[follower.regions.first..][0..follower.regions.count];
    const region_index: u32 = @intCast(switch (follower.pick) {
        .cycle => state.drawn % span.len,
        .random => draw(follower.seed, purpose_region, state.drawn) % span.len,
    });
    const region = span[region_index];
    const weight = unit(draw(follower.seed, purpose_goal, state.drawn));
    var next = state;
    next.goal = between(region.low, region.high, weight);
    next.drawn = state.drawn + 1;
    next.pause_left = 0;
    assert(std.math.isFinite(next.goal));
    return next;
}

/// The steps of the pause after goal number `drawn - 1`, between the two bounds.
fn follower_pause(follower: *const Follower, drawn: u64) u64 {
    assert(follower.pause_min_steps <= follower.pause_max_steps);
    const span: u64 = @as(u64, follower.pause_max_steps) - follower.pause_min_steps + 1;
    const result = follower.pause_min_steps + draw(follower.seed, purpose_pause, drawn) % span;
    assert(result <= follower.pause_max_steps);
    return result;
}

/// Where a shift register is at a step: how many buckets it has entered since the start, and how
/// far it is through the current one.
pub const Position = struct {
    bucket: u64,
    fraction: f64,
};

/// The position of `shift` at step `step_index`, from integer flicks, as section 5 explains.
pub fn shift_position(shift: *const ShiftRegister, step_index: u64) Position {
    assert(shift.buckets > 0);
    assert(shift.period_flicks <= period_flicks_max);
    const flicks = step_index * step_flicks;
    const count: u64 = shift.buckets;
    const pass = flicks / shift.period_flicks;
    const scaled = (flicks % shift.period_flicks) * count;
    const within = scaled / shift.period_flicks;
    const rest = scaled - within * shift.period_flicks;
    // Both below 2^53, so exact, and rest is below the period, so the quotient is below 1.
    const fraction = @as(f64, @floatFromInt(rest)) / @as(f64, @floatFromInt(shift.period_flicks));
    assert(within < count);
    assert(fraction < 1);
    return .{ .bucket = pass * count + within, .fraction = fraction };
}

/// The flicks from the start at which `shift` enters bucket `bucket`, counted as `shift_position`
/// counts: the first flick whose position is in that bucket, an exact integer.
pub fn shift_boundary(shift: *const ShiftRegister, bucket: u64) u64 {
    assert(shift.buckets > 0);
    assert(shift.period_flicks <= period_flicks_max);
    const count: u64 = shift.buckets;
    const pass = bucket / count;
    const within = bucket % count;
    const result = pass * shift.period_flicks +
        (std.math.divCeil(u64, within * shift.period_flicks, count) catch unreachable);
    if (within == 0) assert(result % shift.period_flicks == 0);
    return result;
}

/// Fills `buckets` with the shift register's values at step 0.
pub fn shift_fill(shift: *const ShiftRegister, buckets: []f64) void {
    assert(buckets.len == shift.buckets);
    for (buckets, 0..) |*bucket, index| {
        bucket.* = between(shift.low, shift.high, unit(draw(shift.seed, purpose_fill, index)));
    }
}

/// The result of one step of a shift register: the bucket count it reached, and its value.
pub const ShiftStep = struct {
    bucket: u64,
    value: f64,
};

/// Moves `shift` from `bucket_before`, entered at the step before `step_index`, to `step_index`,
/// replacing a bucket if it enters one, as section 5 explains.
pub fn shift_step(
    shift: *const ShiftRegister,
    buckets: []f64,
    bucket_before: u64,
    step_index: u64,
) ShiftStep {
    assert(step_index > 0);
    const position = shift_position(shift, step_index);
    assert(position.bucket >= bucket_before);
    assert(position.bucket - bucket_before <= 1);
    if (position.bucket > bucket_before) shift_enter(shift, buckets, position.bucket);
    return .{ .bucket = position.bucket, .value = shift_value(shift, buckets, position) };
}

/// Replaces the bucket two behind `entered`, with the drawn odds.
fn shift_enter(shift: *const ShiftRegister, buckets: []f64, entered: u64) void {
    assert(buckets.len == shift.buckets);
    assert(entered > 0);
    const count: u64 = shift.buckets;
    const behind: u32 = @intCast((entered + 2 * count - 2) % count);
    if (unit(draw(shift.seed, purpose_odds, entered)) < shift.odds) {
        const weight = unit(draw(shift.seed, purpose_replace, entered));
        buckets[behind] = between(shift.low, shift.high, weight);
    }
}

/// The value of `shift` at `position`, in its shape.
pub fn shift_value(shift: *const ShiftRegister, buckets: []const f64, position: Position) f64 {
    assert(buckets.len == shift.buckets);
    assert(position.fraction >= 0);
    const count = shift.buckets;
    const index: u32 = @intCast(position.bucket % count);
    const current = buckets[index];
    const next = buckets[(index + 1) % count];
    const fraction = position.fraction;
    switch (shift.shape) {
        .steps => return current,
        .linear => return between(current, next, fraction),
        .smooth => {
            const previous = buckets[(index + count - 1) % count];
            const start = (previous + current) / 2;
            const end = (current + next) / 2;
            const first = between(start, current, fraction);
            const second = between(current, end, fraction);
            return between(first, second, fraction);
        },
    }
}

const testing = std.testing;

// Locks that a draw is a pure function of its three inputs, that its purpose and its index each
// change it, and that a unit draw spans [0, 1): all zeros is 0, and all ones is 1 - 2^-53.
test "a draw depends on its seed, purpose, and index" {
    try testing.expectEqual(draw(7, purpose_goal, 3), draw(7, purpose_goal, 3));
    try testing.expect(draw(7, purpose_goal, 3) != draw(7, purpose_pause, 3));
    try testing.expect(draw(7, purpose_goal, 3) != draw(7, purpose_goal, 4));
    try testing.expect(draw(7, purpose_goal, 3) != draw(8, purpose_goal, 3));
    try testing.expectEqual(@as(f64, 0), unit(0));
    try testing.expectEqual(1 - 0x1p-53, unit(std.math.maxInt(u64)));
    try testing.expectEqual(@as(f64, -2), between(-2, 5, 0));
    try testing.expectEqual(@as(f64, 5), between(-2, 5, 1));
}

// Locks the table's refusals by name, and that a refused span leaves the table as it was.
test "the region table refuses a span it cannot hold" {
    var entries: [3]Region = undefined;
    var regions = Regions.init(&entries);
    try testing.expectError(error.NoRegions, regions.add(&.{}));
    const nan = std.math.nan(f64);
    try testing.expectError(error.NotFinite, regions.add(&.{.{ .low = 0, .high = nan }}));
    const span = try regions.add(&.{ .{ .low = 0, .high = 1 }, .{ .low = 3, .high = 2 } });
    try testing.expectEqual(Span{ .first = 0, .count = 2 }, span);
    try testing.expectError(error.RegionCapacityExceeded, regions.add(&.{
        .{ .low = 0, .high = 1 }, .{ .low = 0, .high = 1 },
    }));
    try testing.expectEqual(@as(usize, 2), regions.table().len);
    const last = try regions.add(&.{.{ .low = 5, .high = 5 }});
    try testing.expectEqual(Span{ .first = 2, .count = 1 }, last);
}

/// A shift register of 4 buckets over 1 s, from -1 to 1, with `odds` and `shape`.
fn shift_of(odds: f64, shape: ShiftShape) ShiftRegister {
    return .{
        .low = -1,
        .high = 1,
        .odds = odds,
        .seed = 99,
        .period_flicks = @intCast(time_module.flicks_per_second),
        .buckets = 4,
        .shape = shape,
    };
}

/// The values of `shift` at every step from 1 to `values.len`, from step 0.
fn shift_run(shift: *const ShiftRegister, values: []f64) void {
    var buckets: [4]f64 = undefined;
    shift_fill(shift, &buckets);
    var bucket: u64 = 0;
    for (values, 1..) |*value, step_index| {
        const result = shift_step(shift, &buckets, bucket, step_index);
        bucket = result.bucket;
        value.* = result.value;
    }
}

// Locks the promise of section 5 over 10 s of 4 buckets a second: with odds 0 every step equals
// the step a period later, bit for bit; with odds 1 none of the 36 later bucket visits repeats the
// visit a period before; and every value stays within [-1, 1].
test "a shift register repeats at odds 0 and never at odds 1" {
    var values: [4800]f64 = undefined;
    const fixed = shift_of(0, .smooth);
    shift_run(&fixed, &values);
    for (values[480..], values[0 .. values.len - 480]) |later, earlier| {
        try testing.expectEqual(earlier, later);
    }
    const restless = shift_of(1, .steps);
    shift_run(&restless, &values);
    var repeats: u32 = 0;
    // Steps 120 apart are a quarter second, one bucket each, so step 120 j sits in bucket j.
    for (4..40) |visit| {
        if (values[visit * 120] == values[(visit - 4) * 120]) repeats += 1;
    }
    try testing.expectEqual(@as(u32, 0), repeats);
    for (values) |value| try testing.expect(@abs(value) <= 1);
}

// Locks the shapes on buckets 0, 1, 0.5, and -1 at a quarter of the way through bucket 1: steps
// gives 1, linear gives 0.875, and smooth gives the quadratic through the midpoints 0.5 and 0.75,
// 0.5 * 9/16 + 1 * 6/16 + 0.75 * 1/16 = 0.703125.
test "a shift register's shapes" {
    const buckets = [_]f64{ 0, 1, 0.5, -1 };
    const position: Position = .{ .bucket = 5, .fraction = 0.25 };
    var shift = shift_of(0, .steps);
    try testing.expectEqual(@as(f64, 1), shift_value(&shift, &buckets, position));
    shift.shape = .linear;
    try testing.expectEqual(@as(f64, 0.875), shift_value(&shift, &buckets, position));
    shift.shape = .smooth;
    try testing.expectEqual(@as(f64, 0.703125), shift_value(&shift, &buckets, position));
}

// Locks the integer bucket boundaries of section 5 for 3 buckets over 1 s, which is 480 steps:
// bucket 1 begins at step 160 exactly, and the second pass at step 480, as bucket 3.
test "shift register boundaries are exact" {
    var shift = shift_of(0, .steps);
    shift.buckets = 3;
    try testing.expectEqual(@as(u64, 0), shift_position(&shift, 159).bucket);
    try testing.expectEqual(Position{ .bucket = 1, .fraction = 0 }, shift_position(&shift, 160));
    try testing.expectEqual(Position{ .bucket = 3, .fraction = 0 }, shift_position(&shift, 480));
    try testing.expectEqual(@as(f64, 0.5), shift_position(&shift, 560).fraction);
    // Bucket 1 begins at 1/3 s, which is 235,200,000 flicks exactly, and bucket 2 at 2/3 s.
    try testing.expectEqual(@as(u64, 235_200_000), shift_boundary(&shift, 1));
    try testing.expectEqual(@as(u64, 470_400_000), shift_boundary(&shift, 2));
    try testing.expectEqual(@as(u64, 705_600_000), shift_boundary(&shift, 3));
    shift.period_flicks = 1000;
    // Bucket 1 of 3 over 1,000 flicks: position 333 is in bucket 0, 334 in bucket 1.
    try testing.expectEqual(@as(u64, 334), shift_boundary(&shift, 1));
}

// Locks section 4 over a minute of steps of a random follower on a spring, with regions
// [-1, -0.5] and [0.5, 1] and pauses of 48 to 144 steps: every goal lies in a region, both
// regions are drawn, every pause is within its bounds, and dozens of goals are reached.
test "a random follower draws goals in its regions and pauses within bounds" {
    const regions = [_]Region{ .{ .low = -1, .high = -0.5 }, .{ .low = 0.5, .high = 1 } };
    const follower: Follower = .{
        .from = 0,
        .tolerance = 0.01,
        .seed = 17,
        .law = .{ .spring = motion.SpringLaw.of(.{ .flicks = 176_400_000 }, 0) },
        .regions = .{ .first = 0, .count = 2 },
        .pause_min_steps = 48,
        .pause_max_steps = 144,
        .pick = .random,
    };
    var state = follower_start(&follower, &regions);
    var drawn_per_region = [2]u32{ 0, 0 };
    var arrivals: u32 = 0;
    for (0..60 * 480) |_| {
        const step_result = follower_step(&follower, &regions, follower.law, state);
        const next = step_result.state;
        if (step_result.arrived) arrivals += 1;
        if (next.drawn != state.drawn) {
            const in_low = next.goal >= -1 and next.goal <= -0.5;
            const in_high = next.goal >= 0.5 and next.goal <= 1;
            try testing.expect(in_low != in_high);
            drawn_per_region[@intFromBool(in_high)] += 1;
        }
        if (state.pause_left == 0 and next.pause_left > 0) {
            try testing.expect(next.pause_left >= 48);
            try testing.expect(next.pause_left <= 144);
        }
        state = next;
    }
    try testing.expect(drawn_per_region[0] > 10);
    try testing.expect(drawn_per_region[1] > 10);
    // Each goal drawn here followed an arrival, and the last arrival may still be in its pause.
    const drawn_count = drawn_per_region[0] + drawn_per_region[1];
    try testing.expect(arrivals >= drawn_count);
    try testing.expect(arrivals <= drawn_count + 1);
}

// Locks section 7's reading rule: NaN reads as 0, the infinities as the bound, and a finite value
// inside it unchanged, the sign of zero included.
test "a bounded value is finite and keeps what fits" {
    try testing.expectEqual(@as(f64, 0), bounded(std.math.nan(f64)));
    try testing.expectEqual(state_bound, bounded(std.math.inf(f64)));
    try testing.expectEqual(-state_bound, bounded(-std.math.inf(f64)));
    try testing.expectEqual(state_bound, bounded(std.math.floatMax(f64)));
    for ([_]f64{ 0, 1, -1, 1e77, -1e77, state_bound, -state_bound }) |value| {
        try testing.expectEqual(value, bounded(value));
    }
    try testing.expect(std.math.signbit(bounded(-0.0)));
    try testing.expect(within_bound(state_bound));
    try testing.expect(!within_bound(state_bound * 2));
    try testing.expect(!within_bound(std.math.nan(f64)));
}

// Locks why section 7's bound is 2^256: one step of a spring or a Newtonian move from a state at
// the bound, at the fastest and slowest laws a builder or a parameter node can give, is finite.
test "a step from the bound stays finite" {
    const ends = [_]f64{ -state_bound, state_bound };
    var laws: [12]motion.Law = undefined;
    var count: usize = 0;
    const omegas = [_]f64{ std.math.tau * @as(f64, @floatFromInt(time_module.flicks_per_second)), std.math.tau, std.math.tau / state_bound };
    const zetas = [_]f64{ 1, motion.SpringLaw.zeta_of(0x1p-1074), motion.SpringLaw.zeta_of(0.99) };
    for (omegas) |omega| for (zetas) |zeta| {
        laws[count] = .{ .spring = motion.SpringLaw.from_omega_zeta(omega, zeta) };
        count += 1;
    };
    const limit_min: f64 = 0x1p-20;
    laws[count] = .{ .newtonian = .{ .speed = state_bound, .accel = state_bound, .decel = state_bound } };
    laws[count + 1] = .{ .newtonian = .{ .speed = state_bound, .accel = state_bound, .decel = limit_min } };
    laws[count + 2] = .{ .newtonian = .{ .speed = limit_min, .accel = limit_min, .decel = state_bound } };
    count += 3;
    for (laws[0..count]) |law| {
        for (ends) |position| for (ends) |velocity| for (ends) |goal| {
            const next = motion.advance(law, .{ .position = position, .velocity = velocity }, goal, step_seconds);
            try testing.expect(std.math.isFinite(next.position));
            try testing.expect(std.math.isFinite(next.velocity));
        };
    }
}
