//! Tests of the graph: a step reads only what a simulated node reads (step 34).
//!
//! A page of simulated nodes beside pure ones that none of them reads is read twice: over the
//! program `Builder.finish` marks, and over a copy of its nodes with every `step_skip` 0, which
//! steps every node, as every step did before step 34. The two must agree bit for bit: every
//! node's values and every simulated node's state after each read, on steps, between them, after
//! seeks back and far ahead, through a cue move, a track write, and an input set; the recording of
//! the input; and every event of `events`, `events_since`, and `events_of` over consecutive ranges.

const std = @import("std");
const assert = std.debug.assert;
const Cue = @import("../cue.zig").Cue;
const Cues = @import("../cue.zig").Cues;
const motion = @import("../motion.zig");
const recording_module = @import("../recording.zig");
const Recording = recording_module.Recording;
const Sample = recording_module.Sample;
const simulation = @import("../simulation.zig");
const time_module = @import("../time.zig");
const Time = time_module.Time;
const Rate = time_module.Rate;
const track_module = @import("../track.zig");
const Tracks = track_module.Tracks;
const TrackId = track_module.TrackId;
const graph_module = @import("../graph.zig");
const testing = std.testing;
const flicks_per_second = time_module.flicks_per_second;
const Builder = graph_module.Builder;
const Event = graph_module.Event;
const Events = graph_module.Events;
const Id = graph_module.Id;
const Node = graph_module.Node;
const Program = graph_module.Program;
const State = graph_module.State;
const step_flicks: i64 = @intCast(graph_module.step_flicks);

const nodes_max = 48;
const slab_max = 512;
/// Room for the checkpoints of a read at 48 s, past the far seek of the script.
const checkpoints_max = 48;
const lanes = 16;
const ms: i64 = @divExact(flicks_per_second, 1000);

/// The page: tables, the marked program and its unmarked copy, and the nodes the tests name.
const Page = struct {
    cue_times: [4]Time,
    cues: Cues,
    goal_entries: [3]motion.Goal,
    goals: motion.Goals,
    region_entries: [2]simulation.Region,
    regions: simulation.Regions,
    track_entries: [3]track_module.Track,
    track_samples: [3][64]Sample,
    tracks: Tracks,
    ids: [3]TrackId,
    nodes: [nodes_max]Node,
    full_nodes: [nodes_max]Node,
    marked: Program,
    full: Program,
    read: [16]Id,
    unread: [12]Id,
    input: Id,
    crossing: Id,
    follow: Id,

    /// A start cue half a step after 0.25 s, so a 60 Hz reader lands between steps, and cues at
    /// 1, 2, and 3 s. Read at a step: a delay, built first, of a sum built after it, so read only
    /// through the delay's back edge; a chase of a wave plus noise whose time is a track; a
    /// crossing of a tween; an oscillator whose rate is a map of the wave; a follower whose
    /// overshoot is a track; a shift register. Read by none of them: a track, an input and a
    /// product of it, cues, a product of the chase and the wave, and a region of 16 lanes with a
    /// staggered spring toward goals, a noise, a staggered tween, a map, a product, and a
    /// staggered bounce.
    fn init(page: *Page) !void {
        page.cues = Cues.init(&page.cue_times);
        const start = try page.cues.add(.{ .flicks = flicks_per_second / 4 + step_flicks / 2 });
        var at: [3]Cue = undefined;
        for (&at, 1..) |*cue, second| cue.* = try page.cues.add(.{ .flicks = @as(i64, @intCast(second)) * flicks_per_second });
        page.goals = motion.Goals.init(&page.goal_entries);
        const path = try page.goals.add(&.{
            .{ .cue = at[0], .value = 1 },
            .{ .cue = at[1], .value = -0.5 },
            .{ .cue = at[2], .value = 0.25 },
        });
        page.regions = simulation.Regions.init(&page.region_entries);
        const span = try page.regions.add(&.{ .{ .low = -1, .high = -0.5 }, .{ .low = 0.5, .high = 1 } });
        page.tracks = Tracks.init(&page.track_entries);
        const bounds = [3][3]f64{ .{ 0.1, 2, 0.5 }, .{ 0, 0.9, 0.3 }, .{ 0, 10, 1 } };
        for (&page.ids, &page.track_samples, bounds) |*id, *samples, bound| {
            id.* = try page.tracks.add(samples, bound[0], bound[1], bound[2]);
        }
        var builder = Builder.init(&page.nodes, .{
            .slab_count_max = slab_max,
            .cues = &page.cues,
            .goals = page.goals.table(),
            .regions = page.regions.table(),
            .tracks = &page.tracks,
            .start = start,
            .seed = 34,
        });
        const echo = try builder.delay(0);
        const wave = try builder.wave(.{ .shape = .sine, .hz = 0.7 });
        const noise = try builder.noise(.{ .shape = .smooth, .hz = 1.3, .seed = 5 });
        const target = try builder.add(wave, noise);
        const chase_time = try builder.track(page.ids[0]);
        const chase = try builder.chase(.{
            .target = target,
            .from = 0,
            .time = .{ .flicks = flicks_per_second / 2 },
            .overshoot = 0.1,
            .time_from = chase_time,
        });
        const gain = try builder.constant(-0.8);
        const scaled = try builder.multiply(chase, gain);
        const echo_input = try builder.add(scaled, wave);
        try builder.close(echo, echo_input);
        var rise_tween: graph_module.Tween = .{
            .from = 0,
            .to = 1,
            .duration = .{ .flicks = flicks_per_second },
            .ease = .in_out,
            .start = at[0],
            .previous = null,
        };
        const rise = try builder.tween(rise_tween);
        page.crossing = try builder.crossing(.{ .input = rise, .level = 0.5, .direction = .both });
        const rate = try builder.map_range(.{ .input = wave, .input_low = -1, .input_high = 1, .output_low = 0.5, .output_high = 2 });
        const oscillator = try builder.oscillator(.{ .shape = .triangle, .rate = rate });
        const overshoot = try builder.track(page.ids[1]);
        page.follow = try builder.follow(.{
            .from = 0,
            .regions = span,
            .pick = .random,
            .mover = .{ .spring = .{ .time = .{ .flicks = flicks_per_second / 4 }, .overshoot = 0 } },
            .tolerance = 0.01,
            .pause_min = .{ .flicks = flicks_per_second / 10 },
            .pause_max = .{ .flicks = flicks_per_second * 3 / 10 },
            .seed = 3,
            .mover_from = .{ .overshoot = overshoot },
        });
        const shift = try builder.shift(.{
            .buckets = 8,
            .period = .{ .flicks = 2 * flicks_per_second },
            .low = -1,
            .high = 1,
            .odds = 0.5,
            .shape = .smooth,
            .seed = 4,
        });
        page.read = .{
            echo,       wave, noise,         target, chase_time, chase,     gain,        scaled,
            echo_input, rise, page.crossing, rate,   oscillator, overshoot, page.follow, shift,
        };
        const unread_track = try builder.track(page.ids[2]);
        page.input = try builder.input(.{ .low = -1, .high = 1, .initial = 0.25 });
        const heard = try builder.multiply(page.input, unread_track);
        const cues = try builder.cues(.{ .first = at[0], .count = 3 });
        const view = try builder.multiply(chase, wave);
        builder.lanes = lanes;
        const spring = try builder.spring(.{
            .from = 0,
            .goals = path,
            .time = .{ .flicks = 400 * ms },
            .overshoot = 0.2,
            .stagger = .{ .flicks = 30 * ms },
        });
        const lane_noise = try builder.noise(.{ .shape = .smooth, .hz = 0.25, .seed = 3 });
        rise_tween.stagger = .{ .flicks = 20 * ms };
        const lane_rise = try builder.tween(rise_tween);
        const height = try builder.map_range(.{ .input = lane_noise, .input_low = -1, .input_high = 1, .output_low = 0.2, .output_high = 1 });
        const bars = try builder.multiply(lane_rise, height);
        const ball = try builder.bounce(.{
            .low = 0,
            .high = 1,
            .speed = 1.5,
            .start = at[0],
            .stagger = .{ .flicks = 10 * ms },
        });
        builder.lanes = null;
        page.unread = .{
            unread_track, page.input, heard,  cues, view,          spring,
            lane_noise,   lane_rise,  height, bars, ball.position, ball.velocity,
        };
        page.marked = builder.finish();
        assert(page.marked.slab_count <= slab_max);
        @memcpy(page.full_nodes[0..page.marked.nodes.len], page.marked.nodes);
        for (page.full_nodes[0..page.marked.nodes.len]) |*node| node.step_skip = 0;
        page.full = page.marked;
        page.full.nodes = page.full_nodes[0..page.marked.nodes.len];
        page.full.assert_valid();
    }
};

/// Two readers of one page: over the marked program and over its unmarked copy.
const Pair = struct {
    marked: State,
    full: State,

    fn init(page: *const Page, kept: bool) Pair {
        const size = if (kept) page.marked.reader_slab_count() else page.marked.slab_count;
        const room = if (kept) checkpoints_max * page.marked.slab_count else 0;
        return .{
            .marked = State.init_with_checkpoints(page.marked, slabs[0][0..size], checkpoints[0][0..room]),
            .full = State.init_with_checkpoints(page.full, slabs[1][0..size], checkpoints[1][0..room]),
        };
    }

    fn eval(pair: *Pair, time: Time) void {
        pair.marked.eval(time);
        pair.full.eval(time);
    }

    fn set_input(pair: *Pair, id: Id, to: f64) void {
        pair.marked.set_input(id, to);
        pair.full.set_input(id, to);
    }

    /// Every node's values, every simulated node's state, and the step agree bit for bit.
    fn expect_same(pair: *const Pair) !void {
        const nodes = pair.marked.program.nodes;
        try testing.expectEqual(pair.full.step, pair.marked.step);
        try testing.expectEqual(pair.full.finite(), pair.marked.finite());
        for (nodes, 0..) |*node, index| {
            const id: Id = .{ .index = @intCast(index) };
            try expect_bits(pair.full.values(id), pair.marked.values(id));
            if (!node.op.simulated()) continue;
            const count = node.extent.count() + node.op.cache_count(node.extent.count());
            const region = pair.marked.slab[node.offset..][0..@intCast(count)];
            try expect_bits(pair.full.slab[node.offset..][0..@intCast(count)], region);
        }
    }
};

fn expect_bits(expected: []const f64, actual: []const f64) !void {
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected), std.mem.sliceAsBytes(actual));
}

fn expect_same_events(expected: Events, expected_out: []const Event, actual: Events, actual_out: []const Event) !void {
    try testing.expectEqual(expected, actual);
    for (expected_out[0..expected.count], actual_out[0..actual.count]) |a, b| {
        try testing.expectEqual(a.time.flicks, b.time.flicks);
        try testing.expectEqual(a.source, b.source);
        try testing.expectEqual(a.instance, b.instance);
        try testing.expectEqual(@as(u64, @bitCast(a.value)), @as(u64, @bitCast(b.value)));
    }
}

fn seconds(count: f64) Time {
    return .{ .flicks = @intFromFloat(count * @as(f64, @floatFromInt(flicks_per_second))) };
}

/// Static, since a page, two slabs, and their checkpoints are too large for a test's stack.
var page_memory: Page = undefined;
var slabs: [2][2 * slab_max]f64 = undefined;
var checkpoints: [2][checkpoints_max * slab_max]f64 = undefined;
var recording_entries: [2][1024]Sample = undefined;
var events_out: [2][256]Event = undefined;

// Locks the marks of the page: the 16 nodes a step reads, the delay's sum after it and the
// constant read only through it among them, have `step_skip` 0, and the 12 none of them reads
// have more; the copy steps every node. A program with no simulated node keeps every mark 0.
test "a step reads the simulated nodes and what they read, and nothing else" {
    const page = &page_memory;
    try page.init();
    for (page.read) |id| try testing.expectEqual(@as(u32, 0), page.marked.nodes[id.index].step_skip);
    for (page.unread) |id| try testing.expect(page.marked.nodes[id.index].step_skip > 0);
    for (page.full.nodes) |node| try testing.expectEqual(@as(u32, 0), node.step_skip);
    // The read nodes come first, so the rest is one run, counted down to the end.
    const first_unread = page.unread[0].index;
    const total: u32 = @intCast(page.marked.nodes.len);
    try testing.expectEqual(total - first_unread, page.marked.nodes[first_unread].step_skip);

    var pure_nodes: [4]Node = undefined;
    var builder = Builder.init(&pure_nodes, .{ .slab_count_max = 4 });
    const wave = try builder.wave(.{ .shape = .sine, .hz = 1 });
    _ = try builder.add(wave, wave);
    const pure = builder.finish();
    for (pure.nodes) |node| try testing.expectEqual(@as(u32, 0), node.step_skip);
}

// Locks step 34's promise for values: with no checkpoints, and with checkpoints and the copy of
// the step before, a reader of the marked page and one of its copy agree bit for bit after every
// read of a script: 4 s at 60 Hz from 0, with an input set at frame 100 and two tracks written
// at the playhead at frame 150; reads a third of a step past steps and on steps; seeks back to
// 1.3 s, ahead to 40 s, back to 0.6 s, and before the start; a cue moved 0.1 s later, then reads
// at 2.5 s and 30 s. The input's recordings agree too.
test "a step that skips what no simulated node reads moves no value" {
    const page = &page_memory;
    const rate = Rate.from_hz(60).?;
    for ([_]bool{ false, true }) |kept| {
        try page.init();
        var pair = Pair.init(page, kept);
        var recordings = [2]Recording{ Recording.init(&recording_entries[0]), Recording.init(&recording_entries[1]) };
        pair.marked.record(page.input, &recordings[0]);
        pair.full.record(page.input, &recordings[1]);
        for (0..240) |frame| {
            if (frame == 100) pair.set_input(page.input, -0.75);
            const time = Time.from_ticks(@intCast(frame), rate).?;
            if (frame == 150) {
                try page.tracks.write(page.ids[0], time, 0.25);
                try page.tracks.write(page.ids[2], time, 3);
            }
            pair.eval(time);
            try pair.expect_same();
        }
        const start = page.cues.at(.{ .index = 0 }).flicks;
        for ([_]i64{ 3, 480, 481, 1000, 1001 }) |step| {
            for ([_]i64{ 0, step_flicks / 3 }) |into| {
                pair.eval(.{ .flicks = start + step * step_flicks + into });
                try pair.expect_same();
            }
        }
        for ([_]f64{ 1.3, 40, 0.6, -1 }) |at| {
            pair.eval(seconds(at));
            try pair.expect_same();
        }
        try page.cues.move(.{ .index = 1 }, seconds(1.1));
        for ([_]f64{ 2.5, 30 }) |at| {
            pair.eval(seconds(at));
            try pair.expect_same();
        }
        try testing.expectEqual(recordings[1].dropped, recordings[0].dropped);
        try testing.expect(recordings[0].count > 1);
        for (recordings[1].table(), recordings[0].table()) |a, b| {
            try testing.expectEqual(a.time.flicks, b.time.flicks);
            try testing.expectEqual(@as(u64, @bitCast(a.value)), @as(u64, @bitCast(b.value)));
        }
    }
}

// Locks step 34's promise for events: `events` over consecutive ranges from -0.5 s to 12 s, of
// lengths cycling through a 60th of a second, one step, 7 flicks, 0.37 s, and a second, gives the
// same events, bit for bit, from both readers, with and without checkpoints, more than 100 of
// them, from each of the bounce, the cues, the spring, the crossing, the follower, and the shift
// register; so do `events_since` at 60 Hz for 6 s, each followed by the same values; a range
// read again after a seek back; and `events_of` the crossing and the follower.
test "a step that skips what no simulated node reads moves no event" {
    const page = &page_memory;
    const lengths = [_]i64{ @divExact(flicks_per_second, 60), step_flicks, 7, 370 * ms, flicks_per_second };
    for ([_]bool{ false, true }) |kept| {
        try page.init();
        var pair = Pair.init(page, kept);
        var t0: i64 = -flicks_per_second / 2;
        var ranges: usize = 0;
        var found: u64 = 0;
        var fired: [nodes_max]bool = @splat(false);
        while (t0 < 12 * flicks_per_second) : (ranges += 1) {
            const t1 = t0 + lengths[ranges % lengths.len];
            const a = pair.full.events(.{ .flicks = t0 }, .{ .flicks = t1 }, &events_out[0]);
            const b = pair.marked.events(.{ .flicks = t0 }, .{ .flicks = t1 }, &events_out[1]);
            try expect_same_events(a, &events_out[0], b, &events_out[1]);
            for (events_out[0][0..a.count]) |event| fired[event.source.index] = true;
            found += a.count;
            t0 = t1;
        }
        // Every source of the page fires: a bounce, cues, a spring, a crossing, a follower, and a
        // shift register.
        try testing.expect(found > 100);
        for ([_]Id{ page.unread[3], page.unread[5], page.unread[10], page.crossing, page.follow, page.read[15] }) |id| {
            try testing.expect(fired[id.index]);
        }

        pair = Pair.init(page, kept);
        const rate = Rate.from_hz(60).?;
        for (0..360) |frame| {
            const now = Time.from_ticks(@intCast(frame), rate).?;
            const a = pair.full.events_since(now, &events_out[0]);
            const b = pair.marked.events_since(now, &events_out[1]);
            try expect_same_events(a, &events_out[0], b, &events_out[1]);
            try pair.expect_same();
        }
        const a = pair.full.events(seconds(1), seconds(3), &events_out[0]);
        const b = pair.marked.events(seconds(1), seconds(3), &events_out[1]);
        try expect_same_events(a, &events_out[0], b, &events_out[1]);
        const listed = [_]Id{ page.crossing, page.follow };
        const c = pair.full.events_of(&listed, seconds(0.5), seconds(5), &events_out[0]);
        const d = pair.marked.events_of(&listed, seconds(0.5), seconds(5), &events_out[1]);
        try expect_same_events(c, &events_out[0], d, &events_out[1]);
        try testing.expect(c.count > 0);
        pair.eval(seconds(5));
        try pair.expect_same();
    }
}
