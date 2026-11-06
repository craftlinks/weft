//! The signals Play shows: one Zig table of eight rows, built into one Weft program.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What Is Here
//! The cue, goal, and region tables, the node array, and the rows that name the nodes to show.
//! `Signals.build` fills them all, once, through the glue. The knobs never rebuild the program:
//! each is a track (Weft's step 9.5) that a node reads, and the app writes it at t, so a knob
//! applies from now on. This file describes the signals; it is not glue, so it is not counted in
//! the glue's budget (`glue.zig`).
//!
//! ```text
//! cues   0  2  4  6  8  10 s        timeline 600 s, graph seed 7, simulated nodes start at 0 s
//! row        signal                                                     class
//! wave       sine, 0.5 Hz                                               pure
//! noise      smooth, 1 Hz, seed 1                                       pure
//! tween      0 to 1 at 2 s over 1 s, then to -0.5 at 6 s, following it  pure
//! spring     from 0; 1 at 2 s, -0.5 at 6 s, 0.25 at 8 s; 0.5 s, 0.2     exact
//! newtonian  the same goals; speed 2, accel 8, decel 4                  exact
//! chase      the noise; time from chase s, overshoot 0.1                simulated
//! follow     [-1, -0.5] and [0.5, 1], random, spring 0.25 s, seed 2     simulated
//! shift      8 buckets, 2 s, [-1, 1], odds 0.25, smooth, seed 3         simulated
//! sway       [-1, 1], random, spring 0.8 s, overshoot from sway os, 4   simulated
//! pulse      an oscillator, sine, its rate from pulse hz                simulated
//! drift      smooth, 0.25 Hz, seed 5                                    pure
//! soft       [0, 1], spring 1 s, overshoot 0, seed 6                    simulated
//! snappy     [0, 1], spring 0.3 s, overshoot 0.1, seed 7                simulated
//! bouncy     [0, 1], spring 0.6 s, overshoot 0.5, seed 8                simulated
//! glide_a    [0, 1], Newtonian, speed from glide v, accel and decel 16, 9  simulated
//! glide_b    the same, seed 10                                          simulated
//! ```
//! The first `scope_row_count` rows are the scope's; every row is a source for the shapes page.
//!
//! ## 2. Goals
//! A row says where its goal comes from, so the glue never reads a node's op: a path in the goal
//! table with the value before its first goal, a node whose value is the goal (a chase's target),
//! or none. A follower and a shift register keep their goals in the slab, which the glue must not
//! read, so they have none (the step's missing list, for step 18).
//!
//! ## 3. Memory
//! `Program` holds pointers into `Signals`, so a `Signals` is built in place and never moves. Play
//! keeps it inside `App`, which the host and the tests keep in static memory. A builder error here
//! is a mistake in this table, not a run-time condition, so it is unreachable.
//!
//! ## 4. TigerStyle Invariants
//! - Every capacity is a constant here, and the build asserts the program fits them.

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
pub const graph_seed: u64 = 7;

pub const timeline_ms: i64 = 600_000;

pub const knob_count = 4;
/// The tracks the knobs write: each one's bounds, then its value before any write, which is the
/// knob's default. In order: pulse hz, chase s, sway os, glide v.
pub const knob_tracks = [knob_count][3]f64{
    .{ 0.075, 1.2, 0.3 },
    .{ 0.125, 2, 0.5 },
    .{ 0, 0.9, 0.45 },
    .{ 0.25, 4, 1 },
};
/// Writes each track holds: about two minutes of a knob turned every frame at 60 Hz. A full track
/// refuses a write, which changes nothing.
pub const track_samples_max = 8192;

/// A Newtonian glide's accel and decel: four times its largest speed, and constant, so its range
/// is its regions widened by at most `speed_max^2 / (2 decel)`, 0.5.
const glide_limit: f64 = 16;

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

pub const Signals = struct {
    nodes: [node_count_max]weft.Node,
    cue_times: [cue_count]weft.Time,
    cues: weft.Cues,
    goal_entries: [3]weft.Goal,
    goals: weft.Goals,
    /// The one path in `goals`, which the spring and the Newtonian move share.
    path: weft.Path,
    region_entries: [4]weft.Region,
    regions: weft.Regions,
    track_entries: [knob_count]weft.Track,
    track_samples: [knob_count][track_samples_max]weft.Sample,
    tracks: weft.Tracks,
    knobs: [knob_count]weft.TrackId,
    rows: [row_count]Row,
    program: weft.Program,

    /// Fills the tables, the tracks, and the node array in place, and finishes the program.
    pub fn build(signals: *Signals) void {
        signals.build_tables() catch unreachable;
        signals.build_nodes() catch unreachable;
        assert(signals.program.nodes.len <= node_count_max);
        assert(signals.program.slab_count <= slab_count_max);
    }

    fn build_tables(signals: *Signals) !void {
        signals.cues = weft.Cues.init(&signals.cue_times);
        for (0..cue_count) |index| _ = try signals.cues.add(ms(2000 * @as(i64, @intCast(index))));
        signals.goals = weft.Goals.init(&signals.goal_entries);
        signals.path = try signals.goals.add(&.{
            .{ .cue = cue(1), .value = 1 },
            .{ .cue = cue(3), .value = -0.5 },
            .{ .cue = cue(4), .value = 0.25 },
        });
        signals.regions = weft.Regions.init(&signals.region_entries);
        _ = try signals.regions.add(&.{
            .{ .low = -1, .high = -0.5 },
            .{ .low = 0.5, .high = 1 },
        });
        _ = try signals.regions.add(&.{.{ .low = -1, .high = 1 }});
        _ = try signals.regions.add(&.{.{ .low = 0, .high = 1 }});
        signals.tracks = weft.Tracks.init(&signals.track_entries);
        for (&signals.knobs, &signals.track_samples, knob_tracks) |*id, *samples, bound| {
            id.* = try signals.tracks.add(samples, bound[0], bound[1], bound[2]);
        }
    }

    fn build_nodes(signals: *Signals) weft.Builder.Error!void {
        var builder = weft.Builder.init(&signals.nodes, .{
            .slab_count_max = slab_count_max,
            .cues = &signals.cues,
            .goals = signals.goals.table(),
            .regions = signals.regions.table(),
            .tracks = &signals.tracks,
            .start = cue(0),
            .seed = graph_seed,
        });
        const path = signals.path;
        const wave = try builder.wave(.{ .shape = .sine, .hz = 0.5 });
        const noise = try builder.noise(.{ .shape = .smooth, .hz = 1, .seed = 1 });
        const rise = try builder.tween(.{
            .from = 0,
            .to = 1,
            .duration = ms(1000),
            .ease = .in_out,
            .start = cue(1),
            .previous = null,
        });
        const tween = try builder.tween(.{
            .from = 1,
            .to = -0.5,
            .duration = ms(1000),
            .ease = .in_out,
            .start = cue(3),
            .previous = rise,
        });
        const spring = try builder.spring(.{
            .from = 0,
            .goals = path,
            .time = ms(500),
            .overshoot = 0.2,
        });
        const newtonian = try builder.newtonian(.{
            .from = 0,
            .goals = path,
            .speed = 2,
            .accel = 8,
            .decel = 4,
        });
        const chase_time = try builder.track(signals.knobs[1]);
        const chase = try builder.chase(.{
            .target = noise,
            .from = 0,
            .time = ms(500),
            .overshoot = 0.1,
            .time_from = chase_time,
        });
        const follow = try builder.follow(.{
            .from = 0,
            .regions = .{ .first = 0, .count = 2 },
            .pick = .random,
            .mover = .{ .spring = .{ .time = ms(250), .overshoot = 0 } },
            .tolerance = 0.01,
            .pause_min = ms(100),
            .pause_max = ms(500),
            .seed = 2,
        });
        const shift = try builder.shift(.{
            .buckets = 8,
            .period = ms(2000),
            .low = -1,
            .high = 1,
            .odds = 0.25,
            .shape = .smooth,
            .seed = 3,
        });
        const sway_overshoot = try builder.track(signals.knobs[2]);
        const sway = try builder.follow(.{
            .from = 0,
            .regions = whole,
            .pick = .random,
            .mover = .{ .spring = .{ .time = ms(800), .overshoot = 0.45 } },
            .mover_from = .{ .overshoot = sway_overshoot },
            .tolerance = 0.01,
            .pause_min = ms(0),
            .pause_max = ms(1000),
            .seed = 4,
        });
        const pulse_rate = try builder.track(signals.knobs[0]);
        const pulse = try builder.oscillator(.{ .shape = .sine, .rate = pulse_rate });
        const drift = try builder.noise(.{ .shape = .smooth, .hz = 0.25, .seed = 5 });
        const soft = try builder.follow(unit_spring(ms(1000), 0, 6));
        const snappy = try builder.follow(unit_spring(ms(300), 0.1, 7));
        const bouncy = try builder.follow(unit_spring(ms(600), 0.5, 8));
        const glide_speed = try builder.track(signals.knobs[3]);
        const glide_a = try builder.follow(unit_glide(glide_speed, 9));
        const glide_b = try builder.follow(unit_glide(glide_speed, 10));
        const goals: Goal = .{ .path = .{ .path = path, .from = 0 } };
        signals.rows = .{
            .{ .name = "wave", .accent = 0, .id = wave, .goal = .none },
            .{ .name = "noise", .accent = 1, .id = noise, .goal = .none },
            .{ .name = "tween", .accent = 2, .id = tween, .goal = .none },
            .{ .name = "spring", .accent = 3, .id = spring, .goal = goals },
            .{ .name = "newtonian", .accent = 0, .id = newtonian, .goal = goals },
            .{ .name = "chase", .accent = 1, .id = chase, .goal = .{ .node = noise } },
            .{ .name = "follow", .accent = 2, .id = follow, .goal = .none },
            .{ .name = "shift", .accent = 3, .id = shift, .goal = .none },
            .{ .name = "sway", .accent = 0, .id = sway, .goal = .none },
            .{ .name = "pulse", .accent = 1, .id = pulse, .goal = .none },
            .{ .name = "drift", .accent = 2, .id = drift, .goal = .none },
            .{ .name = "soft", .accent = 3, .id = soft, .goal = .none },
            .{ .name = "snappy", .accent = 0, .id = snappy, .goal = .none },
            .{ .name = "bouncy", .accent = 1, .id = bouncy, .goal = .none },
            .{ .name = "glide_a", .accent = 2, .id = glide_a, .goal = .none },
            .{ .name = "glide_b", .accent = 3, .id = glide_b, .goal = .none },
        };
        signals.program = builder.finish();
    }
};

/// The region tables' runs: the scope follower's two, then [-1, 1], then [0, 1].
const whole: weft.Span = .{ .first = 2, .count = 1 };
const unit: weft.Span = .{ .first = 3, .count = 1 };

/// A follower over [0, 1] on a spring, pausing up to a second.
fn unit_spring(time: weft.Time, overshoot: f64, seed: u64) weft.Follow {
    return .{
        .from = 0.5,
        .regions = unit,
        .pick = .random,
        .mover = .{ .spring = .{ .time = time, .overshoot = overshoot } },
        .tolerance = 0.01,
        .pause_min = ms(0),
        .pause_max = ms(1000),
        .seed = seed,
    };
}

/// A follower over [0, 1] on a Newtonian move whose speed is the node `speed`, at `glide_limit`.
fn unit_glide(speed: weft.Id, seed: u64) weft.Follow {
    return .{
        .from = 0.5,
        .regions = unit,
        .pick = .random,
        .mover = .{ .newtonian = .{ .speed = 1, .accel = glide_limit, .decel = glide_limit } },
        .mover_from = .{ .speed = speed },
        .tolerance = 0.01,
        .pause_min = ms(0),
        .pause_max = ms(500),
        .seed = seed,
    };
}

/// A time `count` milliseconds after zero: 705,600 flicks each, exactly.
pub fn ms(count: i64) weft.Time {
    return .{ .flicks = count * @divExact(weft.time.flicks_per_second, 1000) };
}

fn cue(index: u32) weft.Cue {
    assert(index < cue_count);
    return .{ .index = index };
}
