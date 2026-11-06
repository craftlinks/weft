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
//! `round(fraction * timeline)`, so 0.5 is 6 s exactly. Time stays in `[0, timeline]`.
//!
//! ## 3. Two Readers
//! The scope and the playhead each hold a `State` over the one program, with checkpoints for
//! `signals.checkpoint_seconds`. The scope samples its window in ascending time, so a frame
//! restores at most one checkpoint and then steps forwards; the playhead reads `t` alone. One
//! `eval` fills every node, so a frame costs `sample_count` evals for all eight rows.
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

pub const Frame = struct {
    samples: [signals.row_count][sample_count]f32,
    /// A node row's goal, sampled.
    goals: [signals.row_count][sample_count]f32,
    /// A path row's goal as `step_counts` steps of a fraction and a value (section 5).
    steps: [signals.row_count][signals.cue_count + 1][2]f32,
    step_counts: [signals.row_count]u32,
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

    pub fn init(motion: *Motion) void {
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

    pub fn sample(motion: *Motion, clock: Clock, frame: *Frame) void {
        const start = clock.t.flicks - signals.ms(before_ms).flicks;
        const span = signals.ms(before_ms + after_ms).flicks;
        const scope = &motion.readers[0];
        for (0..sample_count) |i| {
            const offset = @divFloor(span * @as(i64, @intCast(i)), sample_count - 1);
            const time: weft.Time = .{ .flicks = start + offset };
            scope.eval(time);
            for (motion.signals.rows, 0..) |row, r| {
                frame.samples[r][i] = @floatCast(scope.value(row.id));
                const goal = if (row.goal == .node) scope.value(row.goal.node) else 0;
                frame.goals[r][i] = @floatCast(goal);
            }
        }
        const head = &motion.readers[1];
        head.eval(clock.t);
        for (motion.signals.rows, &frame.heads) |row, *value| {
            value.* = @floatCast(head.value(row.id));
        }
        for (motion.signals.cues.table(), &frame.cues) |cue, *at| {
            at.* = part(cue.flicks - start, span);
        }
        for (motion.signals.rows, &frame.steps, &frame.step_counts) |row, *steps, *count| {
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

// Locks the clock: a 16 ms frame is 11,289,600 flicks and the regress clock's frame 11,760,000; a
// seek to 0.5 is 6 s exactly and to 1 the end; steps and frames clamp at both ends.
test "the clock converts frames and seeks exactly" {
    var clock: Clock = .{};
    clock.advance(16);
    try testing.expectEqual(@as(i64, 11_289_600), clock.t.flicks);
    clock = .{};
    clock.advance(regress_frame_ms);
    try testing.expectEqual(@as(i64, 11_760_000), clock.t.flicks);
    clock.seek(0.5);
    try testing.expectEqual(@as(i64, 6 * weft.time.flicks_per_second), clock.t.flicks);
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

// Locks the scope against Weft: every row's sample at the `scrub` and `play` times is a fresh
// state's value at the same time, bit for bit after the cast to f32, and so is the playhead's.
test "the scope matches a fresh state, bit for bit" {
    const motion = &fixture.motion;
    motion.init();
    var play: Clock = .{};
    play.advance(0);
    for (0..150) |_| play.advance(regress_frame_ms);
    var scrub: Clock = .{};
    scrub.seek(0.5);
    for ([_]Clock{ scrub, play, scrub }) |clock| {
        motion.sample(clock, &fixture.frame);
        const start = clock.t.flicks - signals.ms(before_ms).flicks;
        const span = signals.ms(before_ms + after_ms).flicks;
        for (0..sample_count) |i| {
            var fresh = weft.State.init(motion.signals.program, &fixture.fresh);
            const offset = @divFloor(span * @as(i64, @intCast(i)), sample_count - 1);
            fresh.eval(.{ .flicks = start + offset });
            for (motion.signals.rows, 0..) |row, r| {
                const expected: f32 = @floatCast(fresh.value(row.id));
                const found = fixture.frame.samples[r][i];
                try testing.expectEqual(@as(u32, @bitCast(expected)), @as(u32, @bitCast(found)));
            }
        }
        var fresh = weft.State.init(motion.signals.program, &fixture.fresh);
        fresh.eval(clock.t);
        for (motion.signals.rows, fixture.frame.heads) |row, head| {
            const expected: f32 = @floatCast(fresh.value(row.id));
            try testing.expectEqual(@as(u32, @bitCast(expected)), @as(u32, @bitCast(head)));
        }
    }
}

// Locks the goals: the spring's goal is steps from its goal table, `from` before the first cue, and
// the chase's trace is the noise row's samples. The window at 6 s holds the cues at 6 and 8 s, and
// the one at 0 s starts before the first cue and ends after it.
test "the goal traces follow the goal table and the chase's target" {
    const motion = &fixture.motion;
    motion.init();
    var clock: Clock = .{};
    clock.seek(0.5);
    motion.sample(clock, &fixture.frame);
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
    motion.sample(clock, &fixture.frame);
    const at_0s = [_][2]f32{ .{ 0, 0 }, .{ 0.75, 1 } };
    try testing.expectEqualSlices([2]f32, &at_0s, spring_steps[0..frame.step_counts[spring]]);
}

// Locks the fix for the flicker: at every frame of a play on the regress clock, every goal step
// after the first sits at the very fraction of its cue's line, so the two move together.
test "a goal step stays on its cue line as the window moves" {
    const motion = &fixture.motion;
    motion.init();
    const frame = &fixture.frame;
    var clock: Clock = .{};
    var checked: u32 = 0;
    while (clock.millis() < timeline_ms) : (clock.advance(regress_frame_ms)) {
        motion.sample(clock, frame);
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

// Locks the read-outs: finite ranges for every row, the four classes, and the report.
test "ranges, classes, and the report reach the app as plain values" {
    const motion = &fixture.motion;
    motion.init();
    const classes = [_][]const u8{
        "pure",      "pure",      "pure",      "exact", "exact",
        "simulated", "simulated", "simulated",
    };
    for (motion.ranges, motion.classes, classes) |range, class, expected| {
        try testing.expect(std.math.isFinite(range[0]) and std.math.isFinite(range[1]));
        try testing.expect(range[0] < range[1]);
        try testing.expectEqualStrings(expected, class);
    }
    try testing.expectEqual(@as(f32, -1), motion.ranges[0][0]);
    try testing.expect(motion.report.seekable);
    try testing.expect(motion.report.stepped);
    try testing.expectEqual(@as(?usize, 5), motion.report.first);
}
