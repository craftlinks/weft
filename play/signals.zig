//! The signals Play shows: one Zig table of eight rows, built into one Weft program.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What Is Here
//! The cue, goal, and region tables, the node array, and the rows that name the nodes to show.
//! `Signals.build` fills them all, once, from `App.init` through the glue. This file describes
//! the signals; it is not glue, so it is not counted in the glue's budget (`glue.zig`).
//!
//! ```text
//! cues   0  2  4  6  8  10 s        timeline 12 s, graph seed 7, simulated nodes start at 0 s
//! row        signal                                                     class
//! wave       sine, 0.5 Hz                                               pure
//! noise      smooth, 1 Hz, seed 1                                       pure
//! tween      0 to 1 at 2 s over 1 s, then to -0.5 at 6 s, following it  pure
//! spring     from 0; 1 at 2 s, -0.5 at 6 s, 0.25 at 8 s; 0.5 s, 0.2     exact
//! newtonian  the same goals; speed 2, accel 8, decel 4                  exact
//! chase      the noise; 0.5 s, overshoot 0.1                            simulated
//! follow     [-1, -0.5] and [0.5, 1], random, spring 0.25 s, seed 2     simulated
//! shift      8 buckets, 2 s, [-1, 1], odds 0.25, smooth, seed 3         simulated
//! ```
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

pub const row_count = 8;
pub const cue_count = 6;
pub const node_count_max = 16;
pub const slab_count_max = 256;
/// Seconds of checkpoints each reader has room for: more than the timeline and the scope's
/// window after it, so a scrub anywhere restores one.
pub const checkpoint_seconds = 16;
pub const graph_seed: u64 = 7;

pub const timeline_ms: i64 = 12_000;

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
    region_entries: [2]weft.Region,
    regions: weft.Regions,
    rows: [row_count]Row,
    program: weft.Program,

    /// Fills the tables and the node array in place, and finishes the program.
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
    }

    fn build_nodes(signals: *Signals) weft.Builder.Error!void {
        var builder = weft.Builder.init(&signals.nodes, .{
            .slab_count_max = slab_count_max,
            .cues = &signals.cues,
            .goals = signals.goals.table(),
            .regions = signals.regions.table(),
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
        const chase = try builder.chase(.{
            .target = noise,
            .from = 0,
            .time = ms(500),
            .overshoot = 0.1,
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
        };
        signals.program = builder.finish();
    }
};

/// A time `count` milliseconds after zero: 705,600 flicks each, exactly.
pub fn ms(count: i64) weft.Time {
    return .{ .flicks = count * @divExact(weft.time.flicks_per_second, 1000) };
}

fn cue(index: u32) weft.Cue {
    assert(index < cue_count);
    return .{ .index = index };
}
