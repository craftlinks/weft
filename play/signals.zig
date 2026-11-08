//! The signals Play shows: two Weft files, `signals.weft` and `bouncers.weft`, compiled once, and
//! the rows that name what to show.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What Is Here
//! The text is the signal table. `Signals.build` compiles `signals.weft` (Weft's language, step
//! 12) and finds each row's node, the knobs' tracks, and each row's goal by name; this file keeps
//! only what the text does not know: a row's accent, and which rows the scope shows. The knobs
//! never rebuild the program: each is a track (Weft's step 9.5) that a node reads, and the app
//! writes it at t, so a knob applies from now on. This file describes the signals; it is not glue,
//! so it is not counted in the glue's budget (`glue.zig`).
//!
//! ```text
//! cues   c0 to c5, every 2 s from 0 s   timeline 600 s, seed 7, simulated nodes start at c0
//! row        signal                                                     class
//! wave       sine, 0.5 Hz                                               pure
//! noise      smooth, 1 Hz, seed 1                                       pure
//! tween      0 to 1 at 2 s over 1 s, then to -0.5 at 6 s, following it  pure
//! spring     from 0; 1 at 2 s, -0.5 at 6 s, 0.25 at 8 s; 0.5 s, 0.2     exact
//! newtonian  the same goals; speed 2, accel 8, decel 4                  exact
//! chase      the noise; time from chase_s, overshoot 0.1                simulated
//! follow     [-1, -0.5] and [0.5, 1], random, spring 0.25 s, seed 2     simulated
//! shift      8 buckets, 2 s, [-1, 1], odds 0.25, smooth, seed 3         simulated
//! sway       [-1, 1], random, spring 0.8 s, overshoot from sway_os, 4   simulated
//! pulse      an oscillator, sine, its rate from pulse_hz                simulated
//! drift      smooth, 0.25 Hz, seed 5                                    pure
//! soft       [0, 1], spring 1 s, overshoot 0, seed 6                    simulated
//! snappy     [0, 1], spring 0.3 s, overshoot 0.1, seed 7                simulated
//! bouncy     [0, 1], spring 0.6 s, overshoot 0.5, seed 8                simulated
//! glide_a    [0, 1], Newtonian, speed from glide_v, accel and decel 16, 9  simulated
//! glide_b    the same, seed 10                                          simulated
//! ```
//! The first `scope_row_count` rows are the scope's; every row is a source for the shapes page.
//!
//! ## 2. Goals
//! A row's goal comes from the compiled file (`Compiled.goal`), so the glue never reads a node's
//! op: a path in the goal table with the value before its first goal, a node whose value is the
//! goal (a chase's target), or none. A follower and a shift register keep their goals in the slab,
//! which the glue must not read, so they have none (the step 10 missing list, for step 18).
//!
//! ## 3. Memory
//! `Program` holds pointers into the compiled file's tables, and `cues`, `goals`, and `tracks`
//! point there too, so a `Signals` is built in place and never moves. Play keeps it inside `App`,
//! which the host and the tests keep in static memory. A compile error here is a mistake in the
//! text, not a run-time condition, so it is unreachable; a test compiles both files.
//!
//! ## 4. The Bouncers
//! The bouncers page has a program of its own, `Bouncers`, from `bouncers.weft`, which is pure:
//! ```text
//! cues   bar[0] to bar[300], every 2 s from 0 to 600 s
//! lane   0.7  1  1.5  2  2.5  3  3.5   units a second, between 0 and 1 from bar[0]
//! bars   one `cues` node over every bar
//! ```
//! Six legs are whole flicks, so those lanes hit 2 to 7 times a bar, exactly on the bars. The
//! 0.7 lane is step 7's worked bounce, whose hits land one flick after the exact multiples.
//!
//! ## 5. TigerStyle Invariants
//! - Every capacity is a constant here, the compiler's limits, and the build asserts the program
//!   fits them.

const std = @import("std");
const assert = std.debug.assert;
const weft = @import("weft");

/// Rows: the scope's eight, then the shapes page's eight sources.
pub const row_count = 16;
pub const scope_row_count = 8;
pub const cue_count = 6;
pub const node_count_max = 24;
/// The program's slab, 112 f64 as built, which the build asserts it fits: two readers'
/// checkpoints for 604 s are about 1.1 MB, so the bound stays close.
pub const slab_count_max = 112;
/// Seconds of checkpoints each reader has room for: the timeline, the scope's window after it,
/// and one more, so a scrub anywhere restores one.
pub const checkpoint_seconds = 604;

pub const timeline_ms: i64 = 600_000;

pub const knob_count = 4;
/// The tracks the knobs write, by name, in the order of the knob row.
pub const knob_names = [knob_count][]const u8{ "pulse_hz", "chase_s", "sway_os", "glide_v" };
/// Writes each track holds: about two minutes of a knob turned every frame at 60 Hz. A full track
/// refuses a write, which changes nothing.
pub const track_samples_max = 8192;

pub const source = @embedFile("signals.weft");

const Compiled = weft.lang.Compiled(.{
    .tokens = 1024,
    .tree = 512,
    .names = 64,
    .nodes = node_count_max,
    .slab = slab_count_max,
    .cues = cue_count,
    .goals = 3,
    .regions = 4,
    .tracks = knob_count,
    .track_samples = track_samples_max,
    .errors = 4,
});

/// Where a row's goal trace comes from (section 2).
pub const Goal = union(enum) {
    none,
    /// The goals of a path, and `from` before its first goal.
    path: struct { path: weft.Path, from: f64 },
    /// A node whose value is the goal.
    node: weft.Id,
};

pub const Row = struct {
    name: []const u8,
    /// An index into `widgets.accents`, cycled.
    accent: u8,
    id: weft.Id,
    goal: Goal,
};

/// The rows' names, in the text.
const row_names = [row_count][]const u8{
    "wave", "noise", "tween", "spring", "newtonian", "chase",  "follow",  "shift",
    "sway", "pulse", "drift", "soft",   "snappy",    "bouncy", "glide_a", "glide_b",
};

pub const Signals = struct {
    compiled: Compiled,
    cues: *const weft.Cues,
    goals: *const weft.Goals,
    tracks: *weft.Tracks,
    knobs: [knob_count]weft.TrackId,
    rows: [row_count]Row,
    program: weft.Program,

    /// Compiles `signals.weft` in place and finds the rows and the knobs by name.
    pub fn build(signals: *Signals) void {
        signals.compiled.compile(source) catch unreachable;
        const compiled = &signals.compiled;
        signals.cues = &compiled.tables.cues;
        signals.goals = &compiled.tables.goals;
        signals.tracks = &compiled.tables.tracks;
        for (&signals.knobs, knob_names) |*knob, name| knob.* = compiled.track(name).?;
        for (&signals.rows, row_names, 0..) |*row, name, index| {
            row.* = .{
                .name = name,
                .accent = @intCast(index % 4),
                .id = compiled.signal(name).?,
                .goal = switch (compiled.goal(name)) {
                    .none => .none,
                    .path => |path| .{ .path = .{ .path = path.path, .from = path.from } },
                    .node => |id| .{ .node = id },
                },
            };
        }
        signals.program = compiled.program;
        assert(signals.cues.count == cue_count);
        assert(signals.program.nodes.len <= node_count_max);
        assert(signals.program.slab_count <= slab_count_max);
    }
};

/// The bouncers page's lanes: step 7's worked bounce, then six that hit 2 to 7 times a bar.
pub const lane_count = 7;
/// Bars every 2 s, from 0 to the timeline's end: 301 cues.
pub const bar_ms: i64 = 2000;
pub const bar_count: u32 = @intCast(@divExact(timeline_ms, bar_ms) + 1);
/// The bouncer program: two nodes a lane, then the bars, one f64 each.
pub const bouncer_node_count = 2 * lane_count + 1;

pub const bouncer_source = @embedFile("bouncers.weft");

const BouncerCompiled = weft.lang.Compiled(.{
    .tokens = 512,
    .tree = 256,
    .names = 16,
    .nodes = bouncer_node_count,
    .slab = bouncer_node_count,
    .cues = bar_count,
    .goals = 0,
    .regions = 0,
    .tracks = 0,
    .track_samples = 0,
    .errors = 4,
});

pub const Lane = struct {
    name: []const u8,
    /// How it reads beside the lane: its hits a bar.
    note: []const u8,
    accent: u8,
    speed: f64,
    /// The position node, which fires the hits.
    id: weft.Id,
};

const lane_names = [lane_count][]const u8{ "0.7", "1", "1.5", "2", "2.5", "3", "3.5" };
const lane_bindings = [lane_count][]const u8{
    "lane_0_7", "lane_1", "lane_1_5", "lane_2", "lane_2_5", "lane_3", "lane_3_5",
};
const lane_notes = [lane_count][]const u8{
    "1.4 a bar", "2 a bar", "3 a bar", "4 a bar", "5 a bar", "6 a bar", "7 a bar",
};

/// The bouncers page's program (section 4): seven bounces between 0 and 1 from the first bar, and
/// a `cues` node over every bar, so the bars are events too. It is pure, so a window of its
/// events costs no steps, which is why it is a program of its own and not rows of `Signals`: an
/// events query runs every simulated node's steps across its range, whatever the caller wants.
pub const Bouncers = struct {
    compiled: BouncerCompiled,
    lanes: [lane_count]Lane,
    bars: weft.Id,
    program: weft.Program,

    /// Compiles `bouncers.weft` in place and finds the lanes and the bars by name.
    pub fn build(bouncers: *Bouncers) void {
        bouncers.compiled.compile(bouncer_source) catch unreachable;
        const compiled = &bouncers.compiled;
        const rows = .{ &bouncers.lanes, lane_names, lane_bindings, lane_notes };
        for (rows[0], rows[1], rows[2], rows[3], 0..) |*lane, name, binding, note, index| {
            const id = compiled.signal(binding).?;
            lane.* = .{
                .name = name,
                .note = note,
                .accent = @intCast(index % 4),
                .speed = compiled.program.nodes[id.index].op.bounce.speed,
                .id = id,
            };
        }
        bouncers.bars = compiled.signal("bars").?;
        bouncers.program = compiled.program;
        assert(compiled.tables.cues.count == bar_count);
        assert(bouncers.program.nodes.len == bouncer_node_count);
        assert(bouncers.program.slab_count == bouncer_node_count);
        assert(!bouncers.program.simulated);
    }
};

/// A time `count` milliseconds after zero: 705,600 flicks each, exactly.
pub fn ms(count: i64) weft.Time {
    return .{ .flicks = count * @divExact(weft.time.flicks_per_second, 1000) };
}

const testing = std.testing;
const reference = @import("signals_reference.zig");

var compared: Signals = undefined;
var hand_built: reference.Signals = undefined;
var compared_bouncers: Bouncers = undefined;
var hand_built_bouncers: reference.Bouncers = undefined;

// TEMPORARY: the text compiles to the hand-built tables, field for field.
test "the text compiles to the hand-built program" {
    compared.build();
    hand_built.build();
    try testing.expectEqual(hand_built.program.nodes.len, compared.program.nodes.len);
    for (hand_built.program.nodes, compared.program.nodes, 0..) |a, b, index| {
        if (!std.meta.eql(a, b)) {
            std.debug.print("node {d}\n{any}\n{any}\n", .{ index, a, b });
            return error.TestUnexpectedResult;
        }
    }
    try testing.expectEqual(hand_built.program.slab_count, compared.program.slab_count);
    try testing.expectEqual(hand_built.program.simulated, compared.program.simulated);
    try testing.expectEqual(hand_built.program.start, compared.program.start);
    try testing.expectEqualSlices(weft.Time, hand_built.cues.table(), compared.cues.table());
    try testing.expectEqualSlices(weft.Goal, hand_built.goals.table(), compared.goals.table());
    try testing.expectEqualSlices(weft.Region, hand_built.regions.table(), compared.program.regions);
    for (hand_built.rows, compared.rows) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqual(a.accent, b.accent);
        try testing.expectEqual(a.id, b.id);
        try testing.expectEqualStrings(@tagName(a.goal), @tagName(b.goal));
        switch (a.goal) {
            .none => {},
            .path => |path| {
                try testing.expectEqual(path.path, b.goal.path.path);
                try testing.expectEqual(path.from, b.goal.path.from);
            },
            .node => |id| try testing.expectEqual(id, b.goal.node),
        }
    }
    try testing.expectEqualSlices(weft.TrackId, &hand_built.knobs, &compared.knobs);
    for (0..knob_count) |index| {
        const a = hand_built.tracks.entries[index];
        const b = compared.tracks.entries[index];
        try testing.expectEqual(a.low, b.low);
        try testing.expectEqual(a.high, b.high);
        try testing.expectEqual(a.initial, b.initial);
        try testing.expectEqual(a.samples.len, b.samples.len);
    }
    compared_bouncers.build();
    hand_built_bouncers.build();
    const bouncer_pairs = .{ hand_built_bouncers.program.nodes, compared_bouncers.program.nodes };
    for (bouncer_pairs[0], bouncer_pairs[1]) |a, b| try testing.expect(std.meta.eql(a, b));
    try testing.expectEqual(hand_built_bouncers.bars, compared_bouncers.bars);
    const bar_times = compared_bouncers.compiled.tables.cues.table();
    try testing.expectEqualSlices(weft.Time, hand_built_bouncers.cues.table(), bar_times);
    for (hand_built_bouncers.lanes, compared_bouncers.lanes) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqualStrings(a.note, b.note);
        try testing.expectEqual(a.accent, b.accent);
        try testing.expectEqual(a.speed, b.speed);
        try testing.expectEqual(a.id, b.id);
    }
}
