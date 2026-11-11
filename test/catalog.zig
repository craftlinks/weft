//! The regress catalog: signals sampled on a fixed grid, written as text of hex floats.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. One Renderer, Two Targets
//! `render` is the same code on native (`tools/regress.zig`) and on wasm
//! (`tools/regress_wasm.zig`), and both of its outputs must equal `test/golden/signals.txt` byte
//! for byte. A hex float prints every bit of a value, so text equality is bit equality.
//!
//! ## 2. The Format
//! One sample per line: shape, frequency, epoch, sample index, hex float. So a golden diff is a
//! list of named samples, and `compare` can report the first sample that changed by its line.
//!
//! ## 3. The Grid
//! Each signal runs on a clock it would really meet, and at each epoch: at zero, an hour and a day
//! later, where a float of seconds would have lost bits, and an hour before zero. The stride makes
//! a run cover about a cycle at the slow frequencies and a few cycles at the fast ones.
//!
//! ## 4. Noise
//! Each noise shape runs on the same signals and epochs as the waves, after them in the text, with
//! one fixed seed. A noise is a hash of its seed, so these lines also lock the hash: a change to it
//! changes every one of them.
//!
//! ## 5. Graphs
//! Signals alone cannot notice a change in how a `Program` evaluates, so the catalog also samples
//! whole graphs through a `State`, on the same epochs. They come after the signals in the text, so
//! a change to either shows up on its own lines. Cues are set relative to the epoch, so a sequence
//! of tweens runs at each one, and a test locks that it has the same bits at all of them, as do a
//! spring and a Newtonian move, which head for goals at the same cues. One graph has noise, so a
//! change to how the builder derives a node's seed changes its lines.
//!
//! ## 6. Simulated Graphs
//! A chase, a follower, a shift register, and a feedback loop through a delay start at the first
//! cue, so they too have the same bits at every epoch. They come last, so the lines before them
//! are the lines of step 5. After the start their samples never land on a step, so each also
//! locks the interpolation between steps, and the follower and the shift register lock the draws.
//!
//! ## 7. Events
//! Values alone cannot notice a change in when things happen, so the catalog also lists events.
//! Each event graph runs on the same cues as the graphs, at each epoch, and reports the events of
//! its first six seconds into a buffer of `events_per_run_max`, one line per event kept: graph,
//! epoch, index, flicks after the epoch, source, and the value as a hex float. Every event graph
//! starts at the first cue, so its times after the epoch and its values are the same at every
//! epoch. They come last, so the lines before them are the lines of step 6. How many events each
//! keeps and drops is a constant `render` asserts, so the text keeps a compile-time size, and the
//! shift register overflows the buffer, which locks the overflow rule too.
//!
//! ## 8. Recordings
//! A recording played back is a pure signal, so one graph chases a `recorded` node over samples
//! set relative to the epoch, which makes it the same at every epoch too. Its runs come after the
//! events, so every line before them is a line of step 7, and they lock the playback rule: the
//! last sample at or before the time, held forward.
//!
//! ## 9. Live Parameters
//! Four graphs read tracks (step 9.5): an oscillator whose rate is a track, a chase whose time is
//! one, a spring follower whose overshoot is one, and a Newtonian follower whose limits are one and
//! four times it. Each track is written at fixed times after the epoch, so these too are the same
//! at every epoch, and they lock the latch, an oscillator's summed phase, and the laws a step takes
//! from its parameter nodes. They come after the recorded graph, so every line before them is a
//! line of step 8.
//!
//! ## 10. Runaway
//! A loop through a delay whose gain is above 1 runs away, and its state saturates near
//! `simulation.state_bound` (step 19), so these lines lock that it does so with the same bits on
//! native and wasm and in every build mode. Two graphs, a chase of 1 + gain times its own delay,
//! run at the zero epoch only, sampled every 10 s for 300 s: one with a gain of 1.5 throughout,
//! and one whose gain is a track turned back to 0.5 at 150 s, which comes back down to 2. They
//! come last, so every line before them is a line of step 9.
//!
//! ## 11. Functions of a Value
//! Four graphs read `abs`, `min`, and `max` (step 26) at every epoch, as the graphs of step 5 do:
//! the drift's distance from 0, the lower of two waves, the higher of the sequence and a wave,
//! and a wave clamped as `std`'s `clamp` builds it. Then one run of constants locks signed zero,
//! the case where `@min` and `@max` differ by target: for each pair of a few, |a|, the minimum,
//! and the maximum, one line each, `zeros PAIR OP VALUE`. They come last, so every line before
//! them is a line of step 10.
//!
//! ## 12. TigerStyle Invariants
//! - The text fits in `text_size_max` by construction, so `render` cannot fail.

const std = @import("std");
const assert = std.debug.assert;
const weft = @import("weft");

const Signal = struct {
    name: []const u8,
    hz: f64,
    rate_hz: u32,
    stride_ticks: u32,
};

const Epoch = struct {
    name: []const u8,
    seconds: i64,
};

const signals = [_]Signal{
    .{ .name = "1hz", .hz = 1, .rate_hz = 60, .stride_ticks = 3 },
    .{ .name = "0.7hz", .hz = 0.7, .rate_hz = 60, .stride_ticks = 3 },
    .{ .name = "261.63hz", .hz = 261.63, .rate_hz = 44_100, .stride_ticks = 8 },
    .{ .name = "440hz", .hz = 440, .rate_hz = 48_000, .stride_ticks = 8 },
};

const epochs = [_]Epoch{
    .{ .name = "zero", .seconds = 0 },
    .{ .name = "hour", .seconds = 3600 },
    .{ .name = "day", .seconds = 86_400 },
    .{ .name = "before", .seconds = -3600 },
};

const shapes = std.enums.values(weft.Shape);

const noise_shapes = std.enums.values(weft.noise.Shape);

const noise_seed: u64 = 0x5eed;

/// Each graph's nodes are built by `graph_build`.
const Graph = enum {
    tremolo,
    drift,
    sequence,
    wander,
    spring,
    glide,
    chase,
    follow,
    shift,
    feedback,
    recorded,
    oscillator,
    live_chase,
    live_sway,
    live_glide,

    const nodes_count_max = 8;
    /// Room for the outputs of `nodes_count_max` nodes, and for the largest cache: two motions'
    /// cursors, or a shift register's state.
    const slab_count_max = nodes_count_max + shift_buckets + 4;
    const cues_count = 3;
    const shift_buckets = 8;

    /// The regions of the follower, as one span.
    const regions_count = 2;

    /// The goals of the motion graphs, one at each cue, as two paths in one table.
    const goals_count = 6;
    const spring_goals: weft.Path = .{ .first = 0, .count = 3 };
    const glide_goals: weft.Path = .{ .first = 3, .count = 3 };

    /// The samples of the recorded graph, as one clip: seconds after the epoch, and values.
    const recorded_samples = [_][2]f64{
        .{ 0.5, 0.25 }, .{ 1.125, -0.625 }, .{ 1.75, 0.875 }, .{ 2.625, -0.25 }, .{ 3.25, 0.5 },
    };
    const recorded_clip: weft.Clip = .{ .first = 0, .count = recorded_samples.len };

    /// The tracks of the live graphs: their bounds and initial values, then their writes as
    /// seconds after the epoch and values, in time order (section 9).
    const tracks_count = 4;
    const track_bounds = [tracks_count][3]f64{
        .{ 0.25, 3, 1 }, // an oscillator's rate, Hz
        .{ 0.125, 1, 0.5 }, // a chase's time, s
        .{ 0, 0.9, 0.2 }, // a follower's overshoot
        .{ 0.25, 4, 1 }, // a Newtonian follower's speed
    };
    const track_writes = [tracks_count][2][2]f64{
        .{ .{ 0.5, 2 }, .{ 2, 0.75 } },
        .{ .{ 1, 0.25 }, .{ 2.5, 0.875 } },
        .{ .{ 0.75, 0.7 }, .{ 3, 0 } },
        .{ .{ 1.25, 3 }, .{ 2.5, 0.5 } },
    };
};

/// The graphs whose bits are the same at every epoch, because they read only differences of cue
/// times and the time.
const graphs_epoch_free = [_]Graph{
    .sequence,   .spring,     .glide,     .chase,      .follow, .shift, .feedback, .recorded,
    .oscillator, .live_chase, .live_sway, .live_glide,
};

/// The graphs rendered before the events, the graphs of step 6.
const graphs = std.enums.values(Graph)[0 .. std.enums.values(Graph).len - graphs_after_events.len];

/// The graphs rendered after the events, so the lines of step 7 stay where they were.
const graphs_after_events = [_]Graph{
    .recorded, .oscillator, .live_chase, .live_sway, .live_glide,
};

/// The graphs of section 11, each built by `value_graph_build`, after the runaway.
const ValueGraph = enum {
    abs,
    min,
    max,
    clamp,
};

const value_graphs = std.enums.values(ValueGraph);

/// The pairs of section 11's run of constants: each signed zero either way round, equal values,
/// and two that differ.
const zero_pairs = [_][2]f64{
    .{ 0.0, -0.0 }, .{ -0.0, 0.0 }, .{ -0.0, -0.0 }, .{ 0.0, 0.0 }, .{ 0.5, 0.5 }, .{ -2, 3 },
};

/// The graphs whose events are listed, each built by `event_graph_build`.
const EventGraph = enum {
    bounce,
    crossing,
    follow,
    shift,
    cues,
    glide,

    /// The events each keeps in its buffer and drops, at every epoch.
    fn expected(graph: EventGraph) weft.Events {
        return switch (graph) {
            .bounce => .{ .count = 4, .dropped = 0 },
            .crossing => .{ .count = 2, .dropped = 0 },
            .follow => .{ .count = 9, .dropped = 0 },
            .shift => .{ .count = 16, .dropped = 5 },
            .cues => .{ .count = 3, .dropped = 0 },
            .glide => .{ .count = 2, .dropped = 0 },
        };
    }
};

const event_graphs = std.enums.values(EventGraph);

/// The buffer each event run has, which the shift register overflows.
const events_per_run_max = 16;

/// The range each event run reports: the first six seconds after the epoch.
const event_range_seconds = 6;

const samples_per_run = 24;

const wave_sample_count = shapes.len * signals.len * epochs.len * samples_per_run;
const noise_sample_count = noise_shapes.len * signals.len * epochs.len * samples_per_run;
const graph_sample_count = (graphs.len + graphs_after_events.len) * epochs.len * samples_per_run;

/// The runaway section's samples (section 10): two graphs, every 10 s from 0 to 300 s.
const runaway_samples_per_run = 31;
const runaway_stride_seconds = 10;
const runaway_sample_count = 2 * runaway_samples_per_run;

/// Section 11's samples: its graphs at every epoch, then three lines a pair of constants.
const value_sample_count = value_graphs.len * epochs.len * samples_per_run;
const zero_sample_count = 3 * zero_pairs.len;

pub const sample_count = wave_sample_count + noise_sample_count + graph_sample_count +
    runaway_sample_count + value_sample_count + zero_sample_count;

pub const event_count = count: {
    var count: u32 = 0;
    for (event_graphs) |graph| {
        assert(graph.expected().count <= events_per_run_max);
        count += graph.expected().count;
    }
    break :count count * epochs.len;
};

/// One line per sample and per event.
pub const line_count = sample_count + event_count;

const line_size_max = 64;

pub const text_size_max = line_count * line_size_max;

comptime {
    assert(wave_sample_count == 1536);
    assert(noise_sample_count == 768);
    assert(graph_sample_count == 1440);
    const graphs_last = std.enums.values(Graph)[graphs.len..];
    for (graphs_after_events, graphs_last) |late, last| assert(late == last);
    assert(event_count == 144);
    assert(value_sample_count == 384);
    assert(zero_sample_count == 18);
    assert(Graph.slab_count_max >= Graph.nodes_count_max + 2 * weft.motion.cursor_count);
    assert(text_size_max < 1 << 20);
    for (signals) |signal| assert(weft.Rate.from_hz(signal.rate_hz) != null);
}

/// Writes the catalog into `text` and returns the part written.
pub fn render(text: *[text_size_max]u8) []const u8 {
    var writer: std.Io.Writer = .fixed(text);
    for (shapes) |shape| {
        for (&signals) |*signal| {
            for (&epochs) |*epoch| render_run(&writer, shape, signal, epoch);
        }
    }
    for (noise_shapes) |shape| {
        for (&signals) |*signal| {
            for (&epochs) |*epoch| render_noise_run(&writer, shape, signal, epoch);
        }
    }
    for (graphs) |graph| {
        for (&epochs) |*epoch| render_graph_run(&writer, graph, epoch);
    }
    for (event_graphs) |graph| {
        for (&epochs) |*epoch| render_event_run(&writer, graph, epoch);
    }
    for (graphs_after_events) |graph| {
        for (&epochs) |*epoch| render_graph_run(&writer, graph, epoch);
    }
    render_runaway(&writer, false);
    render_runaway(&writer, true);
    for (value_graphs) |graph| {
        for (&epochs) |*epoch| render_graph_run(&writer, graph, epoch);
    }
    render_zeros(&writer);
    assert(writer.buffered().len > line_count);
    assert(writer.buffered()[writer.buffered().len - 1] == '\n');
    return writer.buffered();
}

fn render_run(
    writer: *std.Io.Writer,
    shape: weft.Shape,
    signal: *const Signal,
    epoch: *const Epoch,
) void {
    assert(signal.stride_ticks > 0);
    assert(signal.hz > 0);
    const wave = weft.Wave{ .shape = shape, .hz = signal.hz };
    const rate = weft.Rate.from_hz(signal.rate_hz).?;
    const tick_first = epoch.seconds * signal.rate_hz;
    for (0..samples_per_run) |index| {
        const tick = tick_first + @as(i64, @intCast(index * signal.stride_ticks));
        const value = wave.sample(weft.Time.from_ticks(tick, rate).?);
        const size_before = writer.buffered().len;
        writer.print("{t} {s} {s} {d} {x}\n", .{
            shape, signal.name, epoch.name, index, value,
        }) catch unreachable;
        assert(writer.buffered().len - size_before <= line_size_max);
    }
}

fn render_noise_run(
    writer: *std.Io.Writer,
    shape: weft.noise.Shape,
    signal: *const Signal,
    epoch: *const Epoch,
) void {
    assert(signal.stride_ticks > 0);
    assert(signal.hz > 0);
    const noise = weft.Noise{ .shape = shape, .hz = signal.hz, .seed = noise_seed };
    const rate = weft.Rate.from_hz(signal.rate_hz).?;
    const tick_first = epoch.seconds * signal.rate_hz;
    for (0..samples_per_run) |index| {
        const tick = tick_first + @as(i64, @intCast(index * signal.stride_ticks));
        const value = noise.sample(weft.Time.from_ticks(tick, rate).?);
        const size_before = writer.buffered().len;
        writer.print("{t} {s} {s} {d} {x}\n", .{
            shape, signal.name, epoch.name, index, value,
        }) catch unreachable;
        assert(writer.buffered().len - size_before <= line_size_max);
    }
}

/// The tables every graph run reads at an epoch: cues half a second into it, then a second apart,
/// the goals of the motion graphs at them, and the follower's regions.
const Tables = struct {
    cue_times: [Graph.cues_count]weft.Time,
    cues: weft.Cues,
    goal_entries: [Graph.goals_count]weft.Goal,
    goals: weft.Goals,
    region_entries: [Graph.regions_count]weft.Region,
    regions: weft.Regions,
    sample_entries: [Graph.recorded_samples.len]weft.Sample,
    samples: weft.Samples,
    track_entries: [Graph.tracks_count]weft.Track,
    track_samples: [Graph.tracks_count][2]weft.Sample,
    tracks: weft.Tracks,

    fn init(tables: *Tables, epoch: *const Epoch) void {
        tables.cues = weft.Cues.init(&tables.cue_times);
        var cue_ids: [Graph.cues_count]weft.Cue = undefined;
        for (&cue_ids, 0..) |*cue, index| {
            const half_seconds: i64 = 2 * @as(i64, @intCast(index)) + 1;
            const flicks = (2 * epoch.seconds + half_seconds) * flicks_per_half_second;
            cue.* = tables.cues.add(.{ .flicks = flicks }) catch unreachable;
        }
        tables.goals = weft.Goals.init(&tables.goal_entries);
        const spring_goals = tables.goals.add(&.{
            .{ .cue = cue_ids[0], .value = 1 },
            .{ .cue = cue_ids[1], .value = -0.5 },
            .{ .cue = cue_ids[2], .value = 0.25 },
        }) catch unreachable;
        const glide_goals = tables.goals.add(&.{
            .{ .cue = cue_ids[0], .value = 1 },
            .{ .cue = cue_ids[1], .value = -1 },
            .{ .cue = cue_ids[2], .value = 0.5 },
        }) catch unreachable;
        assert(std.meta.eql(spring_goals, Graph.spring_goals));
        assert(std.meta.eql(glide_goals, Graph.glide_goals));
        tables.regions = weft.Regions.init(&tables.region_entries);
        _ = tables.regions.add(&.{
            .{ .low = -1, .high = -0.5 },
            .{ .low = 0.25, .high = 1 },
        }) catch unreachable;
        tables.samples = weft.Samples.init(&tables.sample_entries);
        var samples: [Graph.recorded_samples.len]weft.Sample = undefined;
        for (&samples, Graph.recorded_samples) |*sample, row| {
            // Each time is a whole number of eighths of a second, so its flicks are exact.
            const second: f64 = @floatFromInt(weft.time.flicks_per_second);
            const flicks: i64 = @intFromFloat(row[0] * second);
            sample.* = .{
                .time = .{ .flicks = epoch.seconds * weft.time.flicks_per_second + flicks },
                .value = row[1],
            };
        }
        const clip = tables.samples.add(&samples) catch unreachable;
        assert(std.meta.eql(clip, Graph.recorded_clip));
        tables.tracks = weft.Tracks.init(&tables.track_entries);
        const second: f64 = @floatFromInt(weft.time.flicks_per_second);
        const epoch_flicks = epoch.seconds * weft.time.flicks_per_second;
        const rows = .{ &tables.track_samples, Graph.track_bounds, Graph.track_writes };
        for (rows[0], rows[1], rows[2]) |*entries, bound, writes| {
            const id = tables.tracks.add(entries, bound[0], bound[1], bound[2]) catch unreachable;
            for (writes) |row| {
                // Each time is a whole number of quarter seconds, so its flicks are exact.
                const after: i64 = @intFromFloat(row[0] * second);
                const time: weft.Time = .{ .flicks = epoch_flicks + after };
                tables.tracks.write(id, time, row[1]) catch unreachable;
            }
        }
    }

    /// A builder over these tables, with the first cue as the start.
    fn builder(tables: *const Tables, nodes: []weft.Node, slab_count_max: u32) weft.Builder {
        assert(tables.cues.count == Graph.cues_count);
        return weft.Builder.init(nodes, .{
            .slab_count_max = slab_count_max,
            .cues = &tables.cues,
            .goals = tables.goals.table(),
            .regions = tables.regions.table(),
            .samples = tables.samples.table(),
            .tracks = &tables.tracks,
            .start = .{ .index = 0 },
            .seed = noise_seed,
        });
    }
};

/// Samples a `Graph` or a `ValueGraph` at `epoch`.
fn render_graph_run(writer: *std.Io.Writer, graph: anytype, epoch: *const Epoch) void {
    var tables: Tables = undefined;
    tables.init(epoch);
    var nodes: [Graph.nodes_count_max]weft.Node = undefined;
    var slab: [Graph.slab_count_max]f64 = undefined;
    var builder = tables.builder(&nodes, slab.len);
    const output = build_any(graph, &builder) catch unreachable;
    var state = weft.State.init(builder.finish(), &slab);

    const rate = weft.Rate.from_hz(48_000).?;
    const tick_first = epoch.seconds * 48_000;
    for (0..samples_per_run) |index| {
        const tick = tick_first + @as(i64, @intCast(index)) * graph_stride_ticks;
        state.eval(weft.Time.from_ticks(tick, rate).?);
        const size_before = writer.buffered().len;
        writer.print("graph {t} {s} {d} {x}\n", .{
            graph, epoch.name, index, state.value(output),
        }) catch unreachable;
        assert(writer.buffered().len - size_before <= line_size_max);
    }
}

/// Samples a runaway loop at the zero epoch, its gain 1.5 throughout, or turned back to 0.5 at
/// 150 s by a track when `turned_back`, as section 10 explains.
fn render_runaway(writer: *std.Io.Writer, turned_back: bool) void {
    var cue_times: [1]weft.Time = undefined;
    var cues = weft.Cues.init(&cue_times);
    _ = cues.add(.{ .flicks = 0 }) catch unreachable;
    var track_entries: [1]weft.Track = undefined;
    var track_samples: [1]weft.Sample = undefined;
    var tracks = weft.Tracks.init(&track_entries);
    const gain_track = tracks.add(&track_samples, 0, 2, 1.5) catch unreachable;
    if (turned_back) {
        tracks.write(gain_track, .{ .flicks = 150 * weft.time.flicks_per_second }, 0.5) catch unreachable;
    }
    var nodes: [6]weft.Node = undefined;
    var slab: [16]f64 = undefined;
    var builder = weft.Builder.init(&nodes, .{ .slab_count_max = slab.len, .cues = &cues, .tracks = &tracks });
    const loop = runaway_build(&builder, gain_track) catch unreachable;
    var state = weft.State.init(builder.finish(), &slab);
    const name = if (turned_back) "turned_back" else "held";
    for (0..runaway_samples_per_run) |index| {
        const seconds: i64 = @intCast(index * runaway_stride_seconds);
        state.eval(.{ .flicks = seconds * weft.time.flicks_per_second });
        const size_before = writer.buffered().len;
        writer.print("runaway {s} zero {d} {x}\n", .{ name, index, state.value(loop) }) catch unreachable;
        assert(writer.buffered().len - size_before <= line_size_max);
    }
}

/// A chase of 1 + gain times its own delay, the gain read from `gain_track`.
fn runaway_build(builder: *weft.Builder, gain_track: weft.TrackId) weft.Builder.Error!weft.Id {
    const feedback = try builder.delay(0);
    const gain = try builder.track(gain_track);
    const target = try builder.add(try builder.constant(1), try builder.multiply(feedback, gain));
    const loop = try builder.chase(.{
        .target = target,
        .from = 0,
        .time = .{ .flicks = flicks_per_half_second },
        .overshoot = 0,
    });
    try builder.close(feedback, loop);
    return loop;
}

/// Writes |a|, the minimum, and the maximum of each pair of `zero_pairs`, from nodes, as section 11
/// explains.
fn render_zeros(writer: *std.Io.Writer) void {
    for (zero_pairs, 0..) |pair, index| {
        var nodes: [5]weft.Node = undefined;
        var builder = weft.Builder.init(&nodes, .{ .slab_count_max = 5 });
        const a = builder.constant(pair[0]) catch unreachable;
        const b = builder.constant(pair[1]) catch unreachable;
        const outputs = [_]weft.Id{
            builder.apply(.abs, a) catch unreachable,
            builder.minimum(a, b) catch unreachable,
            builder.maximum(a, b) catch unreachable,
        };
        var slab: [5]f64 = undefined;
        var state = weft.State.init(builder.finish(), &slab);
        state.eval(.{ .flicks = 0 });
        for (outputs, [_][]const u8{ "abs", "min", "max" }) |id, name| {
            const size_before = writer.buffered().len;
            writer.print("zeros {d} {s} {x}\n", .{ index, name, state.value(id) }) catch unreachable;
            assert(writer.buffered().len - size_before <= line_size_max);
        }
    }
}

/// Lists the events of the first `event_range_seconds` of `graph` at `epoch`, as section 7
/// explains.
fn render_event_run(writer: *std.Io.Writer, graph: EventGraph, epoch: *const Epoch) void {
    var tables: Tables = undefined;
    tables.init(epoch);
    var nodes: [Graph.nodes_count_max]weft.Node = undefined;
    var slab: [Graph.slab_count_max]f64 = undefined;
    var builder = tables.builder(&nodes, slab.len);
    event_graph_build(graph, &builder) catch unreachable;
    var state = weft.State.init(builder.finish(), &slab);

    const epoch_flicks = epoch.seconds * weft.time.flicks_per_second;
    const end_flicks = epoch_flicks + event_range_seconds * weft.time.flicks_per_second;
    var out: [events_per_run_max]weft.Event = undefined;
    const result = state.events(.{ .flicks = epoch_flicks }, .{ .flicks = end_flicks }, &out);
    assert(std.meta.eql(result, graph.expected()));
    for (out[0..result.count], 0..) |event, index| {
        assert(event.time.flicks >= epoch_flicks);
        const size_before = writer.buffered().len;
        writer.print("event {t} {s} {d} {d} {d} {x}\n", .{
            graph,
            epoch.name,
            index,
            event.time.flicks - epoch_flicks,
            event.source.index,
            event.value,
        }) catch unreachable;
        assert(writer.buffered().len - size_before <= line_size_max);
    }
}

fn event_graph_build(graph: EventGraph, builder: *weft.Builder) weft.Builder.Error!void {
    switch (graph) {
        // Between -1 and 1 at 1.5 units a second: a hit every 4/3 s from the first cue.
        .bounce => _ = try builder.bounce(.{
            .low = -1,
            .high = 1,
            .speed = 1.5,
            .start = .{ .index = 0 },
        }),
        // The sequence of tweens crossing 0.5 either way: rising in the first tween, at its middle,
        // and falling in the last.
        .crossing => {
            const sequence = try build_sequence(builder);
            _ = try builder.crossing(.{ .input = sequence, .level = 0.5, .direction = .both });
        },
        .follow => _ = try graph_build(.follow, builder),
        .shift => _ = try graph_build(.shift, builder),
        .cues => _ = try builder.cues(.{ .first = .{ .index = 0 }, .count = Graph.cues_count }),
        // The first goal lands before the second cue; the second is cut short by the third.
        .glide => _ = try graph_build(.glide, builder),
    }
}

/// Spreads a run over about four seconds, nearly three cycles of the slowest wave.
const graph_stride_ticks = 8192;

const flicks_per_half_second = @divExact(weft.time.flicks_per_second, 2);

fn graph_build(graph: Graph, builder: *weft.Builder) weft.Builder.Error!weft.Id {
    switch (graph) {
        // 440 Hz scaled by a slower wave moved into [0.25, 1].
        .tremolo => {
            const fast = try builder.wave(.{ .shape = .sine, .hz = 440 });
            const slow = try builder.wave(.{ .shape = .triangle, .hz = 0.7 });
            const depth = try builder.map_range(.{
                .input = slow,
                .input_low = -1,
                .input_high = 1,
                .output_low = 0.25,
                .output_high = 1,
            });
            return builder.multiply(fast, depth);
        },
        // Two slow waves added, with an offset, as a position would be.
        .drift => {
            const first = try builder.wave(.{ .shape = .sine, .hz = 0.7 });
            const second = try builder.wave(.{ .shape = .saw, .hz = 1 });
            const half = try builder.constant(0.5);
            const scaled = try builder.multiply(second, half);
            return builder.add(first, scaled);
        },
        // Three tweens a second each, one on each cue, with an overshoot in the middle.
        .sequence => return build_sequence(builder),
        // A slow smooth noise with a quarter of a faster stepped one added, as a hand would drift.
        .wander => {
            const slow = try builder.noise(.{ .shape = .smooth, .hz = 0.7, .seed = 1 });
            const fast = try builder.noise(.{ .shape = .steps, .hz = 3, .seed = 2 });
            const quarter = try builder.constant(0.25);
            const jitter = try builder.multiply(fast, quarter);
            return builder.add(slow, jitter);
        },
        // A spring of overshoot 0.2 and a period of 0.6 s, retargeted at each cue, mid-swing.
        .spring => return builder.spring(.{
            .from = 0,
            .goals = Graph.spring_goals,
            .time = .{ .flicks = 6 * @divExact(weft.time.flicks_per_second, 10) },
            .overshoot = 0.2,
        }),
        // A Newtonian move, retargeted behind it at the second cue, before it can stop.
        .glide => return builder.newtonian(.{
            .from = 0,
            .goals = Graph.glide_goals,
            .speed = 1.5,
            .accel = 6,
            .decel = 4,
        }),
        // A bouncy spring chasing the sequence of tweens, overshoot and jump included.
        .chase => {
            const target = try build_sequence(builder);
            return builder.chase(.{
                .target = target,
                .from = -0.5,
                .time = .{ .flicks = 4 * @divExact(weft.time.flicks_per_second, 10) },
                .overshoot = 0.15,
            });
        },
        // A follower on a critical spring, between two regions at random, pausing a little.
        .follow => return builder.follow(.{
            .from = 0,
            .regions = .{ .first = 0, .count = Graph.regions_count },
            .pick = .random,
            .mover = .{ .spring = .{
                .time = .{ .flicks = 3 * @divExact(weft.time.flicks_per_second, 10) },
                .overshoot = 0,
            } },
            .tolerance = 0.02,
            .pause_min = .{ .flicks = @divExact(weft.time.flicks_per_second, 10) },
            .pause_max = .{ .flicks = 4 * @divExact(weft.time.flicks_per_second, 10) },
            .seed = 5,
        }),
        // A smooth shift register of eight buckets, a pass every 2 s, half of them changing.
        .shift => return builder.shift(.{
            .buckets = Graph.shift_buckets,
            .period = .{ .flicks = 2 * weft.time.flicks_per_second },
            .low = -1,
            .high = 1,
            .odds = 0.5,
            .shape = .smooth,
            .seed = 6,
        }),
        // A spring chasing 1 - 0.8 times its own delay, which settles at 1 / 1.8.
        .feedback => {
            const echo = try builder.delay(0);
            const gain = try builder.constant(-0.8);
            const scaled = try builder.multiply(echo, gain);
            const one = try builder.constant(1);
            const target = try builder.add(one, scaled);
            const result = try builder.chase(.{
                .target = target,
                .from = 0,
                .time = .{ .flicks = @divExact(weft.time.flicks_per_second, 2) },
                .overshoot = 0.2,
            });
            try builder.close(echo, result);
            return result;
        },
        // A triangle whose rate is a track, from 1 Hz, written to 2 Hz and back down to 0.75 Hz.
        .oscillator => {
            const rate = try builder.track(.{ .index = 0 });
            return builder.oscillator(.{ .shape = .triangle, .rate = rate, .phase = 0.25 });
        },
        // A chase of the sequence whose time is a track: 0.5 s, then 0.25 s, then 0.875 s.
        .live_chase => {
            const target = try build_sequence(builder);
            const time = try builder.track(.{ .index = 1 });
            return builder.chase(.{
                .target = target,
                .from = 0,
                .time = .{ .flicks = flicks_per_half_second },
                .overshoot = 0.15,
                .time_from = time,
            });
        },
        // The follower of `follow` on a 0.4 s spring whose overshoot is a track.
        .live_sway => {
            const overshoot = try builder.track(.{ .index = 2 });
            return builder.follow(.{
                .from = 0,
                .regions = .{ .first = 0, .count = Graph.regions_count },
                .pick = .random,
                .mover = .{ .spring = .{
                    .time = .{ .flicks = 4 * @divExact(weft.time.flicks_per_second, 10) },
                    .overshoot = 0.2,
                } },
                .tolerance = 0.02,
                .pause_min = .{ .flicks = @divExact(weft.time.flicks_per_second, 10) },
                .pause_max = .{ .flicks = 4 * @divExact(weft.time.flicks_per_second, 10) },
                .seed = 7,
                .mover_from = .{ .overshoot = overshoot },
            });
        },
        // A Newtonian follower whose speed is a track and whose accel and decel are four times it.
        .live_glide => {
            const speed = try builder.track(.{ .index = 3 });
            const four = try builder.constant(4);
            const limit = try builder.multiply(speed, four);
            return builder.follow(.{
                .from = 0,
                .regions = .{ .first = 0, .count = Graph.regions_count },
                .pick = .random,
                .mover = .{ .newtonian = .{ .speed = 1, .accel = 4, .decel = 4 } },
                .tolerance = 0.02,
                .pause_min = .{ .flicks = 0 },
                .pause_max = .{ .flicks = 3 * @divExact(weft.time.flicks_per_second, 10) },
                .seed = 8,
                .mover_from = .{ .speed = speed, .accel = limit, .decel = limit },
            });
        },
        // A spring chasing a recording played back.
        .recorded => {
            const played = try builder.recorded(Graph.recorded_clip);
            return builder.chase(.{
                .target = played,
                .from = 0,
                .time = .{ .flicks = @divExact(weft.time.flicks_per_second * 2, 5) },
                .overshoot = 0.15,
            });
        },
    }
}

/// The nodes of the graph `name` at epoch zero, and its output, for the language's test, which
/// writes each graph as text and checks it builds these nodes (`test/lang.zig`).
pub fn graph_nodes(name: []const u8, nodes: *[Graph.nodes_count_max]weft.Node) ?struct { count: usize, output: weft.Id } {
    var tables: Tables = undefined;
    tables.init(&epochs[0]);
    var builder = tables.builder(nodes, Graph.slab_count_max);
    const output = if (std.meta.stringToEnum(Graph, name)) |graph|
        graph_build(graph, &builder) catch unreachable
    else if (std.meta.stringToEnum(ValueGraph, name)) |graph|
        value_graph_build(graph, &builder) catch unreachable
    else
        return null;
    const program = builder.finish();
    return .{ .count = program.nodes.len, .output = output };
}

/// The output of a `Graph` or a `ValueGraph`, built.
fn build_any(graph: anytype, builder: *weft.Builder) weft.Builder.Error!weft.Id {
    return switch (@TypeOf(graph)) {
        Graph => graph_build(graph, builder),
        ValueGraph => value_graph_build(graph, builder),
        else => @compileError("not a catalog graph"),
    };
}

fn value_graph_build(graph: ValueGraph, builder: *weft.Builder) weft.Builder.Error!weft.Id {
    switch (graph) {
        // The drift's distance from 0, which it crosses.
        .abs => return builder.apply(.abs, try graph_build(.drift, builder)),
        // The lower of two slow waves, which cross each other.
        .min => {
            const first = try builder.wave(.{ .shape = .sine, .hz = 0.7 });
            const second = try builder.wave(.{ .shape = .triangle, .hz = 1 });
            return builder.minimum(first, second);
        },
        // The higher of the sequence and half a slow wave.
        .max => {
            const sequence = try build_sequence(builder);
            const wave = try builder.wave(.{ .shape = .sine, .hz = 0.7 });
            const half = try builder.multiply(wave, try builder.constant(0.5));
            return builder.maximum(sequence, half);
        },
        // Twice a slow wave held in [-0.5, 1], as `std`'s `clamp` builds it.
        .clamp => {
            const wave = try builder.wave(.{ .shape = .sine, .hz = 0.7 });
            const loud = try builder.multiply(wave, try builder.constant(2));
            const above = try builder.maximum(loud, try builder.constant(-0.5));
            return builder.minimum(above, try builder.constant(1));
        },
    }
}

pub const graph_nodes_max = Graph.nodes_count_max;

/// The three tweens of `sequence`, a second each, one on each cue, with an overshoot in the middle.
fn build_sequence(builder: *weft.Builder) weft.Builder.Error!weft.Id {
    const second: weft.Time = .{ .flicks = weft.time.flicks_per_second };
    const rise = try builder.tween(.{
        .from = 0,
        .to = 1,
        .duration = second,
        .ease = .in_out,
        .start = .{ .index = 0 },
        .previous = null,
    });
    const overshoot = try builder.tween(.{
        .from = 1,
        .to = 3,
        .duration = second,
        .ease = .{ .x1 = 0.34, .y1 = 1.56, .x2 = 0.64, .y2 = 1 },
        .start = .{ .index = 1 },
        .previous = rise,
    });
    return builder.tween(.{
        .from = 3,
        .to = -0.1,
        .duration = second,
        .ease = .out,
        .start = .{ .index = 2 },
        .previous = overshoot,
    });
}

pub const Mismatch = struct {
    /// 1-based, as an editor counts lines.
    line: u32,
    expected: []const u8,
    actual: []const u8,
};

const text_end = "(end of text)";

/// The first line where two texts differ, or null if they are equal.
pub fn compare(expected: []const u8, actual: []const u8) ?Mismatch {
    if (std.mem.eql(u8, expected, actual)) return null;
    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var actual_lines = std.mem.splitScalar(u8, actual, '\n');
    // A text of n bytes has at most n + 1 lines, and the texts differ within the shorter one + 1.
    for (0..expected.len + actual.len + 1) |index| {
        const expected_line = expected_lines.next();
        const actual_line = actual_lines.next();
        const same = if (expected_line != null and actual_line != null)
            std.mem.eql(u8, expected_line.?, actual_line.?)
        else
            false;
        if (same) continue;
        assert(expected_line != null or actual_line != null);
        return .{
            .line = @intCast(index + 1),
            .expected = expected_line orelse text_end,
            .actual = actual_line orelse text_end,
        };
    }
    unreachable;
}

const testing = std.testing;

var text_a: [text_size_max]u8 = undefined;
var text_b: [text_size_max]u8 = undefined;

// Locks the size of the catalog and that rendering twice gives the same bytes.
test "the catalog renders one line per sample and per event, the same each time" {
    const first = render(&text_a);
    const second = render(&text_b);
    try testing.expectEqualStrings(first, second);
    try testing.expectEqual(@as(usize, line_count), std.mem.count(u8, first, "\n"));
    try testing.expectEqual(@as(usize, event_count), std.mem.count(u8, first, "\nevent "));
    try testing.expect(std.mem.startsWith(u8, first, "sine 1hz zero 0 0x0.0p0\n"));
}

// Locks that a hex float keeps every bit: each value in the catalog parses back to a value that
// prints as the same text.
test "every sample round-trips through its text" {
    const text = render(&text_a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const hex = line[std.mem.lastIndexOfScalar(u8, line, ' ').? + 1 ..];
        const value = try std.fmt.parseFloat(f64, hex);
        var buffer: [line_size_max]u8 = undefined;
        const again = try std.fmt.bufPrint(&buffer, "{x}", .{value});
        try testing.expectEqualStrings(hex, again);
    }
}

// Locks the promise of regress: flipping the lowest bit of one sample fails the comparison, and
// the mismatch gives that sample's line and names its signal.
test "a one-bit change is found and names the signal" {
    const golden = render(&text_a);
    const line_target = 700;
    var lines = std.mem.splitScalar(u8, golden, '\n');
    for (0..line_target - 1) |_| _ = lines.next();
    const line = lines.next().?;

    const hex_start = std.mem.lastIndexOfScalar(u8, line, ' ').? + 1;
    const value = try std.fmt.parseFloat(f64, line[hex_start..]);
    const value_flipped: f64 = @bitCast(@as(u64, @bitCast(value)) ^ 1);
    var buffer: [line_size_max]u8 = undefined;
    const hex_flipped = try std.fmt.bufPrint(&buffer, "{x}", .{value_flipped});

    const line_start = line.ptr - golden.ptr;
    const head = golden[0 .. line_start + hex_start];
    const tail = golden[line_start + line.len ..];
    @memcpy(text_b[0..head.len], head);
    @memcpy(text_b[head.len..][0..hex_flipped.len], hex_flipped);
    const tail_start = head.len + hex_flipped.len;
    @memcpy(text_b[tail_start..][0..tail.len], tail);
    const changed = text_b[0 .. tail_start + tail.len];

    const mismatch = compare(golden, changed).?;
    try testing.expectEqual(@as(u32, line_target), mismatch.line);
    try testing.expectEqualStrings(line, mismatch.expected);
    try testing.expect(std.mem.startsWith(u8, mismatch.actual, line[0..hex_start]));
    try testing.expect(!std.mem.eql(u8, mismatch.expected, mismatch.actual));
}

// Locks what integer time gives tweens, motions, and simulations: the cues of `sequence`,
// `spring`, `glide`, and the simulated graphs sit at the same place in each epoch, so their samples
// have the same bits an hour either side of zero and a day on.
test "tweens, motions, and simulations have the same bits at every epoch" {
    const text = render(&text_a);
    for (graphs_epoch_free) |graph| {
        var buffer_start: [line_size_max]u8 = undefined;
        const start = try std.fmt.bufPrint(&buffer_start, "graph {t} zero 0 ", .{graph});
        const zero_start = std.mem.indexOf(u8, text, start).?;
        var zero_lines = std.mem.splitScalar(u8, text[zero_start..], '\n');
        var zero_values: [samples_per_run][]const u8 = undefined;
        for (&zero_values) |*value| {
            const line = zero_lines.next().?;
            value.* = line[std.mem.lastIndexOfScalar(u8, line, ' ').? + 1 ..];
        }
        for (epochs) |epoch| {
            for (zero_values, 0..) |value, index| {
                var buffer: [line_size_max]u8 = undefined;
                const line = try std.fmt.bufPrint(&buffer, "graph {t} {s} {d} {s}\n", .{
                    graph, epoch.name, index, value,
                });
                try testing.expect(std.mem.indexOf(u8, text, line) != null);
            }
        }
    }
}

// Locks the same for events: each event graph's lines at zero, with their index, time after the
// epoch, source, and value, appear at every epoch, as section 7 promises.
test "events have the same times and values at every epoch" {
    const text = render(&text_a);
    for (event_graphs) |graph| {
        var buffer_start: [line_size_max]u8 = undefined;
        const start = try std.fmt.bufPrint(&buffer_start, "event {t} zero 0 ", .{graph});
        const zero_start = std.mem.indexOf(u8, text, start).?;
        var zero_lines = std.mem.splitScalar(u8, text[zero_start..], '\n');
        const prefix_size = "event ".len + @tagName(graph).len + " zero ".len;
        for (0..graph.expected().count) |_| {
            const rest = zero_lines.next().?[prefix_size..];
            for (epochs) |epoch| {
                var buffer: [line_size_max]u8 = undefined;
                const line = try std.fmt.bufPrint(&buffer, "event {t} {s} {s}\n", .{
                    graph, epoch.name, rest,
                });
                try testing.expect(std.mem.indexOf(u8, text, line) != null);
            }
        }
    }
}

// Locks the answers of `compare` for equal texts, a missing line, and an extra blank line, the
// last of which two splitting iterators see only at their ends.
test "compare finds the end of a shorter text" {
    try testing.expectEqual(@as(?Mismatch, null), compare("a\nb\n", "a\nb\n"));
    const short = compare("a\nb\n", "a\n").?;
    try testing.expectEqual(@as(u32, 2), short.line);
    try testing.expectEqualStrings("b", short.expected);
    const long = compare("a\n", "a\n\n").?;
    try testing.expectEqual(@as(u32, 3), long.line);
    try testing.expectEqualStrings(text_end, long.expected);
}

// Locks section 10: held at a gain of 1.5, the loop is near the bound from 100 s on and holds the
// same bits; turned back to 0.5 at 150 s, it is back at 2 by 300 s.
test "the runaway graphs saturate, hold, and come back" {
    for ([_]bool{ false, true }) |turned_back| {
        var cue_times: [1]weft.Time = undefined;
        var cues = weft.Cues.init(&cue_times);
        _ = try cues.add(.{ .flicks = 0 });
        var track_entries: [1]weft.Track = undefined;
        var track_samples: [1]weft.Sample = undefined;
        var tracks = weft.Tracks.init(&track_entries);
        const gain_track = try tracks.add(&track_samples, 0, 2, 1.5);
        if (turned_back) try tracks.write(gain_track, .{ .flicks = 150 * weft.time.flicks_per_second }, 0.5);
        var nodes: [6]weft.Node = undefined;
        var slab: [16]f64 = undefined;
        var builder = weft.Builder.init(&nodes, .{ .slab_count_max = slab.len, .cues = &cues, .tracks = &tracks });
        const loop = try runaway_build(&builder, gain_track);
        var state = weft.State.init(builder.finish(), &slab);
        var held: ?f64 = null;
        for ([_]i64{ 100, 120, 140 }) |seconds| {
            state.eval(.{ .flicks = seconds * weft.time.flicks_per_second });
            try std.testing.expectApproxEqRel(weft.simulation.state_bound, state.value(loop), 1e-12);
            if (held) |value| try std.testing.expectEqual(value, state.value(loop));
            held = state.value(loop);
        }
        state.eval(.{ .flicks = 300 * weft.time.flicks_per_second });
        if (turned_back) {
            try std.testing.expectApproxEqAbs(@as(f64, 2), state.value(loop), 1e-9);
        } else {
            try std.testing.expectEqual(held.?, state.value(loop));
        }
    }
}
