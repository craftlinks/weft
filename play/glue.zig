//! The glue: every line of Play, beside the signal table, that names a Weft type.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Boundary
//! `app.zig` and `scope.zig` never import `weft`. What they need crosses here as `f32` arrays and
//! plain structs: time as a `Clock`, the scope's samples as a `Frame`, and ranges, classes, and the
//! report as `Motion` fields. The budget is 60 lines of code: not blank, not a comment, not a test.
//! If the glue outgrows it, the boundary or Weft's API is wrong.
//!
//! ## 2. Time Follows Frames
//! `Clock` holds Weft time in flicks. A frame's delta is milliseconds as an `f32`, which the app
//! clamps, and becomes flicks as `round(dt * 705,600)` in f64: a whole millisecond is exact, and
//! the regress clock's 1000/60 ms gives 11,760,000 flicks on every host. A seek is
//! `round(fraction * timeline)`, so 0.5 is 300 s exactly. Time stays in `[0, timeline]`.
//!
//! ## 3. Two Readers
//! The scope and the playhead each hold a `State` over the one program, with checkpoints for
//! `signals.checkpoint_seconds`. The scope samples its window in ascending time, so a frame
//! restores at most one checkpoint and then steps forwards; the playhead reads `t` alone. One
//! `eval` fills every node, so the scope costs `sample_count` evals a frame for its eight rows.
//! `sample_window` and `sample_head` are apart, so the shapes page reads the playhead only.
//!
//! ## 3a. Knobs
//! `build` makes the program once. A knob is a track (Weft's step 9.5): `write` latches its
//! parameter from t on, and the readers drop only the checkpoints after t at their next read, so a
//! knob applies from now on, costs about a microsecond at the playhead, and scrubbing back shows
//! what was played. `knob` reads the parameter at t back, so a knob can show it.
//!
//! ## 4. The Window
//! From `t - before_ms` to `t + after_ms`, sample i at `start + floor(i * span / (n - 1))` flicks,
//! so the first sample is at the start, the last at the end, and every time is a whole flick. The
//! playhead is at `before / span`, a quarter of the width. A cue is a fraction of the window, and
//! one outside `[0, 1]` is not in it.
//!
//! ## 5. Goals
//! A path row's goal at a time is the value of the last goal whose cue is at or before it, or
//! `from` before the first, as `motion.zig` section 1 defines. It only changes at cues, so it is
//! not sampled: it crosses as steps, the goal at the window's start at 0, then each goal whose cue
//! is in the window at that cue's fraction, the very `f32` the cue line gets. Sampled on the grid,
//! a jump would fall between two samples and move in whole sample widths while the cue line moves
//! smoothly, which flickers. A node row's goal is that node's value, sampled like the signal.
//! Other rows have none, and their goal samples are zeros that the app does not draw.

const std = @import("std");
const assert = std.debug.assert;
const weft = @import("weft");
const signals = @import("signals.zig");

pub const row_count = signals.row_count;
pub const scope_row_count = signals.scope_row_count;
pub const timeline_ms = signals.timeline_ms;
pub const sample_count = 256;
pub const before_ms = 1000;
pub const after_ms = 3000;
const timeline = signals.ms(signals.timeline_ms).flicks;
const flicks_per_ms: f64 = @floatFromInt(signals.ms(1).flicks);
const slab = signals.slab_count_max;

pub const Clock = struct {
    t: weft.Time = .{ .flicks = 0 },

    pub fn advance(clock: *Clock, dt_ms: f32) void {
        const flicks: i64 = @intFromFloat(@round(dt_ms * flicks_per_ms));
        clock.t.flicks = std.math.clamp(clock.t.flicks + flicks, 0, timeline);
    }

    pub fn seek(clock: *Clock, to: f32) void {
        assert(to >= 0 and to <= 1);
        clock.t.flicks = @intFromFloat(@round(to * @as(f64, timeline)));
    }

    pub fn step(clock: *Clock, ms: i64) void {
        clock.t.flicks = std.math.clamp(clock.t.flicks + signals.ms(ms).flicks, 0, timeline);
    }

    pub fn fraction(clock: Clock) f32 {
        return @floatCast(@as(f64, @floatFromInt(clock.t.flicks)) / timeline);
    }

    /// Whole milliseconds, rounded down, so it is `signals.timeline_ms` only at the end.
    pub fn millis(clock: Clock) i64 {
        return @divFloor(clock.t.flicks, signals.ms(1).flicks);
    }
};

/// The scope's rows sampled over the window, and every row at the playhead.
pub const Frame = struct {
    samples: [signals.scope_row_count][sample_count]f32,
    /// A node row's goal, sampled.
    goals: [signals.scope_row_count][sample_count]f32,
    /// A path row's goal as `step_counts` steps of a fraction and a value (section 5).
    steps: [signals.scope_row_count][signals.cue_count + 1][2]f32,
    step_counts: [signals.scope_row_count]u32,
    /// The playhead reader's value of each row.
    heads: [signals.row_count]f32,
    cues: [signals.cue_count]f32,
};

pub const Motion = struct {
    signals: signals.Signals,
    memory: [2][(1 + signals.checkpoint_seconds) * slab]f64,
    /// The scope's reader, then the playhead's.
    readers: [2]weft.State,
    ranges: [signals.row_count][2]f32,
    classes: [signals.row_count][]const u8,
    /// No live node, a read can cost steps, and the row of the first simulated node.
    report: struct { seekable: bool, stepped: bool, first: ?usize },

    /// Builds the program and starts both readers fresh (section 3a).
    pub fn build(motion: *Motion) void {
        motion.signals.build();
        const program = motion.signals.program;
        for (&motion.readers, &motion.memory) |*reader, *memory| {
            reader.* = .init_with_checkpoints(program, memory[0..slab], memory[slab..]);
        }
        var ranges: [signals.node_count_max]weft.Range = undefined;
        var classes: [signals.node_count_max]weft.Class = undefined;
        program.ranges(&ranges);
        program.classes(&classes);
        const report = program.report();
        motion.report = .{ .seekable = report.seekable, .stepped = report.stepped, .first = null };
        for (motion.signals.rows, 0..) |row, index| {
            const range = ranges[row.id.index];
            motion.ranges[index] = .{ @floatCast(range.low), @floatCast(range.high) };
            motion.classes[index] = @tagName(classes[row.id.index]);
            if (std.meta.eql(report.first_simulated, row.id)) motion.report.first = index;
        }
    }

    /// The scope's rows over the window around `clock`, their goals, and the cues.
    pub fn sample_window(motion: *Motion, clock: Clock, frame: *Frame) void {
        const start = clock.t.flicks - signals.ms(before_ms).flicks;
        const span = signals.ms(before_ms + after_ms).flicks;
        const scope = &motion.readers[0];
        const rows = motion.signals.rows[0..signals.scope_row_count];
        for (0..sample_count) |i| {
            const offset = @divFloor(span * @as(i64, @intCast(i)), sample_count - 1);
            const time: weft.Time = .{ .flicks = start + offset };
            scope.eval(time);
            for (rows, 0..) |row, r| {
                frame.samples[r][i] = @floatCast(scope.value(row.id));
                const goal = if (row.goal == .node) scope.value(row.goal.node) else 0;
                frame.goals[r][i] = @floatCast(goal);
            }
        }
        for (motion.signals.cues.table(), &frame.cues) |cue, *at| {
            at.* = part(cue.flicks - start, span);
        }
        for (rows, &frame.steps, &frame.step_counts) |row, *steps, *count| {
            count.* = 0;
            const goal = if (row.goal == .path) row.goal.path else continue;
            steps[0] = .{ 0, @floatCast(goal.from) };
            count.* = 1;
            for (motion.signals.goals.table()[goal.path.first..][0..goal.path.count]) |entry| {
                const offset = motion.signals.cues.at(entry.cue).flicks - start;
                if (offset <= 0) steps[0][1] = @floatCast(entry.value);
                if (offset <= 0 or offset > span) continue;
                steps[count.*] = .{ part(offset, span), @floatCast(entry.value) };
                count.* += 1;
            }
        }
    }

    /// Latches knob `index`'s parameter at `value` from `clock` on (section 3a). False when its
    /// track is full, which changes nothing.
    pub fn write(motion: *Motion, index: usize, clock: Clock, value: f64) bool {
        const id = motion.signals.knobs[index];
        motion.signals.tracks.write(id, clock.t, value) catch return false;
        return true;
    }

    /// Knob `index`'s parameter at `clock`.
    pub fn knob(motion: *const Motion, index: usize, clock: Clock) f64 {
        return motion.signals.tracks.value(motion.signals.knobs[index], clock.t);
    }

    /// Every row's value at `clock`, from the playhead reader.
    pub fn sample_head(motion: *Motion, clock: Clock, frame: *Frame) void {
        const head = &motion.readers[1];
        head.eval(clock.t);
        for (motion.signals.rows, &frame.heads) |row, *value| {
            value.* = @floatCast(head.value(row.id));
        }
    }
};

/// `offset` as a fraction of the window `span`, the same `f32` for a cue line and a goal step.
fn part(offset: i64, span: i64) f32 {
    return @floatCast(@as(f64, @floatFromInt(offset)) / @as(f64, @floatFromInt(span)));
}

const testing = std.testing;

/// Static, for its size, and in place, since its program points into it.
const fixture = struct {
    var motion: Motion = undefined;
    var frame: Frame = undefined;
    var fresh: [slab]f64 = undefined;
};

/// The regress clock's frame, as `patchwork.bench.frame_ms` gives it.
const regress_frame_ms: f32 = 1000.0 / 60.0;

/// Whether `found` is `expected` cast to f32, bit for bit.
fn expect_bits(expected: f64, found: f32) !void {
    const cast: f32 = @floatCast(expected);
    try testing.expectEqual(@as(u32, @bitCast(cast)), @as(u32, @bitCast(found)));
}

/// A fresh state's value of `row` at `flicks`, from a state with no checkpoints.
fn fresh_value(motion: *const Motion, row: usize, flicks: i64) f64 {
    var fresh = weft.State.init(motion.signals.program, &fixture.fresh);
    fresh.eval(.{ .flicks = flicks });
    return fresh.value(motion.signals.rows[row].id);
}

// Locks the clock: a 16 ms frame is 11,289,600 flicks and the regress clock's frame 11,760,000; a
// seek to 0.5 is 300 s exactly and to 1 the end; steps and frames clamp at both ends.
test "the clock converts frames and seeks exactly" {
    var clock: Clock = .{};
    clock.advance(16);
    try testing.expectEqual(@as(i64, 11_289_600), clock.t.flicks);
    clock = .{};
    clock.advance(regress_frame_ms);
    try testing.expectEqual(@as(i64, 11_760_000), clock.t.flicks);
    clock.seek(0.5);
    try testing.expectEqual(@as(i64, 300 * weft.time.flicks_per_second), clock.t.flicks);
    try testing.expectEqual(@as(f32, 0.5), clock.fraction());
    clock.seek(1);
    try testing.expectEqual(timeline, clock.t.flicks);
    try testing.expectEqual(@as(i64, timeline_ms), clock.millis());
    clock.advance(100);
    try testing.expectEqual(timeline, clock.t.flicks);
    clock.step(-100);
    try testing.expectEqual(@as(i64, timeline_ms - 100), clock.millis());
    clock.seek(0);
    clock.step(-100);
    try testing.expectEqual(@as(i64, 0), clock.t.flicks);
}

// Locks the scope against Weft: every sample at 6 s and at the `play` scenario's end is a fresh
// state's value at the same time, bit for bit after the cast to f32, and so is every row at the
// playhead. At the `scrub` time, 300 s, a fresh state costs 144,000 steps, so three samples and
// the playhead are checked there.
test "the scope matches a fresh state, bit for bit" {
    const motion = &fixture.motion;
    motion.build();
    var play: Clock = .{};
    for (0..151) |_| play.advance(regress_frame_ms);
    var six: Clock = .{};
    six.step(6000);
    var scrub: Clock = .{};
    scrub.seek(0.5);
    const span = signals.ms(before_ms + after_ms).flicks;
    for ([_]Clock{ six, play, scrub, six }) |clock| {
        motion.sample_window(clock, &fixture.frame);
        motion.sample_head(clock, &fixture.frame);
        const start = clock.t.flicks - signals.ms(before_ms).flicks;
        const every = clock.millis() < 10_000;
        for (0..sample_count) |i| {
            if (!every and i != 0 and i != 128 and i != sample_count - 1) continue;
            const offset = @divFloor(span * @as(i64, @intCast(i)), sample_count - 1);
            var fresh = weft.State.init(motion.signals.program, &fixture.fresh);
            fresh.eval(.{ .flicks = start + offset });
            for (motion.signals.rows[0..scope_row_count], 0..) |row, r| {
                try expect_bits(fresh.value(row.id), fixture.frame.samples[r][i]);
            }
        }
        var fresh = weft.State.init(motion.signals.program, &fixture.fresh);
        fresh.eval(clock.t);
        for (motion.signals.rows, fixture.frame.heads) |row, head| {
            try expect_bits(fresh.value(row.id), head);
        }
    }
}

// Locks the goals: the spring's goal is steps from its goal table, `from` before the first cue, and
// the chase's trace is the noise row's samples. The window at 6 s holds the cues at 6 and 8 s, and
// the one at 0 s starts before the first cue and ends after it.
test "the goal traces follow the goal table and the chase's target" {
    const motion = &fixture.motion;
    motion.build();
    var clock: Clock = .{};
    clock.step(6000);
    motion.sample_window(clock, &fixture.frame);
    const frame = &fixture.frame;
    const spring = 3;
    const noise = 1;
    const chase = 5;
    try testing.expectEqualStrings("spring", motion.signals.rows[spring].name);
    try testing.expectEqualStrings("chase", motion.signals.rows[chase].name);
    // The window is 5 s to 9 s: the 6 s cue at a quarter, the 8 s cue at three quarters.
    try testing.expectEqual(@as(f32, 0.25), frame.cues[3]);
    try testing.expectEqual(@as(f32, 0.75), frame.cues[4]);
    const at_6s = [_][2]f32{ .{ 0, 1 }, .{ 0.25, -0.5 }, .{ 0.75, 0.25 } };
    const spring_steps = &frame.steps[spring];
    try testing.expectEqualSlices([2]f32, &at_6s, spring_steps[0..frame.step_counts[spring]]);
    try testing.expectEqualSlices(f32, &frame.samples[noise], &frame.goals[chase]);
    for (frame.step_counts, 0..) |count, row| {
        const path = motion.signals.rows[row].goal == .path;
        try testing.expectEqual(path, count > 0);
    }
    clock.seek(0);
    motion.sample_window(clock, &fixture.frame);
    const at_0s = [_][2]f32{ .{ 0, 0 }, .{ 0.75, 1 } };
    try testing.expectEqualSlices([2]f32, &at_0s, spring_steps[0..frame.step_counts[spring]]);
}

// Locks the fix for the flicker: at every frame of the first 12 s on the regress clock, where the
// cues are, every goal step after the first sits at the very fraction of its cue's line.
test "a goal step stays on its cue line as the window moves" {
    const motion = &fixture.motion;
    motion.build();
    const frame = &fixture.frame;
    var clock: Clock = .{};
    var checked: u32 = 0;
    while (clock.millis() < 12_000) : (clock.advance(regress_frame_ms)) {
        motion.sample_window(clock, frame);
        for (frame.steps, frame.step_counts) |steps, count| {
            if (count == 0) continue;
            for (steps[1..count]) |step| {
                const on_a_cue = std.mem.indexOfScalar(f32, &frame.cues, step[0]) != null;
                try testing.expect(on_a_cue);
                checked += 1;
            }
        }
    }
    try testing.expect(checked > 1000);
}

// Locks the read-outs: a finite range for every row but the chase, whose spring time comes from a
// track and so has no bound (Weft's step 9.5); the classes, the pulse an oscillator now; and the
// report.
test "ranges, classes, and the report reach the app as plain values" {
    const motion = &fixture.motion;
    motion.build();
    const classes = [_][]const u8{
        "pure",      "pure",      "pure",      "exact",     "exact",
        "simulated", "simulated", "simulated", "simulated", "simulated",
        "pure",      "simulated", "simulated", "simulated", "simulated",
        "simulated",
    };
    for (motion.ranges, motion.classes, classes, 0..) |range, class, expected, row| {
        const finite = std.math.isFinite(range[0]) and std.math.isFinite(range[1]);
        try testing.expectEqual(row != 5, finite);
        try testing.expect(range[0] < range[1]);
        try testing.expectEqualStrings(expected, class);
    }
    try testing.expectEqual(@as(f32, -1), motion.ranges[0][0]);
    try testing.expect(motion.report.seekable);
    try testing.expect(motion.report.stepped);
    try testing.expectEqual(@as(?usize, 5), motion.report.first);
}

// Locks what a knob means: a write of `chase s` at 1 s, at 2.5 s, leaves every sample of the
// scope's chase before 2.5 s as it was, bit for bit, changes the ones after, and gives a fresh
// state's values at every sample, bit for bit.
test "a knob write applies from now on" {
    const motion = &fixture.motion;
    motion.build();
    var clock: Clock = .{};
    clock.step(2500);
    const chase = 5;
    motion.sample_window(clock, &fixture.frame);
    const before: [sample_count]f32 = fixture.frame.samples[chase];
    try testing.expect(motion.write(1, clock, 1));
    try testing.expectEqual(@as(f64, 1), motion.knob(1, clock));
    motion.sample_window(clock, &fixture.frame);
    const after = &fixture.frame.samples[chase];
    const start = clock.t.flicks - signals.ms(before_ms).flicks;
    const span = signals.ms(before_ms + after_ms).flicks;
    var changed: u32 = 0;
    for (0..sample_count) |i| {
        const offset = @divFloor(span * @as(i64, @intCast(i)), sample_count - 1);
        if (start + offset < clock.t.flicks) {
            try testing.expectEqual(@as(u32, @bitCast(before[i])), @as(u32, @bitCast(after[i])));
        } else if (before[i] != after[i]) changed += 1;
        try expect_bits(fresh_value(motion, chase, start + offset), after[i]);
    }
    try testing.expect(changed > 100);
}
