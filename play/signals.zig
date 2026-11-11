//! The signals Play shows: four Weft files, `signals.weft`, `bouncers.weft`, `vectors.weft`, and
//! `lanes.weft`, compiled once, and the rows that name what to show.
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
//! ## 7. The Vectors
//! The vectors page (step 16) has a program of its own too, `Vectors`, from `vectors.weft`, which
//! is pure and closed form, so a read at any time costs one pass and no steps:
//! ```text
//! cues    c0 to c3, every 0.8 s from 0 s
//! dot     a vec2 spring through four goals from (0.5, 0.5); 0.7 s, overshoot 0.35  exact
//! sway    two smooth noises at 0.7 Hz, packed, times 0.08                         pure
//! place   dot + sway, the point the page draws                                    exact
//! sweep   a colour tween from orange to blue, over 6 s from c0                    pure
//! glow    a colour spring through four colours at the cues, from the first;
//!         0.5 s, overshoot 0.4                                                     exact
//! drift   OKLab at lightness 0.72, its a and b two noises at 0.2 Hz times 0.12     pure
//! ```
//! Each goal comes before the spring settles on the last, so the place arrives at a goal still
//! moving and curves. The dot's goals are read once from the checked file, since a vector motion has no goal source
//! (Weft's back end, section 6): the call bound to `dot`, its path, and one run a component. The
//! glow's overshoot leaves the sRGB gamut, which `weft.colour.to_srgb` maps back at the read.
//!
//! ## 8. The Lanes
//! The lanes page (step 17) has `Field`, from `lanes.weft`: a thousand dots, one a lane of one
//! program, pure and closed form:
//! ```text
//! rise    a tween from 0 to 1 over 0.8 s from c0, each lane 3 ms after the one before   pure
//! height  a smooth noise at 0.2 Hz a lane, mapped to 0.3..1                             pure
//! size    rise * height, a dot's size                                                    pure
//! tint    OKLab at lightness 0.74, its a and b two noises at 0.1 Hz a lane, times 0.13   pure
//! hop     a bounce between 0 and 1 at 0.6 a second, each lane 5 ms after the one before  pure
//! ```
//! A noise in a region draws each lane from its own seed, so no two dots share a height or a
//! colour, and the hop's hits at the top wall are the flashes, each event's instance its lane.
//!
//! ## 9. The Swarm
//! The swarm page (step 18's agent trial) has `Swarm`, from `swarm.weft`: forty-eight dots, one a lane
//! of one program, stepped (it has followers and chases) but with no live input, so seekable:
//! ```text
//! wander_x, wander_y  a follower a lane over -1..1 on a spring of 0.7 s, pausing up to 0.8 s   stepped
//! place               vec2(wander_x, wander_y), the dot                                         stepped
//! ghost               vec2 of two chases of the wanderers, 0.4 s behind                         stepped
//! tint                OKLab at lightness 0.74, a and b two noises a lane                        pure
//! gate                a crossing of wander_x at 0.25: 1 while the dot is at or past it                stepped
//! ```
//! Each lane draws its own seed, so no two dots wander alike, and the gate's events carry the lane
//! as their instance. The page reads values only: a frame costs the steps since the last one.
//!
//! ## 6. Editing
//! The text page edits `signals.weft` (step 15), so a `Signals` is built from any text, not only
//! the embedded file: `build` copies the text first, since the program's names and the errors'
//! places point into it, and returns false, with `errors` as plain `Problem`s, when it does not
//! compile. Rows and knobs are found by name, so one the text no longer declares is null and the
//! app shows it absent. The limits leave room for edits: 40 nodes, a slab of 160, and 16 cues.
//! `track_literals` finds each knob's `track` line with the parser alone, so the text page's
//! knobs stay bound while another line has an error the checker would refuse.
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
/// The cues `signals.weft` declares, and the most an edit may declare (step 15).
pub const cue_count = 6;
pub const cue_count_max = 16;
/// Room for edits: `signals.weft` builds 21 nodes and a slab of 112 f64. Four readers'
/// checkpoints for 604 s (two programs during a recompile, two readers each) are about 3.1 MB.
pub const node_count_max = 40;
pub const slab_count_max = 160;
/// The longest file the editor can compile (step 15).
pub const text_max = 16 << 10;
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

const limits: weft.lang.Limits = .{
    .tokens = 4096,
    .tree = 2048,
    .names = 64,
    .nodes = node_count_max,
    .slab = slab_count_max,
    .cues = cue_count_max,
    .goals = 3,
    .regions = 4,
    .tracks = knob_count,
    .track_samples = track_samples_max,
    .errors = 4,
};
const Compiled = weft.lang.Compiled(limits);

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
    /// Null when the text no longer declares the row (section 6).
    id: ?weft.Id,
    goal: Goal,
};

/// The rows' names, in the text.
const row_names = [row_count][]const u8{
    "wave", "noise", "tween", "spring", "newtonian", "chase",  "follow",  "shift",
    "sway", "pulse", "drift", "soft",   "snappy",    "bouncy", "glide_a", "glide_b",
};

pub const Signals = struct {
    compiled: Compiled,
    /// The text compiled, which the program's names and the errors' places point into, so it
    /// is a copy the editor's later edits do not move.
    text: [text_max]u8,
    text_len: u32,
    cues: *const weft.Cues,
    goals: *const weft.Goals,
    tracks: *weft.Tracks,
    /// Null for a knob whose track the text no longer declares (section 6).
    knobs: [knob_count]?weft.TrackId,
    rows: [row_count]Row,
    program: weft.Program,

    /// Compiles a copy of `text` in place and finds the rows and the knobs by name. False when
    /// the text does not compile, with `errors` saying why; nothing else is then set.
    pub fn build(signals: *Signals, text: []const u8) bool {
        if (text.len > text_max) return false;
        @memcpy(signals.text[0..text.len], text);
        signals.text_len = @intCast(text.len);
        const compiled = &signals.compiled;
        compiled.compile(signals.text[0..text.len]) catch return false;
        signals.cues = &compiled.tables.cues;
        signals.goals = &compiled.tables.goals;
        signals.tracks = &compiled.tables.tracks;
        for (&signals.knobs, knob_names) |*knob, name| knob.* = compiled.track(name);
        for (&signals.rows, row_names, 0..) |*row, name, index| {
            row.* = .{
                .name = name,
                .accent = @intCast(index % 4),
                .id = compiled.signal(name),
                .goal = switch (compiled.goal(name)) {
                    .none => .none,
                    .path => |path| .{ .path = .{ .path = path.path, .from = path.from } },
                    .node => |id| .{ .node = id },
                },
            };
        }
        signals.program = compiled.program;
        assert(signals.cues.count <= cue_count_max);
        assert(signals.program.nodes.len <= node_count_max);
        assert(signals.program.slab_count <= slab_count_max);
        return true;
    }

    /// The errors of the last `build` that failed, as plain text and byte places (section 6).
    pub fn errors(signals: *const Signals, out: []Problem) []const Problem {
        const found = signals.compiled.errors();
        const count = @min(found.len, out.len);
        const text = signals.text[0..signals.text_len];
        for (out[0..count], found[0..count]) |*problem, *diagnostic| {
            const place = weft.lang.diagnostic.locate(text, diagnostic.start);
            problem.* = .{
                .start = diagnostic.start,
                .end = @min(diagnostic.start + diagnostic.len, signals.text_len),
                .line = place.line,
                .column = place.column,
                .message = diagnostic.message_text(),
                .hint = diagnostic.hint_text(),
            };
        }
        return out[0..count];
    }

    /// Keeps `old`'s reader state in `state`, a reader of this program, when no simulated node
    /// changed (Weft's `Compiled.carry`); false otherwise.
    pub fn carry(signals: *const Signals, state: *weft.State, old: *const Signals, old_state: *const weft.State) bool {
        return signals.compiled.carry(state, &old.compiled, old_state);
    }

    /// Writes `old`'s track writes into this program's tracks of the same names.
    pub fn carry_tracks(signals: *Signals, old: *const Signals) void {
        signals.compiled.carry_tracks(&old.compiled);
    }
};

/// An error of the text, with nothing of Weft's in it (section 6).
pub const Problem = struct {
    start: u32,
    end: u32,
    line: u32,
    column: u32,
    message: []const u8,
    hint: []const u8,
};

/// The three number literals of a knob's track line, `track name = value in lo..hi`, as byte
/// ranges of the text (section 6).
pub const TrackLiterals = struct { value: [2]u32, lo: [2]u32, hi: [2]u32 };

var binding_syntax: weft.lang.Syntax(limits) = undefined;

/// Each knob's track line in `text`, found by its name, or null where the text does not parse,
/// the track is gone, or one of its three numbers is not a plain number literal. Runs the
/// parser only, so it finds them while the text has errors the checker would refuse.
pub fn track_literals(text: []const u8, out: *[knob_count]?TrackLiterals) void {
    out.* = @splat(null);
    if (text.len > text_max) return;
    _ = binding_syntax.parse_source(text);
    const tree = &binding_syntax.tree;
    if (!tree.complete) return;
    for (tree.declarations) |index| {
        const item = tree.item(index);
        if (item.tag != .track) continue;
        const name = tree.token_text(item.token);
        const knob = for (knob_names, 0..) |known, at| {
            if (std.mem.eql(u8, known, name)) break at;
        } else continue;
        const bounds = tree.item(item.b);
        if (bounds.tag != .range) continue;
        const value = number_literal(tree, item.a) orelse continue;
        const lo = number_literal(tree, bounds.a) orelse continue;
        const hi = number_literal(tree, bounds.b) orelse continue;
        out[knob] = .{ .value = value, .lo = lo, .hi = hi };
    }
}

/// The bytes of a plain number literal, its sign included, or null for anything else.
fn number_literal(tree: anytype, index: u32) ?[2]u32 {
    const item = tree.item(index);
    if (item.tag != .literal) return null;
    if (tree.tokens[item.token].tag != .number) return null;
    const first = tree.tokens[item.first];
    const last = tree.tokens[item.last];
    return .{ first.start, last.start + last.len };
}

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

/// The vectors page's program (section 7).
pub const vector_node_count = 25;
pub const vector_slab_count = 55;
pub const vector_goal_count = 4;
pub const vector_source = @embedFile("vectors.weft");

const VectorCompiled = weft.lang.Compiled(.{
    .tokens = 512,
    .tree = 256,
    .names = 16,
    .nodes = vector_node_count,
    .slab = vector_slab_count,
    .cues = 4,
    .goals = 8 + 12,
    .regions = 0,
    .tracks = 0,
    .track_samples = 0,
    .errors = 4,
});

/// The colours the page draws as strips over the window, by name, in order.
pub const colour_count = 3;
pub const colour_names = [colour_count][]const u8{ "sweep", "glow", "drift" };

pub const Vectors = struct {
    compiled: VectorCompiled,
    place: weft.Id,
    colours: [colour_count]weft.Id,
    /// The dot's goals: where, and the cue's time.
    goals: [vector_goal_count][2]f64,
    goal_times: [vector_goal_count]weft.Time,
    program: weft.Program,

    /// Compiles `vectors.weft` in place, finds its signals by name, and reads the dot's goals.
    pub fn build(vectors: *Vectors) void {
        const compiled = &vectors.compiled;
        compiled.compile(vector_source) catch unreachable;
        vectors.place = compiled.signal("place").?;
        for (&vectors.colours, colour_names) |*id, name| id.* = compiled.signal(name).?;
        const checked = &compiled.checked;
        const binding = for (checked.bindings) |entry| {
            if (std.mem.eql(u8, entry.name, "dot")) break entry;
        } else unreachable;
        const expr = checked.exprs[binding.index];
        assert(expr.tag == .call);
        const path = checked.call_values(expr.a)[0].path;
        assert(checked.paths[path].shape.components == 2);
        for (0..2) |k| {
            const run = checked.paths[path + k];
            assert(run.count == vector_goal_count);
            for (checked.goals[run.first..][0..run.count], 0..) |goal, at| {
                vectors.goals[at][k] = goal.value;
                vectors.goal_times[at] = compiled.tables.cues.at(.{ .index = goal.cue });
            }
        }
        vectors.program = compiled.program;
        assert(vectors.program.nodes.len == vector_node_count);
        assert(vectors.program.slab_count == vector_slab_count);
        assert(!vectors.program.simulated);
    }
};

/// The lanes page's program (section 8).
pub const field_count = 1000;
pub const field_node_count = 14;
pub const field_slab_count = 13 * field_count + 3;
pub const field_source = @embedFile("lanes.weft");

const FieldCompiled = weft.lang.Compiled(.{
    .tokens = 512,
    .tree = 256,
    .names = 16,
    .nodes = field_node_count,
    .slab = field_slab_count,
    .cues = 1,
    .goals = 0,
    .regions = 0,
    .tracks = 0,
    .track_samples = 0,
    .errors = 4,
});

pub const Field = struct {
    compiled: FieldCompiled,
    size: weft.Id,
    tint: weft.Id,
    hop: weft.Id,
    program: weft.Program,

    /// Compiles `lanes.weft` in place and finds its signals by name.
    pub fn build(field: *Field) void {
        const compiled = &field.compiled;
        compiled.compile(field_source) catch unreachable;
        field.size = compiled.signal("size").?;
        field.tint = compiled.signal("tint").?;
        field.hop = compiled.signal("hop").?;
        field.program = compiled.program;
        assert(field.program.nodes.len == field_node_count);
        assert(field.program.slab_count == field_slab_count);
        assert(!field.program.simulated);
        for ([_]weft.Id{ field.size, field.tint, field.hop }) |id| {
            assert(field.program.nodes[id.index].extent.lanes == field_count);
        }
    }
};

/// The swarm page's program (section 9).
pub const swarm_count = 48;
pub const swarm_node_count = 15;
pub const swarm_slab_count = 1876;
pub const swarm_source = @embedFile("swarm.weft");
/// Seconds of checkpoints the swarm's reader keeps: the timeline and a little more.
pub const swarm_checkpoint_seconds = 604;

const SwarmCompiled = weft.lang.Compiled(.{
    .tokens = 1024,
    .tree = 512,
    .names = 32,
    .nodes = swarm_node_count,
    .slab = swarm_slab_count,
    .cues = 1,
    .goals = 0,
    .regions = 1,
    .tracks = 0,
    .track_samples = 0,
    .errors = 4,
});

pub const Swarm = struct {
    compiled: SwarmCompiled,
    place: weft.Id,
    ghost: weft.Id,
    tint: weft.Id,
    gate: weft.Id,
    program: weft.Program,

    /// Compiles `swarm.weft` in place and finds its signals by name.
    pub fn build(swarm: *Swarm) void {
        const compiled = &swarm.compiled;
        compiled.compile(swarm_source) catch unreachable;
        swarm.place = compiled.signal("place").?;
        swarm.ghost = compiled.signal("ghost").?;
        swarm.tint = compiled.signal("tint").?;
        swarm.gate = compiled.signal("gate").?;
        swarm.program = compiled.program;
        assert(swarm.program.nodes.len == swarm_node_count);
        assert(swarm.program.slab_count == swarm_slab_count);
        assert(swarm.program.simulated);
        for ([_]weft.Id{ swarm.place, swarm.ghost, swarm.tint, swarm.gate }) |id| {
            assert(swarm.program.nodes[id.index].extent.lanes == swarm_count);
        }
    }
};

/// A time `count` milliseconds after zero: 705,600 flicks each, exactly.
pub fn ms(count: i64) weft.Time {
    return .{ .flicks = count * @divExact(weft.time.flicks_per_second, 1000) };
}

const testing = std.testing;

var built: Signals = undefined;
var built_bouncers: Bouncers = undefined;
var built_vectors: Vectors = undefined;
var built_field: Field = undefined;
var field_slab: [field_slab_count]f64 = undefined;
var built_swarm: Swarm = undefined;
var swarm_slab: [swarm_slab_count]f64 = undefined;
var swarm_checkpoints: [8 * swarm_slab_count]f64 = undefined;

// Locks section 8: a thousand lanes, each its own dot. Before c0 every dot is at size 0, lane
// 400 is still at 0 at 1.2 s while lane 0 has risen, no two lanes share a tint, and the first
// hits at the top wall are lane 0's then lane 1's, 5 ms apart.
test "the lanes program is a thousand dots of their own" {
    built_field.build();
    var reader = weft.State.init(built_field.program, &field_slab);
    reader.eval(ms(1200));
    const size = reader.values(built_field.size);
    try testing.expect(size[0] > 0.29);
    try testing.expectEqual(@as(f64, 0), size[400]);
    const tint = reader.values(built_field.tint);
    try testing.expectEqual(@as(usize, 3 * field_count), tint.len);
    try testing.expect(tint[1] != tint[4] and tint[2] != tint[5]);
    var events: [4]weft.Event = undefined;
    const found = reader.events(ms(0), ms(1675), &events);
    try testing.expectEqual(@as(u32, 2), found.count);
    try testing.expectEqual(@as(u32, 0), events[0].instance);
    try testing.expectEqual(@as(u32, 1), events[1].instance);
    try testing.expectEqual(ms(5).flicks, events[1].time.flicks - events[0].time.flicks);
}

// Locks section 9: forty-eight wanderers, each its own. At t = 0 every dot is at the origin; at 5 s
// no two share an x and the ghost, a chase of the dot, is not on it; the gate is 1 for the
// lanes whose x is at or past 0.25.
test "the swarm program is forty-eight wanderers of their own" {
    built_swarm.build();
    var reader = weft.State.init_with_checkpoints(built_swarm.program, &swarm_slab, &swarm_checkpoints);
    reader.eval(ms(0));
    for (reader.values(built_swarm.place)) |component| try testing.expectEqual(@as(f64, 0), component);
    reader.eval(ms(5000));
    const place = reader.values(built_swarm.place);
    const ghost = reader.values(built_swarm.ghost);
    try testing.expectEqual(@as(usize, 2 * swarm_count), place.len);
    try testing.expect(place[0] != place[2] and place[1] != place[3]);
    try testing.expect(place[0] != ghost[0]);
    // The gate is 1 exactly for the lanes at or past 0.25, and some lane is.
    var lit: u32 = 0;
    for (reader.values(built_swarm.gate), 0..) |gate, lane| {
        try testing.expectEqual(@as(f64, if (place[2 * lane] >= 0.25) 1 else 0), gate);
        lit += @intFromBool(gate == 1);
    }
    try testing.expect(lit > 0);
}

// Locks section 7: the dot's goals and their cues come from the checked file, and the colours
// are OKLab, the sweep starting at the orange its `srgb` names.
test "the vectors program finds its goals and colours" {
    built_vectors.build();
    try testing.expectEqual([2]f64{ 0.2, 0.75 }, built_vectors.goals[0]);
    try testing.expectEqual([2]f64{ 0.3, 0.3 }, built_vectors.goals[3]);
    try testing.expectEqual(ms(2400), built_vectors.goal_times[3]);
    var slab: [vector_slab_count]f64 = undefined;
    var reader = weft.State.init(built_vectors.program, &slab);
    reader.eval(ms(0));
    const sweep = reader.values(built_vectors.colours[0]);
    const orange = weft.colour.from_srgb(.{ 0.95, 0.35, 0.2 });
    try testing.expectEqualSlices(f64, &orange, sweep);
    // The dot starts at its `from`, and the sway moves it at most 0.08 a component.
    for (reader.values(built_vectors.place)) |component| try testing.expectApproxEqAbs(@as(f64, 0.5), component, 0.08);
}

/// A hash of a program and the tables it reads, from each node's and entry's printed fields, so
/// padding bytes never count (section 1's lock).
fn program_hash(program: weft.Program, tracks: *const weft.Tracks) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var buffer: [1024]u8 = undefined;
    for (program.nodes) |node| hasher.update(std.fmt.bufPrint(&buffer, "{any}", .{node}) catch unreachable);
    for (program.cues.table()) |time| hasher.update(std.mem.asBytes(&time.flicks));
    for (program.goals) |goal| hasher.update(std.fmt.bufPrint(&buffer, "{any}", .{goal}) catch unreachable);
    for (program.regions) |region| hasher.update(std.fmt.bufPrint(&buffer, "{any}", .{region}) catch unreachable);
    for (tracks.entries[0..tracks.count]) |track| {
        hasher.update(std.fmt.bufPrint(&buffer, "{d} {d} {d} {d}", .{ track.low, track.high, track.initial, track.samples.len }) catch unreachable);
    }
    hasher.update(std.fmt.bufPrint(&buffer, "{d} {} {d}", .{ program.slab_count, program.simulated, program.start.index }) catch unreachable);
    return hasher.final();
}

// Locks both programs as built from the text: the hashes are those of the hand-built tables the
// text replaced in step 12, checked field for field then, so a change to either file or to the
// compiler that moves a node shows here, before the goldens. Step 17's `stagger` fields moved
// them only by their printing: with those fields cut from each node's text, both were the step
// 12 hashes, 0xdea1386a4be8a783 and 0x69071b1bdb435f6a. Step 28's `cue_by_lane` field moved them
// the same way: with ", .cue_by_lane = false" cut, both were 0x8ebcd160a135c39d and
// 0x8def344e14662829 again. Step 34's `step_skip` field moved them the same way: with
// ", .step_skip = n" cut, both were 0x0fa761f8b9ab026a and 0x6ffd7f6225076541 again.
test "the text compiles to the programs it replaced" {
    try testing.expect(built.build(source));
    built_bouncers.build();
    try testing.expectEqual(@as(u64, 0xa9f41f282456a456), program_hash(built.program, built.tracks));
    const bouncer_tracks = &built_bouncers.compiled.tables.tracks;
    try testing.expectEqual(@as(u64, 0xb7df9067be7ef729), program_hash(built_bouncers.program, bouncer_tracks));
}

// Locks what the rows find by name: the spring's and the Newtonian move's shared path, the chase's
// target, and the knobs' bounds.
test "rows, goals, and knobs come from the text by name" {
    try testing.expect(built.build(source));
    try testing.expectEqual(built.rows[3].goal.path.path, built.rows[4].goal.path.path);
    try testing.expectEqual(@as(f64, 0), built.rows[3].goal.path.from);
    try testing.expectEqual(built.rows[1].id.?, built.rows[5].goal.node);
    try testing.expect(built.rows[0].goal == .none);
    const glide = built.tracks.at(built.knobs[3].?);
    try testing.expectEqual(@as(f64, 0.25), glide.low);
    try testing.expectEqual(@as(f64, 4), glide.high);
    try testing.expectEqual(@as(f64, 1), glide.initial);
}

var syntax: weft.lang.Syntax(.{ .tokens = 1024, .tree = 512, .names = 64 }) = undefined;
var formatted: [8192]u8 = undefined;

// Locks the round trip: both files are in the canonical format, so formatting gives their bytes.
test "both files are canonical" {
    for ([_][]const u8{ source, bouncer_source, vector_source, field_source, swarm_source }) |text| {
        try testing.expect(syntax.parse_source(text));
        try testing.expectEqualStrings(text, try syntax.format_into(&formatted));
    }
}
