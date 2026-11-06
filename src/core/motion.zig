//! Motion toward goals: springs and Newtonian moves, solved exactly between goal changes.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Goals at Cues
//! A motion moves toward a goal, and a new goal can arrive at any cue. A path is a run of goals in
//! the `Goals` table, each a value at a cue, in cue order and so in time order. Before its first
//! cue a motion holds `from`, at rest. From each cue it heads for that cue's goal, starting from
//! wherever the previous goal left it, at that velocity. So a new goal mid-move keeps the momentum.
//!
//! ## 2. Exact Between Goal Changes
//! Between two cues a motion has a closed form, so the value at any time is computed, not stepped,
//! and it is the same at any frame rate. To reach a time, `sample` folds over the goal changes
//! before it: it carries position and velocity from each cue to the next with the closed form, then
//! evaluates the last stretch. Splitting a stretch in two and folding gives the same motion, to
//! rounding, because each closed form starts from any position and velocity.
//!
//! ## 3. The Cursor
//! Folding from the first goal costs one closed form per goal change. A reader playing forwards
//! would pay that every frame, so it keeps a cursor: the last goal it reached, and the position
//! and velocity there. The next sample starts from the cursor when it can, so forward play costs
//! one closed form per frame and a jump costs one per goal change. The cursor is a cache and not
//! history: starting from it performs the very operations a fold from the first goal would, so a
//! reader cannot tell which happened. It records the generation of the cue table it was worked out
//! from, and a cue move makes it stale.
//!
//! ## 4. Springs
//! A spring is given by `time`, the period of its undamped oscillation, so omega is 2 pi / time,
//! and by `overshoot`, the peak overshoot of a move from rest as a fraction of the move, which
//! fixes the damping ratio. An overshoot of 0 is a critically damped spring, about 1.4% short of
//! its goal after one `time`. Above 0 the spring is underdamped, and its closed form is a decaying
//! sine and cosine.
//!
//! A spring never arrives in exact arithmetic, so it is settled when what is left of the move
//! cannot change a rounded value: when the decaying envelope of its distance to the goal is below
//! 2^-53 of the move's scale, the larger of the goal, the start, and the start velocity over omega.
//! From then on it returns its goal exactly, at rest, so a client can go idle on an exact value.
//! The envelope only falls, so a settled spring stays settled until its next goal.
//!
//! ## 5. Newtonian Moves
//! A Newtonian move accelerates at `accel` up to `speed`, cruises, and slows at `decel` to stop
//! exactly on its goal, in the least time those limits allow. A goal behind, or one too close to
//! stop for, first costs a braking phase. So a plan has at most four phases of constant
//! acceleration, and at its end the move returns its goal itself, so it lands exactly.
//!
//! ## 6. Goals Reached
//! Reaching a goal is an event. Goal i is reached at the first flick from its cue at which the
//! closed form from its cue returns the goal itself, at rest, which is when `sample` already
//! returns it: a settled spring, or a Newtonian move at the end of its plan. If the next goal's cue
//! comes first, goal i is never reached. Both laws only stay on a goal once they reach it, so the
//! flick is found by a gallop from the cue, doubling from one simulation step, then a bisection on
//! integer flicks: at most 64 closed forms each. For a range, the closed forms at its two ends
//! first say whether the flick is in it, so the search runs once per goal for a reader.
//!
//! ## 7. TigerStyle Invariants
//! - No allocation, no locks. A sample runs one closed form per goal change at most, and a closed
//!   form has no loop longer than four phases. Finding a goal reached runs at most 131.
//! - The goal table is immutable once built, and a refused `add` leaves it as it was.

const std = @import("std");
const assert = std.debug.assert;
const Cue = @import("cue.zig").Cue;
const Cues = @import("cue.zig").Cues;
const elementary = @import("elementary.zig");
const time_module = @import("time.zig");
const Time = time_module.Time;

/// A value to head for from the time of `cue`.
pub const Goal = struct {
    cue: Cue,
    value: f64,
};

/// A run of goals in a `Goals` table.
pub const Path = struct {
    first: u32,
    count: u32,
};

/// A bounded table of goals that motions refer to by `Path`.
pub const Goals = struct {
    entries: []Goal,
    count: u32,

    pub const Error = error{
        /// The array the caller gave `init` is full.
        GoalCapacityExceeded,
        /// A path with no goals.
        NoGoals,
        /// A goal whose cue is not after the cue of the goal before it.
        GoalOutOfOrder,
        /// A goal value that is infinite or NaN.
        NotFinite,
    };

    pub fn init(entries: []Goal) Goals {
        assert(entries.len <= std.math.maxInt(u32));
        return .{ .entries = entries, .count = 0 };
    }

    /// Copies `goals` to the end of the table, as one path.
    pub fn add(table_goals: *Goals, goals: []const Goal) Error!Path {
        assert(table_goals.count <= table_goals.entries.len);
        if (goals.len == 0) return error.NoGoals;
        if (goals.len > table_goals.entries.len - table_goals.count) {
            return error.GoalCapacityExceeded;
        }
        for (goals, 0..) |goal, index| {
            if (!std.math.isFinite(goal.value)) return error.NotFinite;
            if (index > 0) {
                if (goal.cue.index <= goals[index - 1].cue.index) return error.GoalOutOfOrder;
            }
        }
        const path: Path = .{ .first = table_goals.count, .count = @intCast(goals.len) };
        @memcpy(table_goals.entries[path.first..][0..path.count], goals);
        table_goals.count += path.count;
        return path;
    }

    /// The goals so far.
    pub fn table(table_goals: *const Goals) []const Goal {
        assert(table_goals.count <= table_goals.entries.len);
        return table_goals.entries[0..table_goals.count];
    }
};

/// A spring, as a client describes it.
pub const Spring = struct {
    /// The value before the first goal.
    from: f64,
    goals: Path,
    /// The period of the undamped oscillation, above zero. Section 4 explains why.
    time: Time,
    /// The peak overshoot of a move from rest, as a fraction of the move, in [0, 1).
    overshoot: f64,
};

/// A Newtonian move, as a client describes it.
pub const Newtonian = struct {
    /// The value before the first goal.
    from: f64,
    goals: Path,
    /// The largest speed, in units per second, above zero.
    speed: f64,
    /// The acceleration while speeding up, in units per second squared, above zero.
    accel: f64,
    /// The deceleration while slowing down, in units per second squared, above zero.
    decel: f64,
};

/// A spring's constants, worked out once when it is built.
pub const SpringLaw = struct {
    omega: f64,
    /// 1 exactly for a critically damped spring, below 1 for an underdamped one.
    zeta: f64,
    /// The damped frequency in cycles per second, or 0 when `zeta` is 1.
    damped_hz: f64,

    /// The law of a spring with this `time` and `overshoot`, which section 4 explains.
    pub fn of(time: Time, overshoot: f64) SpringLaw {
        assert(time.flicks > 0);
        return of_seconds(time.seconds(), overshoot);
    }

    /// `of` with the time in seconds, as a parameter from a node gives it.
    pub fn of_seconds(seconds: f64, overshoot: f64) SpringLaw {
        assert(seconds > 0);
        assert(std.math.isFinite(seconds));
        return from_omega_zeta(std.math.tau / seconds, zeta_of(overshoot));
    }

    /// The damping ratio whose peak overshoot from rest is `overshoot`: 1 at 0.
    pub fn zeta_of(overshoot: f64) f64 {
        assert(overshoot >= 0);
        assert(overshoot < 1);
        if (overshoot == 0) return 1;
        // The peak overshoot from rest is exp(-pi zeta / sqrt(1 - zeta^2)), solved for zeta.
        const log_overshoot = elementary.log(overshoot);
        const pi_squared = std.math.pi * std.math.pi;
        return -log_overshoot / @sqrt(pi_squared + log_overshoot * log_overshoot);
    }

    pub fn from_omega_zeta(omega: f64, zeta: f64) SpringLaw {
        assert(omega > 0);
        assert(std.math.isFinite(omega));
        assert(zeta > 0);
        assert(zeta <= 1);
        // (1 - zeta)(1 + zeta), not 1 - zeta^2, which cancels near 1.
        const damped = omega * @sqrt((1 - zeta) * (1 + zeta));
        return .{ .omega = omega, .zeta = zeta, .damped_hz = damped / std.math.tau };
    }
};

/// The limits of a Newtonian move.
pub const Limits = struct {
    speed: f64,
    accel: f64,
    decel: f64,
};

pub const Law = union(enum) {
    spring: SpringLaw,
    newtonian: Limits,
};

/// A motion as a graph node holds it.
pub const Motion = struct {
    from: f64,
    goals: Path,
    law: Law,
};

pub const Kinematics = struct {
    position: f64,
    velocity: f64,
};

/// The f64 a reader keeps per motion for its cursor: the goal index plus one, or 0 for none; the
/// cue generation; and the position and velocity at that goal's cue.
pub const cursor_count = 4;

/// The value of `motion` at `time`, folding over its goals from `cursor` when it can, and leaving
/// in `cursor` the last goal reached. Section 3 explains why the result does not depend on it.
pub fn sample(
    motion: *const Motion,
    goals: []const Goal,
    cues: *const Cues,
    cursor: *[cursor_count]f64,
    time: Time,
) f64 {
    assert(motion.goals.count > 0);
    assert(cues.generation < Cues.generation_max);
    const path = goals[motion.goals.first..][0..motion.goals.count];
    const generation: f64 = @floatFromInt(cues.generation);

    var index: u32 = 0;
    var kinematics: Kinematics = .{ .position = motion.from, .velocity = 0 };
    const cursor_index_plus_one: u32 = @intFromFloat(cursor[0]);
    assert(cursor_index_plus_one <= path.len);
    const cursor_usable = cursor_index_plus_one > 0 and cursor[1] == generation and
        cues.at(path[cursor_index_plus_one - 1].cue).flicks <= time.flicks;
    if (cursor_usable) {
        index = cursor_index_plus_one - 1;
        kinematics = .{ .position = cursor[2], .velocity = cursor[3] };
    } else if (time.flicks < cues.at(path[0].cue).flicks) {
        return motion.from;
    }

    while (index + 1 < path.len) {
        const next_time = cues.at(path[index + 1].cue);
        if (next_time.flicks > time.flicks) break;
        const seconds = seconds_between(cues.at(path[index].cue), next_time);
        kinematics = advance(motion.law, kinematics, path[index].value, seconds);
        index += 1;
    }
    cursor.* = .{
        @floatFromInt(index + 1), generation, kinematics.position, kinematics.velocity,
    };
    const seconds = seconds_between(cues.at(path[index].cue), time);
    return advance(motion.law, kinematics, path[index].value, seconds).position;
}

/// The position and velocity of `motion` at the cue of goal `index`, folding from `cursor` when it
/// holds an earlier goal, and from the first goal otherwise. Section 3 explains why the result does
/// not depend on which. The cursor is only read.
pub fn kinematics_at_goal(
    motion: *const Motion,
    goals: []const Goal,
    cues: *const Cues,
    cursor: *const [cursor_count]f64,
    index: u32,
) Kinematics {
    assert(motion.goals.count > 0);
    assert(index < motion.goals.count);
    const path = goals[motion.goals.first..][0..motion.goals.count];
    var at: u32 = 0;
    var kinematics: Kinematics = .{ .position = motion.from, .velocity = 0 };
    const cursor_index_plus_one: u32 = @intFromFloat(cursor[0]);
    assert(cursor_index_plus_one <= path.len);
    const generation: f64 = @floatFromInt(cues.generation);
    if (cursor_index_plus_one > 0 and cursor[1] == generation) {
        if (cursor_index_plus_one - 1 <= index) {
            at = cursor_index_plus_one - 1;
            kinematics = .{ .position = cursor[2], .velocity = cursor[3] };
        }
    }
    while (at < index) : (at += 1) {
        const seconds = seconds_between(cues.at(path[at].cue), cues.at(path[at + 1].cue));
        kinematics = advance(motion.law, kinematics, path[at].value, seconds);
    }
    assert(at == index);
    return kinematics;
}

/// The first flick at or after the cue of goal `index` at which `motion`, at `kinematics` there,
/// is on the goal at rest, exactly, or null if the next goal's cue comes first. Section 6 explains
/// the search.
pub fn reached(
    motion: *const Motion,
    goals: []const Goal,
    cues: *const Cues,
    index: u32,
    kinematics: Kinematics,
) ?Time {
    assert(index < motion.goals.count);
    const path = goals[motion.goals.first..][0..motion.goals.count];
    const cue_time = cues.at(path[index].cue);
    const offset_max = stretch_offset_max(path, cues, index) orelse return null;
    const goal = path[index].value;
    if (on_goal(motion.law, kinematics, goal, 0)) return cue_time;
    var below: u64 = 0;
    var above: u64 = 0;
    var probe: u64 = @intCast(reach_probe_flicks);
    for (0..64) |_| {
        probe = @min(probe, offset_max);
        if (on_goal(motion.law, kinematics, goal, probe)) {
            above = probe;
            break;
        }
        if (probe == offset_max) return null;
        below = probe;
        probe = if (probe > offset_max / 2) offset_max else probe * 2;
    } else unreachable;
    assert(above > below);
    for (0..64) |_| {
        if (above - below == 1) break;
        const middle = below + (above - below) / 2;
        if (on_goal(motion.law, kinematics, goal, middle)) above = middle else below = middle;
    } else unreachable;
    assert(above - below == 1);
    return .{ .flicks = cue_time.flicks +% @as(i64, @bitCast(above)) };
}

/// `reached`, if it is in `[t0, t1)`, or null. A motion stays on its goal once it is there, so the
/// closed forms at the two ends of the range decide, and the search runs only for the range that
/// holds the flick: a reader's consecutive ranges cost two closed forms per goal, not 129.
pub fn reached_between(
    motion: *const Motion,
    goals: []const Goal,
    cues: *const Cues,
    index: u32,
    kinematics: Kinematics,
    t0: Time,
    t1: Time,
) ?Time {
    assert(index < motion.goals.count);
    assert(t0.flicks < t1.flicks);
    const path = goals[motion.goals.first..][0..motion.goals.count];
    const cue_time = cues.at(path[index].cue);
    const offset_max = stretch_offset_max(path, cues, index) orelse return null;
    if (t1.flicks <= cue_time.flicks) return null;
    // Wrapping, because the distance between two i64 only fits in a u64.
    const last = @min(@as(u64, @bitCast(t1.flicks -% cue_time.flicks)) - 1, offset_max);
    var first: u64 = 0;
    if (t0.flicks > cue_time.flicks) {
        first = @bitCast(t0.flicks -% cue_time.flicks);
        if (first > offset_max) return null;
    }
    const goal = path[index].value;
    if (!on_goal(motion.law, kinematics, goal, last)) return null;
    if (first > 0) {
        if (on_goal(motion.law, kinematics, goal, first - 1)) return null;
    }
    const result = reached(motion, goals, cues, index, kinematics).?;
    assert(result.flicks >= t0.flicks);
    assert(result.flicks < t1.flicks);
    return result;
}

/// The last offset from the cue of goal `index` that belongs to it, before the next goal's cue,
/// or null if the next cue is at the same time.
fn stretch_offset_max(path: []const Goal, cues: *const Cues, index: u32) ?u64 {
    assert(index < path.len);
    const cue_time = cues.at(path[index].cue);
    if (index + 1 == path.len) return @bitCast(std.math.maxInt(i64) -% cue_time.flicks);
    const next_time = cues.at(path[index + 1].cue);
    assert(next_time.flicks >= cue_time.flicks);
    if (next_time.flicks == cue_time.flicks) return null;
    return @as(u64, @bitCast(next_time.flicks -% cue_time.flicks)) - 1;
}

/// The first probe of a search for a goal reached: one simulation step. `simulation.zig` imports
/// this file, so the value is repeated here and checked there.
pub const reach_probe_flicks: i64 = 1_470_000;

/// Whether a motion at `start` heading for `goal` is on it at rest, exactly, `offset` flicks later.
fn on_goal(law: Law, start: Kinematics, goal: f64, offset: u64) bool {
    const flicks_per_second: f64 = @floatFromInt(time_module.flicks_per_second);
    const seconds = @as(f64, @floatFromInt(offset)) / flicks_per_second;
    const result = advance(law, start, goal, seconds);
    if (result.position != goal) return false;
    return result.velocity == 0;
}

/// The seconds from `earlier` to `later`. Wrapping, because the distance between two i64 only
/// fits in a u64.
pub fn seconds_between(earlier: Time, later: Time) f64 {
    assert(later.flicks >= earlier.flicks);
    const flicks: u64 = @bitCast(later.flicks -% earlier.flicks);
    const flicks_per_second: f64 = @floatFromInt(time_module.flicks_per_second);
    return @as(f64, @floatFromInt(flicks)) / flicks_per_second;
}

/// Where a motion starting at `start` and heading for `goal` is `seconds` later.
pub fn advance(law: Law, start: Kinematics, goal: f64, seconds: f64) Kinematics {
    assert(seconds >= 0);
    assert(std.math.isFinite(start.position));
    const result = switch (law) {
        .spring => |spring| spring_advance(spring, start, goal, seconds),
        .newtonian => |limits| newtonian_advance(limits, start, goal, seconds),
    };
    assert(std.math.isFinite(result.position));
    assert(std.math.isFinite(result.velocity));
    return result;
}

fn spring_advance(law: SpringLaw, start: Kinematics, goal: f64, seconds: f64) Kinematics {
    const settled: Kinematics = .{ .position = goal, .velocity = 0 };
    const omega = law.omega;
    const offset = start.position - goal;
    const scale = @max(@max(@abs(goal), @abs(start.position)), @abs(start.velocity) / omega);
    const settled_below = scale * 0x1p-53;
    if (law.zeta == 1) {
        // offset(t) = (offset + slope t) e^(-omega t).
        const slope = start.velocity + omega * offset;
        const decay = elementary.exp(-omega * seconds);
        // The envelope rises until 1 / omega at the latest, and only falls after.
        if (seconds >= 1 / omega) {
            if ((@abs(offset) + @abs(slope) * seconds) * decay <= settled_below) return settled;
        }
        return .{
            .position = goal + (offset + slope * seconds) * decay,
            .velocity = (start.velocity - omega * slope * seconds) * decay,
        };
    }
    // offset(t) = e^(-sigma t) (offset cos(wd t) + sine_part sin(wd t)).
    const sigma = law.zeta * omega;
    const damped = law.damped_hz * std.math.tau;
    const sine_part = (start.velocity + sigma * offset) / damped;
    const decay = elementary.exp(-sigma * seconds);
    if ((@abs(offset) + @abs(sine_part)) * decay <= settled_below) return settled;
    const turns = law.damped_hz * seconds;
    const angle = elementary.sine_cosine(turns - @floor(turns));
    const velocity_sine_part = (sigma * start.velocity + omega * omega * offset) / damped;
    return .{
        .position = goal + decay * (offset * angle.cosine + sine_part * angle.sine),
        .velocity = decay * (start.velocity * angle.cosine - velocity_sine_part * angle.sine),
    };
}

const Phase = struct {
    seconds: f64,
    acceleration: f64,
};

const phases_count_max = 4;

const Plan = struct {
    phases: [phases_count_max]Phase,
    count: u32,

    fn push(plan: *Plan, seconds: f64, acceleration: f64) void {
        assert(plan.count < phases_count_max);
        assert(seconds >= 0);
        plan.phases[plan.count] = .{ .seconds = seconds, .acceleration = acceleration };
        plan.count += 1;
    }
};

/// The fastest way from `start` to rest on `goal` within `limits`, as section 5 explains.
fn newtonian_plan(limits: Limits, start: Kinematics, goal: f64) Plan {
    var plan: Plan = .{ .phases = undefined, .count = 0 };
    const distance = goal - start.position;
    if (distance == 0 and start.velocity == 0) return plan;
    // Work along the direction of the goal, or, on the goal, against the velocity.
    var direction: f64 = if (distance != 0) std.math.sign(distance) else 1;
    if (distance == 0 and start.velocity > 0) direction = -1;
    var ahead = distance * direction;
    var speed = start.velocity * direction;
    assert(ahead >= 0);
    const stopping = speed * speed / (2 * limits.decel);
    if (speed < 0) {
        // Moving away: brake to rest, which leaves the goal further ahead.
        plan.push(-speed / limits.decel, direction * limits.decel);
        ahead += stopping;
        speed = 0;
    } else if (stopping > ahead) {
        // Too fast to stop in time: brake to rest past the goal, then come back.
        plan.push(speed / limits.decel, -direction * limits.decel);
        ahead = stopping - ahead;
        speed = 0;
        direction = -direction;
    }
    // Now at most at the speed that stops exactly on the goal: speed up, cruise, slow down.
    const accel = limits.accel;
    const decel = limits.decel;
    const peak_squared = (2 * accel * decel * ahead + decel * speed * speed) / (accel + decel);
    var peak = @max(@sqrt(peak_squared), speed);
    var cruise: f64 = 0;
    if (peak > limits.speed) {
        peak = @max(limits.speed, speed);
        const covered = (peak * peak - speed * speed) / (2 * accel) + peak * peak / (2 * decel);
        cruise = @max(0, (ahead - covered) / peak);
    }
    plan.push((peak - speed) / accel, direction * accel);
    plan.push(cruise, 0);
    plan.push(peak / decel, -direction * decel);
    return plan;
}

fn newtonian_advance(limits: Limits, start: Kinematics, goal: f64, seconds: f64) Kinematics {
    const plan = newtonian_plan(limits, start, goal);
    var kinematics = start;
    var left = seconds;
    for (plan.phases[0..plan.count]) |phase| {
        if (left < phase.seconds) return integrate(kinematics, phase.acceleration, left);
        kinematics = integrate(kinematics, phase.acceleration, phase.seconds);
        left -= phase.seconds;
    }
    return .{ .position = goal, .velocity = 0 };
}

/// Where a body at `start` is after `seconds` at a constant `acceleration`.
fn integrate(start: Kinematics, acceleration: f64, seconds: f64) Kinematics {
    assert(seconds >= 0);
    return .{
        .position = start.position + start.velocity * seconds +
            acceleration * seconds * seconds / 2,
        .velocity = start.velocity + acceleration * seconds,
    };
}

const testing = std.testing;
const Rate = time_module.Rate;

const rest: Kinematics = .{ .position = 0, .velocity = 0 };

// Locks the worked values of the step page for a spring from rest at 0 to a goal of 1 with omega
// 8: critical damping gives 0.99698 at t = 1, and a damping ratio of 0.5 gives 0.84943 at 0.25,
// 1.15312 at 0.5, and 0.97901 at 1.
test "a spring matches its worked values" {
    const critical: Law = .{ .spring = SpringLaw.from_omega_zeta(8, 1) };
    const critical_at_one = advance(critical, rest, 1, 1).position;
    try testing.expectApproxEqAbs(@as(f64, 0.99698), critical_at_one, 5e-6);
    try testing.expectApproxEqAbs(1 - 9 * @exp(@as(f64, -8)), critical_at_one, 1e-15);

    const bouncy: Law = .{ .spring = SpringLaw.from_omega_zeta(8, 0.5) };
    const expected = [_][2]f64{ .{ 0.25, 0.84943 }, .{ 0.5, 1.15312 }, .{ 1, 0.97901 } };
    for (expected) |row| {
        try testing.expectApproxEqAbs(row[1], advance(bouncy, rest, 1, row[0]).position, 5e-6);
    }
}

// Locks the retarget of the step page: the spring of damping ratio 0.5 is retargeted to 0 at
// t = 0.4, from position 1.14603 and velocity 0.67497, and reaches -0.11333 at t = 1.
test "a new goal keeps the velocity" {
    const bouncy: Law = .{ .spring = SpringLaw.from_omega_zeta(8, 0.5) };
    const at_retarget = advance(bouncy, rest, 1, 0.4);
    try testing.expectApproxEqAbs(@as(f64, 1.14603), at_retarget.position, 5e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.67497), at_retarget.velocity, 5e-6);
    const later = advance(bouncy, at_retarget, 0, 0.6);
    try testing.expectApproxEqAbs(@as(f64, -0.11333), later.position, 5e-6);
}

// Locks the mapping of section 4: an overshoot of 0.163 is a damping ratio of 0.5 within 1e-4,
// and the peak of a move from rest, found by sampling a millionth of a period apart, is 1.163
// within 1e-9; `time` is the period, so omega is 8 for 2 pi / 8 seconds.
test "overshoot is the peak of a move from rest" {
    const time: Time = .{ .flicks = 554_176_944 };
    const law = SpringLaw.of(time, 0.163);
    try testing.expectApproxEqAbs(@as(f64, 8), law.omega, 1e-8);
    try testing.expectApproxEqAbs(@as(f64, 0.5), law.zeta, 1e-4);
    const peak_seconds = 0.5 / law.damped_hz;
    var peak: f64 = 0;
    for (0..2001) |index| {
        const seconds = peak_seconds * (0.999 + @as(f64, @floatFromInt(index)) * 1e-6);
        peak = @max(peak, advance(.{ .spring = law }, rest, 1, seconds).position);
    }
    try testing.expectApproxEqAbs(@as(f64, 1.163), peak, 1e-9);
    try testing.expectEqual(@as(f64, 1), SpringLaw.of(time, 0).zeta);
}

// Locks section 2's promise: carrying a move to any time and continuing from there gives the move
// evaluated whole, within 1e-12, for both spring laws and a Newtonian move, at 1,000 splits each,
// from a start with velocity.
test "splitting a move and folding equals evaluating it whole" {
    const laws = [_]Law{
        .{ .spring = SpringLaw.from_omega_zeta(8, 1) },
        .{ .spring = SpringLaw.from_omega_zeta(8, 0.3) },
        .{ .newtonian = .{ .speed = 4, .accel = 2, .decel = 3 } },
    };
    const start: Kinematics = .{ .position = -2, .velocity = 1.5 };
    for (laws) |law| {
        for (0..1000) |index| {
            const total = 0.001 + @as(f64, @floatFromInt(index)) * 0.005;
            const split = total * 0.37;
            const whole = advance(law, start, 5, total);
            const folded = advance(law, advance(law, start, 5, split), 5, total - split);
            try testing.expectApproxEqAbs(whole.position, folded.position, 1e-12);
            try testing.expectApproxEqAbs(whole.velocity, folded.velocity, 1e-12);
        }
    }
}

// Locks the meaning of settled from section 4 for a critical spring with omega 8 from 0 to 1,
// whose envelope (1 + 8t) e^(-8t) falls below 2^-53 between 5.05 s and 5.1 s. At 4 s it is
// 4.2e-13 short, at 5 s still moving, and from 5.1 s exactly 1 at rest; from 5 s to 5.1 s, across
// the snap, it is never more than 2^-52 from its goal. A bouncy spring is settled within a minute.
test "a settled spring returns its goal exactly" {
    const critical: Law = .{ .spring = SpringLaw.from_omega_zeta(8, 1) };
    const at_four = advance(critical, rest, 1, 4).position;
    try testing.expectApproxEqAbs(@as(f64, 1 - 4.179e-13), at_four, 1e-16);
    try testing.expect(advance(critical, rest, 1, 5).velocity != 0);
    const settled: Kinematics = .{ .position = 1, .velocity = 0 };
    try testing.expectEqual(settled, advance(critical, rest, 1, 5.1));
    var snapped_at: f64 = 0;
    for (0..1000) |index| {
        const seconds = 5 + @as(f64, @floatFromInt(index)) / 10_000;
        const kinematics = advance(critical, rest, 1, seconds);
        try testing.expect(@abs(kinematics.position - 1) <= 0x1p-52);
        if (snapped_at == 0 and kinematics.velocity == 0) snapped_at = seconds;
    }
    try testing.expect(snapped_at > 5.05);
    try testing.expect(snapped_at <= 5.1);
    const bouncy: Law = .{ .spring = SpringLaw.from_omega_zeta(8, 0.5) };
    try testing.expectEqual(settled, advance(bouncy, rest, 1, 60));
}

// Locks a Newtonian move from 0 to 20 with speed 4, accel 2, and decel 4: 2 s speeding up over 4,
// 3.5 s cruising, and 1 s slowing over 2, so 1 at 1 s, 4 at 2 s, 18 at 5.5 s, 19.5 at 6 s, and
// exactly 20 at rest from 6.5 s on.
test "a Newtonian move speeds up, cruises, and lands exactly" {
    const law: Law = .{ .newtonian = .{ .speed = 4, .accel = 2, .decel = 4 } };
    const expected = [_][2]f64{ .{ 1, 1 }, .{ 2, 4 }, .{ 5.5, 18 }, .{ 6, 19.5 } };
    for (expected) |row| {
        try testing.expectApproxEqAbs(row[1], advance(law, rest, 20, row[0]).position, 1e-12);
    }
    const landed: Kinematics = .{ .position = 20, .velocity = 0 };
    try testing.expectEqual(landed, advance(law, rest, 20, 6.5));
    try testing.expectEqual(landed, advance(law, rest, 20, 1e6));
}

// Locks the two braking cases of section 5 with speed 4, accel 2, and decel 4. Cruising at 4 past
// a goal 2 behind: brake for 1 s to 14, then come back. A goal 1 ahead, closer than the 2 it takes
// to stop: brake past it to 14, then come back. Each lands exactly, never above the speed.
test "a Newtonian move brakes for a goal behind or too close" {
    const law: Law = .{ .newtonian = .{ .speed = 4, .accel = 2, .decel = 4 } };
    const cruising: Kinematics = .{ .position = 12, .velocity = 4 };
    for ([_]f64{ 10, 13 }) |goal| {
        const braked = advance(law, cruising, goal, 1);
        try testing.expectApproxEqAbs(@as(f64, 14), braked.position, 1e-12);
        try testing.expectApproxEqAbs(@as(f64, 0), braked.velocity, 1e-12);
        var landed: f64 = 0;
        for (0..1000) |index| {
            const seconds = @as(f64, @floatFromInt(index)) / 100;
            const kinematics = advance(law, cruising, goal, seconds);
            try testing.expect(@abs(kinematics.velocity) <= 4 + 1e-12);
            if (landed == 0 and kinematics.velocity == 0 and kinematics.position == goal) {
                landed = seconds;
            }
        }
        try testing.expect(landed > 1);
    }
}

// Locks the table's refusals by name, and that a refused path leaves the table as it was.
test "the goal table refuses a path it cannot hold" {
    var entries: [3]Goal = undefined;
    var goals = Goals.init(&entries);
    try testing.expectError(error.NoGoals, goals.add(&.{}));
    const a: Cue = .{ .index = 0 };
    const b: Cue = .{ .index = 1 };
    try testing.expectError(error.GoalOutOfOrder, goals.add(&.{
        .{ .cue = b, .value = 1 }, .{ .cue = a, .value = 2 },
    }));
    try testing.expectError(error.GoalOutOfOrder, goals.add(&.{
        .{ .cue = a, .value = 1 }, .{ .cue = a, .value = 2 },
    }));
    const nan = std.math.nan(f64);
    try testing.expectError(error.NotFinite, goals.add(&.{.{ .cue = a, .value = nan }}));
    const path = try goals.add(&.{ .{ .cue = a, .value = 1 }, .{ .cue = b, .value = 2 } });
    try testing.expectEqual(Path{ .first = 0, .count = 2 }, path);
    try testing.expectError(error.GoalCapacityExceeded, goals.add(&.{
        .{ .cue = a, .value = 1 }, .{ .cue = b, .value = 2 },
    }));
    try testing.expectEqual(@as(usize, 2), goals.table().len);
    const last = try goals.add(&.{.{ .cue = b, .value = 3 }});
    try testing.expectEqual(Path{ .first = 2, .count = 1 }, last);
}
