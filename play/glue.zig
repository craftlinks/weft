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
//!
//! ## 6. Events as Windows
//! Both pages read events as a window `(start, end]`, which is `events(start + 1, end + 1)` in
//! flicks. The scope reads its own on its reader, interleaved with its samples: the eval at
//! sample i, then the events between samples i and i + 1. An eval exactly on a step leaves the
//! slab one step past it, so a range starting at that very time would restore a checkpoint, and
//! at 60 Hz on the regress clock every window starts on a step. A range one flick on starts at
//! `ceil((s + 1) / step) = floor(s / step) + 1`, the step `eval(s)` left, and ends at the step the
//! next eval needs, so the dots cost a read-only pass a sample and no steps. Each event of a scope
//! row is a dot at its time and value; the other rows' events are read and ignored.
//!
//! The bouncers are a pure program of their own (`signals.zig`, section 4), on a reader with no
//! checkpoints. A frame reads one window for the lanes and the bars, and `(t - 2 s, t]` for each
//! lane's last hit and the log: the slowest leg is under 2 s. Evals at the window's two ends and
//! at t give each lane's ends and its ball, so a lane is a polyline from its start through a
//! corner at each hit to its end, which is the signal, since a bounce is linear between hits.
//! Nothing is stored between frames, so a scrub re-derives every hit from the graph.

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
pub const lane_count = signals.lane_count;
pub const flicks_per_second = weft.time.flicks_per_second;
/// Events one range between two samples keeps; a frame's dots; a bouncer window's hits and bars;
/// and the hits of `(t - 2 s, t]`. The tests prove the timeline never fills them.
pub const range_events_max = 32;
pub const dots_max = 64;
pub const window_hits_max = 96;
pub const bars_max = 3;
pub const recent_hits_max = 48;
const recent_ms = 2000;
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
    /// The scope rows' events in the window (section 6), and what could not be kept.
    dots: [dots_max]Dot,
    dot_count: u32,
    dropped: u64,
};

pub const Dot = struct { row: u8, at: f32, value: f32 };

/// A bouncer's hit: its lane, its time in flicks, its place in the window, and its wall.
pub const Hit = struct { lane: u8, flicks: i64, at: f32, high: bool };

/// The bouncers page at one time (section 6).
pub const Hits = struct {
    window: [window_hits_max]Hit,
    window_count: u32,
    bars: [bars_max]f32,
    bar_count: u32,
    /// The hits of `(t - 2 s, t]`, in order.
    recent: [recent_hits_max]Hit,
    recent_count: u32,
    /// Each lane's value at the window's start and end, and at t.
    ends: [lane_count][2]f32,
    heads: [lane_count]f32,
    /// Seconds since each lane's last hit at or before t, infinite before its first.
    since: [lane_count]f32,
    last_high: [lane_count]bool,
    dropped: u64,
};

pub const Report = struct { seekable: bool, stepped: bool, first: ?usize };

pub const Motion = struct {
    signals: signals.Signals,
    memory: [2][(1 + signals.checkpoint_seconds) * slab]f64,
    /// The scope's reader, then the playhead's.
    readers: [2]weft.State,
    ranges: [signals.row_count][2]f32,
    classes: [signals.row_count][]const u8,
    /// No live node, a read can cost steps, and the row of the first simulated node.
    report: Report,
    bouncers: signals.Bouncers,
    bouncer_slab: [signals.bouncer_node_count]f64,
    bouncer_reader: weft.State,
    bouncer_report: Report,

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
        motion.bouncers.build();
        const bouncers = motion.bouncers.program;
        motion.bouncer_reader = .init(bouncers, &motion.bouncer_slab);
        const plain = bouncers.report();
        motion.bouncer_report = .{
            .seekable = plain.seekable,
            .stepped = plain.stepped,
            .first = null,
        };
    }

    /// The scope's rows over the window around `clock`, their goals, and the cues.
    pub fn sample_window(motion: *Motion, clock: Clock, frame: *Frame) void {
        const start = clock.t.flicks - signals.ms(before_ms).flicks;
        const span = signals.ms(before_ms + after_ms).flicks;
        const scope = &motion.readers[0];
        const rows = motion.signals.rows[0..signals.scope_row_count];
        frame.dot_count = 0;
        frame.dropped = 0;
        var previous: i64 = start;
        for (0..sample_count) |i| {
            const offset = @divFloor(span * @as(i64, @intCast(i)), sample_count - 1);
            const time: weft.Time = .{ .flicks = start + offset };
            if (i > 0) motion.dots(previous, time.flicks, start, span, frame);
            previous = time.flicks;
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

    /// The scope rows' events in `(from, to]` as dots, on the scope's reader (section 6).
    fn dots(motion: *Motion, from: i64, to: i64, start: i64, span: i64, frame: *Frame) void {
        var found: [range_events_max]weft.Event = undefined;
        const result = motion.readers[0].events(one_after(from), one_after(to), &found);
        frame.dropped += result.dropped;
        for (found[0..result.count]) |event| {
            const row = for (motion.signals.rows[0..signals.scope_row_count], 0..) |row, index| {
                if (row.id.index == event.source.index) break index;
            } else continue;
            if (frame.dot_count == dots_max) {
                frame.dropped += 1;
                continue;
            }
            const at = part(event.time.flicks - start, span);
            const value: f32 = @floatCast(event.value);
            frame.dots[frame.dot_count] = .{ .row = @intCast(row), .at = at, .value = value };
            frame.dot_count += 1;
        }
    }

    /// The bouncers page at `clock`: the window's hits and bars, the recent hits, and each lane's
    /// ends, ball, and last hit (section 6).
    pub fn sample_hits(motion: *Motion, clock: Clock, hits: *Hits) void {
        const reader = &motion.bouncer_reader;
        const start = clock.t.flicks - signals.ms(before_ms).flicks;
        const span = signals.ms(before_ms + after_ms).flicks;
        var found: [window_hits_max]weft.Event = undefined;
        const window = reader.events(one_after(start), one_after(start + span), &found);
        hits.window_count = 0;
        hits.bar_count = 0;
        hits.recent_count = 0;
        hits.since = @splat(std.math.inf(f32));
        hits.last_high = @splat(false);
        hits.dropped = window.dropped;
        for (found[0..window.count]) |event| {
            const at = part(event.time.flicks - start, span);
            if (event.source.index == motion.bouncers.bars.index) {
                // A window of 4 s holds two bars of 2 s; one more slot is margin.
                assert(hits.bar_count < bars_max);
                hits.bars[hits.bar_count] = at;
                hits.bar_count += 1;
            } else {
                hits.window[hits.window_count] = motion.hit_of(event, at);
                hits.window_count += 1;
            }
        }
        const back = clock.t.flicks - signals.ms(recent_ms).flicks;
        const now = clock.t.flicks;
        const recent = reader.events(one_after(back), one_after(now), found[0..recent_hits_max]);
        hits.dropped += recent.dropped;
        for (found[0..recent.count]) |event| {
            if (event.source.index == motion.bouncers.bars.index) continue;
            const hit = motion.hit_of(event, part(event.time.flicks - start, span));
            hits.recent[hits.recent_count] = hit;
            hits.recent_count += 1;
            const age: f64 = @floatFromInt(clock.t.flicks - hit.flicks);
            hits.since[hit.lane] = @floatCast(age / flicks_per_second);
            hits.last_high[hit.lane] = hit.high;
        }
        for ([_]i64{ start, start + span, clock.t.flicks }, 0..) |at, which| {
            reader.eval(.{ .flicks = at });
            for (motion.bouncers.lanes, 0..) |lane, index| {
                const value: f32 = @floatCast(reader.value(lane.id));
                if (which == 2) hits.heads[index] = value else hits.ends[index][which] = value;
            }
        }
    }

    /// A bouncer program event as a hit.
    fn hit_of(motion: *const Motion, event: weft.Event, at: f32) Hit {
        const lane = for (motion.bouncers.lanes, 0..) |lane, index| {
            if (lane.id.index == event.source.index) break index;
        } else unreachable;
        const flicks = event.time.flicks;
        return .{ .lane = @intCast(lane), .flicks = flicks, .at = at, .high = event.value > 0 };
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

/// One flick after `flicks`, so a range from it starts after `flicks` (section 6).
fn one_after(flicks: i64) weft.Time {
    return .{ .flicks = flicks + 1 };
}

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
    var hits: Hits = undefined;
    var bouncer_slab: [signals.bouncer_node_count]f64 = undefined;
    var events: [1 << 15]weft.Event = undefined;
    var joined: [1 << 10]weft.Event = undefined;
    /// The windows read at the times every rate shares, per rate after the first.
    var shared_hits: [61]Hits = undefined;
    var shared_dots: [7][dots_max]Dot = undefined;
    var shared_dot_counts: [7]u32 = undefined;
};
const bouncers_draw = @import("bouncers.zig");

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

/// A clock at `flicks`.
fn at_flicks(flicks: i64) Clock {
    return .{ .t = .{ .flicks = flicks } };
}

/// The flicks of lane `lane`'s hits in the last window read.
fn lane_hits(hits: *const Hits, lane: u8, out: []i64) []const i64 {
    var count: usize = 0;
    for (hits.window[0..hits.window_count]) |hit| {
        if (hit.lane != lane) continue;
        out[count] = hit.flicks;
        count += 1;
    }
    return out[0..count];
}

// Locks the hit times against step 7's worked bounce: the 0.7 lane's hits at 2 s, in (1 s, 5 s],
// are 1,008,000,001, 2,016,000,001, and 3,024,000,001 flicks, up, down, up. At 300 s the other six
// hit the floor at 300 s exactly, every hit of theirs is a whole multiple of its leg, and the 0.7
// lane's 210th hit is one flick after 300 s. The bars are at 300 s and 302 s.
test "the bouncers hit at step 7's worked times and on the bars" {
    const motion = &fixture.motion;
    motion.build();
    const hits = &fixture.hits;
    motion.sample_hits(at_flicks(signals.ms(2000).flicks), hits);
    var buffer: [24]i64 = undefined;
    const worked = [_]i64{ 1_008_000_001, 2_016_000_001, 3_024_000_001 };
    try testing.expectEqualSlices(i64, &worked, lane_hits(hits, 0, &buffer));
    const walls = [_]bool{ true, false, true };
    var index: usize = 0;
    for (hits.window[0..hits.window_count]) |hit| {
        if (hit.lane != 0) continue;
        try testing.expectEqual(walls[index], hit.high);
        index += 1;
    }
    const t300 = signals.ms(300_000).flicks;
    motion.sample_hits(at_flicks(t300), hits);
    try testing.expectEqual(@as(u64, 0), hits.dropped);
    for (motion.bouncers.lanes[1..], 1..) |lane, lane_index| {
        const leg: i64 = @intFromFloat(flicks_per_second / lane.speed);
        const product = @as(f64, @floatFromInt(leg)) * lane.speed;
        try testing.expectEqual(@as(f64, flicks_per_second), product);
        const flicks = lane_hits(hits, @intCast(lane_index), &buffer);
        try testing.expect(flicks.len >= 4);
        for (flicks) |at| try testing.expectEqual(@as(i64, 0), @mod(at, leg));
        try testing.expectEqual(@as(f32, 0), hits.since[lane_index]);
        try testing.expect(!hits.last_high[lane_index]);
    }
    try testing.expectEqual(t300 + 1, lane_hits(hits, 0, &buffer)[0]);
    try testing.expect(hits.since[0] > 1);
    try testing.expectEqualSlices(f32, &.{ 0.25, 0.75 }, hits.bars[0..hits.bar_count]);
}

/// Whether two reads of the bouncers page are the same, field by field where it was written.
fn expect_same_hits(expected: *const Hits, found: *const Hits) !void {
    const bytes = std.mem.sliceAsBytes;
    const window = expected.window[0..expected.window_count];
    try testing.expectEqualSlices(u8, bytes(window), bytes(found.window[0..found.window_count]));
    const bars = expected.bars[0..expected.bar_count];
    try testing.expectEqualSlices(f32, bars, found.bars[0..found.bar_count]);
    const recent = expected.recent[0..expected.recent_count];
    try testing.expectEqualSlices(u8, bytes(recent), bytes(found.recent[0..found.recent_count]));
    try testing.expectEqualDeep(expected.ends, found.ends);
    try testing.expectEqualDeep(expected.heads, found.heads);
    try testing.expectEqualDeep(expected.since, found.since);
    try testing.expectEqualDeep(expected.last_high, found.last_high);
}

// Locks the frame-rate rule: frames at 30, 60, and 144 Hz on exact flicks, each reading
// `events(t_prev, t)` as a sound reader would, deliver the same events over 10 s, equal byte for
// byte to one query of the 10 s, each in the first frame past it. At the times the three rates
// share, every 1/6 s, the bouncer windows are the same, and over 4 s to 5 s so are the scope's
// dots, though each reader reached them by a different path of restores and steps.
test "frames at 30, 60, and 144 Hz see the same events" {
    const motion = &fixture.motion;
    motion.build();
    const program = motion.bouncers.program;
    const ten: i64 = 10 * flicks_per_second;
    const shared: i64 = @divExact(flicks_per_second, 6);
    var whole_reader = weft.State.init(program, &fixture.bouncer_slab);
    const whole = whole_reader.events(.{ .flicks = 0 }, .{ .flicks = ten }, &fixture.events);
    try testing.expectEqual(@as(u64, 0), whole.dropped);
    // In [0, 10 s): the 0.7 lane's 6 hits, 9 + 14 + 19 + 24 + 29 + 34 of the others (each lane's
    // hit at 10 s itself is out of range), and the bars at 0, 2, 4, 6, and 8 s.
    try testing.expectEqual(@as(u32, 6 + 129 + 5), whole.count);
    for ([_]i64{ 30, 60, 144 }, 0..) |rate, which| {
        var reader = weft.State.init(program, &fixture.bouncer_slab);
        var count: usize = 0;
        var previous: i64 = 0;
        var frame: i64 = 1;
        while (frame <= 10 * rate) : (frame += 1) {
            const t = @divExact(frame * flicks_per_second, rate);
            const out = fixture.joined[count..];
            const result = reader.events(.{ .flicks = previous }, .{ .flicks = t }, out);
            try testing.expectEqual(@as(u64, 0), result.dropped);
            for (out[0..result.count]) |event| {
                try testing.expect(event.time.flicks >= previous and event.time.flicks < t);
            }
            count += result.count;
            previous = t;
            if (@mod(t, shared) != 0) continue;
            const slot = &fixture.shared_hits[@intCast(@divExact(t, shared))];
            if (which == 0) {
                motion.sample_hits(at_flicks(t), slot);
            } else {
                motion.sample_hits(at_flicks(t), &fixture.hits);
                try expect_same_hits(slot, &fixture.hits);
            }
        }
        const expected = std.mem.sliceAsBytes(fixture.events[0..whole.count]);
        try testing.expectEqualSlices(u8, expected, std.mem.sliceAsBytes(fixture.joined[0..count]));
    }
    var dots_seen: u32 = 0;
    for ([_]i64{ 30, 60, 144 }, 0..) |rate, which| {
        motion.build();
        var frame: i64 = 4 * rate;
        while (frame <= 5 * rate) : (frame += 1) {
            const t = @divExact(frame * flicks_per_second, rate);
            motion.sample_window(at_flicks(t), &fixture.frame);
            try testing.expectEqual(@as(u64, 0), fixture.frame.dropped);
            if (@mod(t, shared) != 0) continue;
            const slot: usize = @intCast(@divExact(t, shared) - 24);
            const dots = fixture.frame.dots[0..fixture.frame.dot_count];
            if (which == 0) {
                @memcpy(fixture.shared_dots[slot][0..dots.len], dots);
                fixture.shared_dot_counts[slot] = fixture.frame.dot_count;
                dots_seen += fixture.frame.dot_count;
            } else {
                const kept = fixture.shared_dots[slot][0..fixture.shared_dot_counts[slot]];
                const bytes = std.mem.sliceAsBytes;
                try testing.expectEqualSlices(u8, bytes(kept), bytes(dots));
            }
        }
    }
    try testing.expect(dots_seen > 20);
}

// Locks the dots against a fresh reader: at 6 s, then after a read at 500 s, at 300 s, the
// scope's dots are a fresh reader's events of the window `(start, end]` for the scope's rows, in
// order. Over the first 12 s, each goal a spring or the Newtonian move reaches is its value
// there, bit for bit, so its dot sits on its trace.
test "the scope's dots are a fresh reader's events" {
    const motion = &fixture.motion;
    motion.build();
    const span = signals.ms(before_ms + after_ms).flicks;
    const scope_rows = motion.signals.rows[0..scope_row_count];
    for ([_]i64{ 6000, 500_000, 300_000 }) |ms| {
        const clock = at_flicks(signals.ms(ms).flicks);
        motion.sample_window(clock, &fixture.frame);
        if (ms == 500_000) continue;
        const start = clock.t.flicks - signals.ms(before_ms).flicks;
        var fresh = weft.State.init(motion.signals.program, &fixture.fresh);
        const result = fresh.events(one_after(start), one_after(start + span), &fixture.events);
        try testing.expectEqual(@as(u64, 0), result.dropped);
        var count: u32 = 0;
        for (fixture.events[0..result.count]) |event| {
            const row = for (scope_rows, 0..) |row, index| {
                if (row.id.index == event.source.index) break index;
            } else continue;
            const dot = fixture.frame.dots[count];
            try testing.expectEqual(@as(u8, @intCast(row)), dot.row);
            try testing.expectEqual(part(event.time.flicks - start, span), dot.at);
            try expect_bits(event.value, dot.value);
            count += 1;
        }
        try testing.expectEqual(count, fixture.frame.dot_count);
        try testing.expect(count > 8);
    }
    var fresh = weft.State.init(motion.signals.program, &fixture.fresh);
    const goals = .{ scope_rows[3].id, scope_rows[4].id };
    const twelve = signals.ms(12_000);
    const result = fresh.events(.{ .flicks = 0 }, twelve, &fixture.events);
    var reached: u32 = 0;
    for (fixture.events[0..result.count]) |event| {
        if (event.source.index != goals[0].index and event.source.index != goals[1].index) continue;
        var check = weft.State.init(motion.signals.program, &fixture.fresh);
        check.eval(event.time);
        const value = check.value(event.source);
        try testing.expectEqual(@as(u64, @bitCast(event.value)), @as(u64, @bitCast(value)));
        reached += 1;
    }
    try testing.expect(reached >= 2);
}

// Locks the polyline: at 6 s and 300 s, at every sample time of the window, a lane's stroke,
// from its ends and the corners at its hits, is the lane's value within f32 rounding.
test "a lane's polyline is its signal" {
    const motion = &fixture.motion;
    motion.build();
    const span = signals.ms(before_ms + after_ms).flicks;
    var reader = weft.State.init(motion.bouncers.program, &fixture.bouncer_slab);
    for ([_]i64{ 6000, 300_000 }) |ms| {
        const clock = at_flicks(signals.ms(ms).flicks);
        motion.sample_hits(clock, &fixture.hits);
        const start = clock.t.flicks - signals.ms(before_ms).flicks;
        for (motion.bouncers.lanes, 0..) |lane, index| {
            var out: [bouncers_draw.points_max][2]f32 = undefined;
            const ends = fixture.hits.ends[index];
            const window = fixture.hits.window[0..fixture.hits.window_count];
            const points = bouncers_draw.polyline(ends[0], ends[1], window, index, &out);
            try testing.expect(points.len >= 3);
            var segment: usize = 0;
            for (0..sample_count) |i| {
                const offset = @divFloor(span * @as(i64, @intCast(i)), sample_count - 1);
                const at: f32 = part(offset, span);
                while (segment + 2 < points.len and points[segment + 1][0] < at) segment += 1;
                const a = points[segment];
                const b = points[segment + 1];
                const w = if (b[0] > a[0]) (at - a[0]) / (b[0] - a[0]) else 0;
                const stroke = a[1] + (b[1] - a[1]) * w;
                reader.eval(.{ .flicks = start + offset });
                const value: f32 = @floatCast(reader.value(lane.id));
                try testing.expectApproxEqAbs(value, stroke, 1e-5);
            }
        }
    }
}

/// The most of `times` in any window `(s, s + width]`, for sorted `times`.
fn most_in(times: []const i64, width: i64) usize {
    var most: usize = 0;
    var first: usize = 0;
    for (times, 0..) |time, last| {
        while (times[first] <= time - width) first += 1;
        most = @max(most, last - first + 1);
    }
    return most;
}

// Locks the buffers: over the whole timeline and the window after it, the scope rows' events in
// any window, every event between two samples, a bouncer window's hits and bars, and the hits of
// any 2 s fit what the glue keeps, so no frame drops one.
test "no window drops an event over the timeline" {
    const motion = &fixture.motion;
    motion.build();
    const end = signals.ms(timeline_ms + after_ms + 1000);
    var reader = weft.State.init(motion.signals.program, &fixture.fresh);
    const all = reader.events(.{ .flicks = 0 }, end, &fixture.events);
    try testing.expectEqual(@as(u64, 0), all.dropped);
    var times: [1 << 15]i64 = undefined;
    for (fixture.events[0..all.count], 0..) |event, index| times[index] = event.time.flicks;
    const span = signals.ms(before_ms + after_ms).flicks;
    const gap = @divFloor(span, sample_count - 1) + 1;
    try testing.expect(most_in(times[0..all.count], gap) <= range_events_max);
    var count: usize = 0;
    for (fixture.events[0..all.count]) |event| {
        for (motion.signals.rows[0..scope_row_count]) |row| {
            if (row.id.index != event.source.index) continue;
            times[count] = event.time.flicks;
            count += 1;
        }
    }
    // 25 as built: the follower's arrivals and the shift register's buckets.
    try testing.expect(most_in(times[0..count], span) <= dots_max);
    var bouncer = weft.State.init(motion.bouncers.program, &fixture.bouncer_slab);
    const hits = bouncer.events(.{ .flicks = 0 }, end, &fixture.events);
    try testing.expectEqual(@as(u64, 0), hits.dropped);
    for (fixture.events[0..hits.count], 0..) |event, index| times[index] = event.time.flicks;
    try testing.expect(most_in(times[0..hits.count], span) <= window_hits_max);
    const recent = signals.ms(recent_ms).flicks;
    try testing.expect(most_in(times[0..hits.count], recent) <= recent_hits_max);
}
