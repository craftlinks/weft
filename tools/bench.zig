//! `zig build bench`: what Weft's reads cost on this machine, with no GPU.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Measures
//! Four cases, one line each, after a line naming the build mode. Run it with
//! `-Doptimize=ReleaseFast` for numbers worth recording; a Debug build measures the assertions.
//!
//! ```text
//! waves    a pure graph of 16 waves summed                     per eval
//! play     four chases on a wave plus noise, forwards at 60 Hz per frame, over 60 s
//! cold     that graph from a fresh state, the first eval        at 60 s, and at 600 s
//! events   a bounce and cues, events per 128-frame block        48 kHz blocks over 10 s
//! sources  16 waves summed, a bounce, and cues, then the same      per frame, 60 Hz for 10 s
//!          with a chase: `events` of 3 s behind to 3 s ahead of
//!          a playhead and an eval, then `events_of` the bounce
//!          and the cues beside the chase, and the eval alone
//!          (step 23)
//! write    the chase page with its springs' time from a track,  per frame, at 600 s
//!          a write of the track at the playhead, then the eval
//! compile  Play's `signals.weft` (step 12), parse to program      per compile
//! modules  a patch of modules nested 8 deep, 511 instances           per compile
//! lanes    a noise, a staggered tween, a map, a product, and a      per frame, at 1,000 and
//!          staggered bounce over n lanes: an eval, then the events  100,000 lanes
//! node     64 nodes of one op playing forwards at 60 Hz             per node, per frame
//! seek     Play's file read at 600 s, then at 300.99 s              the read at 300.99 s
//! recomp   Play's file with a pure line edited at 600 s: compile,   per recompile
//!          carry, and the first eval
//! audio    a reader on its own thread at audio pace, a 128-frame    the worst block, over 5 s
//!          block at 48 kHz every 2.667 ms: events, then an eval     of wall time each
//! ```
//! `audio` is the realtime check of step 18: Play's simulated file and the lanes page's thousand
//! lanes, each block's work timed and the reader asleep until the next block is due, as an audio
//! callback would be. It prints the worst block, how many blocks went over the 2.667 ms budget,
//! and the worst block per node.
//! `write` is what a knob costs when it applies from now on (step 9.5), beside `cold`, which is
//! what it cost as a rebuild.
//!
//! ## 2. Why No Thresholds
//! The numbers depend on the machine, so nothing here passes or fails, and it is not part of
//! `test` or `regress`. A step records the numbers on its page, and the next step compares.
//!
//! ## 3. The Clock
//! The monotonic clock Zig 0.17 offers a native tool, `std.Io.Clock.awake`. The library itself
//! still links nothing: only this executable reads a clock. Each case keeps a sum of what it read
//! and prints it, so no read can be optimized away, and repeats its run and keeps the fastest, so
//! a preemption does not count.
//!
//! ## 4. TigerStyle Invariants
//! - No allocation: every node array, slab, and checkpoint buffer is static.
//! - A case that fails to build panics with the error's name, in ReleaseFast too.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const weft = @import("weft");

const flicks_per_second = weft.time.flicks_per_second;
/// Runs of each case; the fastest is kept.
const repeats = 5;
const slab_max = 64;
/// Checkpoints for 600 s and a margin, the longest a case reads.
const checkpoints_max = 610;

var nodes: [64]weft.Node = undefined;
var slab: [slab_max]f64 = undefined;
var checkpoints: [checkpoints_max * slab_max]f64 = undefined;
var cue_times: [32]weft.Time = undefined;
/// The page's one cue, at 0, where its simulated nodes start.
var start_times: [1]weft.Time = undefined;
var start_cues: weft.Cues = undefined;
var events_out: [64]weft.Event = undefined;
/// The `sources` case's cues, every half second for 20 s.
var sources_cue_times: [40]weft.Time = undefined;
var sources_cues: weft.Cues = undefined;
var track_entries: [1]weft.Track = undefined;
var track_samples: [4096]weft.Sample = undefined;
var tracks: weft.Tracks = undefined;
/// The lanes case's program at 100,000 lanes: 6 nodes of a lane each, and the bounce's two.
var lanes_slab: [8 * 100_000]f64 = undefined;
var lanes_events: [4096]weft.Event = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    std.debug.print("bench: weft, {t}\n", .{builtin.mode});
    waves(io);
    play(io);
    cold(io);
    events(io);
    sources(io);
    write(io);
    compile(io);
    modules(io);
    lanes(io, 1_000);
    lanes(io, 100_000);
    per_node(io);
    seek(io);
    recompile(io);
    audio(io, "signals.weft", play_signals);
    audio(io, "lanes.weft", play_lanes);
}

fn now(io: std.Io) i96 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}

fn seconds(count: i64) weft.Time {
    return .{ .flicks = count * flicks_per_second };
}

/// Case 1: 16 waves at different rates and shapes, summed by 15 adds.
fn waves(io: std.Io) void {
    var builder = weft.Builder.init(&nodes, .{ .slab_count_max = slab_max });
    var sum = builder.wave(.{ .shape = .sine, .hz = 0.5 }) catch |err| fail(err);
    for (1..16) |index| {
        const shape: weft.Shape = @fromBackingInt(@intCast(index % 4));
        const hz = 0.5 + 0.37 * @as(f64, @floatFromInt(index));
        const wave = builder.wave(.{ .shape = shape, .hz = hz }) catch |err| fail(err);
        sum = builder.add(sum, wave) catch |err| fail(err);
    }
    const program = builder.finish();
    const rate = weft.Rate.from_hz(60).?;
    const evals = 1_000_000;
    var best: i96 = std.math.maxInt(i96);
    var total: f64 = 0;
    for (0..repeats) |_| {
        var state = weft.State.init(program, &slab);
        const start = now(io);
        for (0..evals) |frame| {
            state.eval(weft.Time.from_ticks(@intCast(frame), rate).?);
            total += state.value(sum);
        }
        best = @min(best, now(io) - start);
    }
    report("waves   16 waves summed, per eval", best, evals, total);
}

/// The page of cases 2 and 3: a wave plus noise, and four chases of it with different springs.
fn chases() struct { program: weft.Program, outputs: [4]weft.Id } {
    start_cues = weft.Cues.init(&start_times);
    _ = start_cues.add(.{ .flicks = 0 }) catch |err| fail(err);
    var builder = weft.Builder.init(&nodes, .{ .slab_count_max = slab_max, .cues = &start_cues });
    const wave = builder.wave(.{ .shape = .sine, .hz = 0.5 }) catch |err| fail(err);
    const noise = builder.noise(.{ .shape = .smooth, .hz = 1, .seed = 1 }) catch |err| fail(err);
    const target = builder.add(wave, noise) catch |err| fail(err);
    var outputs: [4]weft.Id = undefined;
    for (&outputs, 0..) |*output, index| {
        const tenths: i64 = 2 + @as(i64, @intCast(index));
        output.* = builder.chase(.{
            .target = target,
            .from = 0,
            .time = .{ .flicks = tenths * @divExact(flicks_per_second, 10) },
            .overshoot = 0.05 * @as(f64, @floatFromInt(index)),
        }) catch |err| fail(err);
    }
    return .{ .program = builder.finish(), .outputs = outputs };
}

/// Case 2: the page playing forwards at 60 Hz for 60 s, per frame.
fn play(io: std.Io) void {
    const page = chases();
    assert(page.program.simulated);
    const rate = weft.Rate.from_hz(60).?;
    const frames = 60 * 60;
    var best: i96 = std.math.maxInt(i96);
    var total: f64 = 0;
    for (0..repeats) |_| {
        var state = weft.State.init_with_checkpoints(page.program, &slab, &checkpoints);
        const start = now(io);
        for (0..frames) |frame| {
            state.eval(weft.Time.from_ticks(@intCast(frame), rate).?);
            for (page.outputs) |output| total += state.value(output);
        }
        best = @min(best, now(io) - start);
    }
    report("play    4 chases, 60 Hz, per frame", best, frames, total);
}

/// Case 3: the page from a fresh state, the first eval at 60 s and at 600 s.
fn cold(io: std.Io) void {
    const page = chases();
    for ([_]i64{ 60, 600 }) |at| {
        var best: i96 = std.math.maxInt(i96);
        var total: f64 = 0;
        for (0..repeats) |_| {
            var state = weft.State.init_with_checkpoints(page.program, &slab, &checkpoints);
            const start = now(io);
            state.eval(seconds(at));
            best = @min(best, now(io) - start);
            total += state.value(page.outputs[0]);
        }
        var label_buffer: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buffer, "cold    first eval at {d} s", .{at}) catch
            unreachable;
        report(label, best, 1, total);
    }
}

/// Case 4: a bounce and 21 cues half a second apart, `events` per 128-frame block at 48 kHz,
/// 1,881,600 flicks, over 10 s.
fn events(io: std.Io) void {
    var cues = weft.Cues.init(&cue_times);
    for (0..21) |index| {
        const half_seconds: i64 = @intCast(index);
        _ = cues.add(.{ .flicks = half_seconds * @divExact(flicks_per_second, 2) }) catch
            unreachable;
    }
    var builder = weft.Builder.init(&nodes, .{ .slab_count_max = slab_max, .cues = &cues });
    _ = builder.bounce(.{ .low = 0, .high = 1, .speed = 7, .start = .{ .index = 0 } }) catch
        unreachable;
    _ = builder.cues(.{ .first = .{ .index = 0 }, .count = 21 }) catch |err| fail(err);
    const program = builder.finish();
    const block: i64 = 1_881_600;
    assert(@mod(block * 48_000, 128 * flicks_per_second) == 0);
    const blocks: u64 = @intCast(@divFloor(10 * flicks_per_second, block));
    var best: i96 = std.math.maxInt(i96);
    var total: f64 = 0;
    for (0..repeats) |_| {
        var state = weft.State.init(program, &slab);
        const start = now(io);
        var t0: i64 = 0;
        for (0..blocks) |_| {
            const found = state.events(.{ .flicks = t0 }, .{ .flicks = t0 + block }, &events_out);
            assert(found.dropped == 0);
            total += @floatFromInt(found.count);
            t0 += block;
        }
        best = @min(best, now(io) - start);
    }
    report("events  bounce and cues, per block", best, blocks, total);
}

/// The `sources` case's program: 16 waves summed, a bounce, and cues every half second, with or
/// without a chase of the sum, and the ids of the bounce's position and the cues.
const SourcesPage = struct {
    program: weft.Program,
    sources: [2]weft.Id,
};

fn sources_page(with_chase: bool) SourcesPage {
    var builder = weft.Builder.init(&nodes, .{ .slab_count_max = slab_max, .cues = &sources_cues });
    var sum = builder.wave(.{ .shape = .sine, .hz = 0.5 }) catch |err| fail(err);
    for (1..16) |index| {
        const shape: weft.Shape = @fromBackingInt(@intCast(index % 4));
        const hz = 0.5 + 0.37 * @as(f64, @floatFromInt(index));
        const wave = builder.wave(.{ .shape = shape, .hz = hz }) catch |err| fail(err);
        sum = builder.add(sum, wave) catch |err| fail(err);
    }
    const ball = builder.bounce(.{ .low = 0, .high = 1, .speed = 3, .start = .{ .index = 0 } }) catch |err|
        fail(err);
    const count: u32 = @intCast(sources_cues.count);
    const beats = builder.cues(.{ .first = .{ .index = 0 }, .count = count }) catch |err| fail(err);
    if (with_chase) {
        _ = builder.chase(.{
            .target = sum,
            .from = 0,
            .time = .{ .flicks = @divExact(flicks_per_second, 2) },
            .overshoot = 0.1,
        }) catch |err| fail(err);
    }
    assert(ball.position.index < beats.index);
    return .{ .program = builder.finish(), .sources = .{ ball.position, beats } };
}

/// Case 6: what events cost by source (step 23). A playhead plays 10 s at 60 Hz from 3 s, and each
/// frame reads the events of a window 3 s behind it to 3 s ahead, then evaluates at it, on a
/// reader with checkpoints: `events` of the pure program, `events` of the same with one chase,
/// which steps the whole window back and forth each frame, and `events_of` the bounce and the
/// cues beside the chase, which steps nothing but the frame's own eval. A fourth line is that
/// eval alone, so the third splits into the eval's steps and the events' own cost.
fn sources(io: std.Io) void {
    sources_cues = weft.Cues.init(&sources_cue_times);
    for (0..sources_cue_times.len) |index| {
        const half_seconds: i64 = @intCast(index);
        _ = sources_cues.add(.{ .flicks = half_seconds * @divExact(flicks_per_second, 2) }) catch
            unreachable;
    }
    const rate = weft.Rate.from_hz(60).?;
    const frame_first = 3 * 60;
    const frames = 600;
    const window = 3 * flicks_per_second;
    const Read = enum { events, events_of, none };
    const cases = [_]struct { label: []const u8, chase: bool, read: Read }{
        .{ .label = "sources events, pure, per frame", .chase = false, .read = .events },
        .{ .label = "sources events, with a chase", .chase = true, .read = .events },
        .{ .label = "sources events_of, with a chase", .chase = true, .read = .events_of },
        .{ .label = "sources eval alone, with a chase", .chase = true, .read = .none },
    };
    for (cases) |case| {
        const page = sources_page(case.chase);
        var best: i96 = std.math.maxInt(i96);
        var total: f64 = 0;
        for (0..repeats) |_| {
            var state = weft.State.init_with_checkpoints(page.program, &slab, &checkpoints);
            const start = now(io);
            for (frame_first..frame_first + frames) |frame| {
                const at = weft.Time.from_ticks(@intCast(frame), rate).?;
                const t0: weft.Time = .{ .flicks = at.flicks - window };
                const t1: weft.Time = .{ .flicks = at.flicks + window };
                const found: weft.Events = switch (case.read) {
                    .events => state.events(t0, t1, &events_out),
                    .events_of => state.events_of(&page.sources, t0, t1, &events_out),
                    .none => .{ .count = 0, .dropped = 0 },
                };
                assert(found.dropped == 0);
                state.eval(at);
                total += @as(f64, @floatFromInt(found.count)) + state.value(page.sources[0]);
            }
            best = @min(best, now(io) - start);
        }
        report(case.label, best, frames, total);
    }
}

/// Case 5: the chase page with its springs' time from a track, played at 60 Hz to 600 s, then for
/// 10 s a write of the track at the playhead every frame, and the frame's eval, per frame.
fn write(io: std.Io) void {
    start_cues = weft.Cues.init(&start_times);
    _ = start_cues.add(.{ .flicks = 0 }) catch |err| fail(err);
    var best: i96 = std.math.maxInt(i96);
    var total: f64 = 0;
    const rate = weft.Rate.from_hz(60).?;
    const frames = 600;
    for (0..repeats) |_| {
        tracks = weft.Tracks.init(&track_entries);
        const id = tracks.add(&track_samples, 0.1, 1, 0.4) catch |err| fail(err);
        var builder = weft.Builder.init(&nodes, .{
            .slab_count_max = slab_max,
            .cues = &start_cues,
            .tracks = &tracks,
        });
        const wave = builder.wave(.{ .shape = .sine, .hz = 0.5 }) catch |err| fail(err);
        const smooth: weft.Noise = .{ .shape = .smooth, .hz = 1, .seed = 1 };
        const noise = builder.noise(smooth) catch |err| fail(err);
        const target = builder.add(wave, noise) catch |err| fail(err);
        const time = builder.track(id) catch |err| fail(err);
        var outputs: [4]weft.Id = undefined;
        for (&outputs, 0..) |*output, index| {
            output.* = builder.chase(.{
                .target = target,
                .from = 0,
                .time = .{ .flicks = @divExact(flicks_per_second, 2) },
                .overshoot = 0.05 * @as(f64, @floatFromInt(index)),
                .time_from = time,
            }) catch |err| fail(err);
        }
        const program = builder.finish();
        var state = weft.State.init_with_checkpoints(program, &slab, &checkpoints);
        var frame: i64 = 0;
        while (frame <= 600 * 60) : (frame += 1) state.eval(weft.Time.from_ticks(frame, rate).?);
        const start = now(io);
        for (0..frames) |index| {
            const at = weft.Time.from_ticks(frame, rate).?;
            const value = 0.2 + 0.1 * @as(f64, @floatFromInt(index % 5));
            tracks.write(id, at, value) catch |err| fail(err);
            state.eval(at);
            for (outputs) |output| total += state.value(output);
            frame += 1;
        }
        best = @min(best, now(io) - start);
    }
    report("write   a track write at 600 s, per frame", best, frames, total);
}

/// A builder refusal here is a mistake in the case, named in every build mode.
/// Play's signal table as text, passed in by `build.zig`.
const play_signals = @embedFile("play_signals");

var compiled: weft.lang.Compiled(.{
    .tokens = 1024,
    .tree = 512,
    .names = 64,
    .nodes = 24,
    .slab = 112,
    .cues = 6,
    .goals = 3,
    .regions = 4,
    .tracks = 4,
    .track_samples = 16,
}) = undefined;

/// Case 6: Play's file compiled from its bytes to its program, per compile.
fn compile(io: std.Io) void {
    const count = 2000;
    var best: i96 = std.math.maxInt(i96);
    var total: f64 = 0;
    for (0..repeats) |_| {
        const start = now(io);
        for (0..count) |_| {
            compiled.compile(play_signals) catch |err| fail(err);
            total += @floatFromInt(compiled.program.nodes.len);
        }
        best = @min(best, now(io) - start);
    }
    report("compile Play's signals.weft, per compile", best, count, total);
}

/// A binary tree of modules 8 deep (step 13): each level calls the one below it twice, so a
/// compile expands 511 instances into 768 nodes, with the argument shared as one wave.
const nested =
    "module m0(x) = x * 0.5\n" ++
    "module m1(x) = m0(x) + m0(x)\n" ++
    "module m2(x) = m1(x) + m1(x)\n" ++
    "module m3(x) = m2(x) + m2(x)\n" ++
    "module m4(x) = m3(x) + m3(x)\n" ++
    "module m5(x) = m4(x) + m4(x)\n" ++
    "module m6(x) = m5(x) + m5(x)\n" ++
    "module m7(x) = m6(x) + m6(x)\n" ++
    "module m8(x) = m7(x) + m7(x)\n" ++
    "out = m8(wave(sine, 1hz))\n";

var nested_compiled: weft.lang.Compiled(.{
    .tokens = 1024,
    .tree = 4096,
    .names = 64,
    .nodes = 1024,
    .slab = 2048,
    .cues = 2,
    .goals = 2,
    .regions = 2,
    .tracks = 1,
    .track_samples = 1,
    .modules = 16,
}) = undefined;

/// Case 7: the nested patch compiled, per compile. The sum is the node count.
fn modules(io: std.Io) void {
    const count = 200;
    var best: i96 = std.math.maxInt(i96);
    var total: f64 = 0;
    for (0..repeats) |_| {
        const start = now(io);
        for (0..count) |_| {
            nested_compiled.compile(nested) catch |err| fail(err);
            total += @floatFromInt(nested_compiled.program.nodes.len);
        }
        best = @min(best, now(io) - start);
    }
    report("compile 8 deep of modules, per compile", best, count, total);
}

/// Case 8: a region of `count` lanes, as a dataviz page would have, read at 60 Hz for 10 s from
/// 0: each frame an eval and a sum over every bar, then the frame's events in another reader.
fn lanes(io: std.Io, count: u32) void {
    start_cues = weft.Cues.init(&start_times);
    _ = start_cues.add(.{ .flicks = 0 }) catch |err| fail(err);
    var builder = weft.Builder.init(&nodes, .{ .slab_count_max = lanes_slab.len, .cues = &start_cues });
    builder.lanes = count;
    const ms: i64 = @divExact(flicks_per_second, 1000);
    const noise = builder.noise(.{ .shape = .smooth, .hz = 0.25, .seed = 3 }) catch |err| fail(err);
    const rise = builder.tween(.{
        .from = 0,
        .to = 1,
        .duration = .{ .flicks = 600 * ms },
        .ease = weft.Ease.out,
        .start = .{ .index = 0 },
        .previous = null,
        .stagger = .{ .flicks = 2 * ms },
    }) catch |err| fail(err);
    const height = builder.map_range(.{ .input = noise, .input_low = -1, .input_high = 1, .output_low = 0.2, .output_high = 1 }) catch |err| fail(err);
    const bars = builder.multiply(rise, height) catch |err| fail(err);
    _ = builder.bounce(.{ .low = 0, .high = 1, .speed = 0.5, .start = .{ .index = 0 }, .stagger = .{ .flicks = ms } }) catch |err| fail(err);
    const program = builder.finish();
    assert(program.slab_count <= lanes_slab.len);
    const rate = weft.Rate.from_hz(60).?;
    const frames = 600;
    var best_eval: i96 = std.math.maxInt(i96);
    var best_events: i96 = std.math.maxInt(i96);
    var total: f64 = 0;
    var found_total: f64 = 0;
    for (0..repeats) |_| {
        var state = weft.State.init(program, lanes_slab[0..program.slab_count]);
        var spent: i96 = 0;
        for (0..frames) |frame| {
            const start = now(io);
            state.eval(weft.Time.from_ticks(@intCast(frame), rate).?);
            for (state.values(bars)) |value| total += value;
            spent += now(io) - start;
        }
        best_eval = @min(best_eval, spent);
        var reader = weft.State.init(program, lanes_slab[0..program.slab_count]);
        spent = 0;
        for (0..frames) |frame| {
            const t0 = weft.Time.from_ticks(@intCast(frame), rate).?;
            const t1 = weft.Time.from_ticks(@intCast(frame + 1), rate).?;
            const start = now(io);
            const found = reader.events(t0, t1, &lanes_events);
            spent += now(io) - start;
            found_total += @floatFromInt(found.count + found.dropped);
        }
        best_events = @min(best_events, spent);
    }
    var label_buffer: [64]u8 = undefined;
    const eval_label = std.fmt.bufPrint(&label_buffer, "lanes   {d} lanes, eval per frame", .{count}) catch unreachable;
    report(eval_label, best_eval, frames, total);
    const events_label = std.fmt.bufPrint(&label_buffer, "lanes   {d} lanes, events per frame", .{count}) catch unreachable;
    report(events_label, best_events, frames, found_total);
}

/// The ops of case 9, each 64 nodes of a program of its own.
const Kind = enum { constant, add, multiply, map, abs, min, max, sin, cos, exp, ln, sqrt, floor, round, pow, wave, noise, tween, spring, newtonian, bounce, cues, track, chase, follow, shift, delay, crossing, oscillator };

var kind_goal_entries: [2]weft.Goal = undefined;
var kind_region_entries: [1]weft.Region = undefined;
var kind_cue_times: [2]weft.Time = undefined;
var kind_slab: [64 * 16]f64 = undefined;
var kind_checkpoints: [16 * 64 * 16]f64 = undefined;
var kind_nodes: [160]weft.Node = undefined;

/// The program of `kind`: a wave as the input where the op reads one, then 64 of the op.
fn kind_program(kind: Kind) weft.Program {
    var cues = &start_cues;
    cues.* = weft.Cues.init(&kind_cue_times);
    const c0 = cues.add(.{ .flicks = 0 }) catch |err| fail(err);
    const c1 = cues.add(seconds(2)) catch |err| fail(err);
    var goals = weft.Goals.init(&kind_goal_entries);
    const path = goals.add(&.{ .{ .cue = c0, .value = 1 }, .{ .cue = c1, .value = -1 } }) catch |err| fail(err);
    var regions = weft.Regions.init(&kind_region_entries);
    const span = regions.add(&.{.{ .low = 0, .high = 1 }}) catch |err| fail(err);
    tracks = weft.Tracks.init(&track_entries);
    const track_id = tracks.add(&track_samples, 0, 1, 0.5) catch |err| fail(err);
    var builder = weft.Builder.init(&kind_nodes, .{
        .slab_count_max = kind_slab.len,
        .cues = cues,
        .goals = goals.table(),
        .regions = regions.table(),
        .tracks = &tracks,
    });
    const input = builder.wave(.{ .shape = .sine, .hz = 0.5 }) catch |err| fail(err);
    // The second operand of `min` and `max`, so half of a wave's values pass each way. Only
    // their programs have it, so every other op's is as it was.
    const half = if (kind == .min or kind == .max) builder.constant(0) catch |err| fail(err) else input;
    // `ln` and `sqrt` of the wave moved into [0.5, 2], so the cost is of their series, not of the
    // held value below 0. Only their programs have it.
    const positive = if (kind == .ln or kind == .sqrt) builder.map_range(.{ .input = input, .input_low = -1, .input_high = 1, .output_low = 0.5, .output_high = 2 }) catch |err| fail(err) else input;
    const ms: i64 = @divExact(flicks_per_second, 1000);
    for (0..64) |index| {
        const seed: u64 = index;
        _ = switch (kind) {
            .constant => builder.constant(@floatFromInt(index)),
            .add => builder.add(input, input),
            .multiply => builder.multiply(input, input),
            .map => builder.map_range(.{ .input = input, .input_low = -1, .input_high = 1, .output_low = 0, .output_high = 1 }),
            .abs => builder.apply(.abs, input),
            .sin => builder.apply(.sin, input),
            .cos => builder.apply(.cos, input),
            .exp => builder.apply(.exp, input),
            .ln => builder.apply(.ln, positive),
            .sqrt => builder.apply(.sqrt, positive),
            .floor => builder.apply(.floor, input),
            .round => builder.apply(.round, input),
            .pow => builder.apply(.{ .pow = 3 }, input),
            .min => builder.minimum(input, half),
            .max => builder.maximum(input, half),
            .wave => builder.wave(.{ .shape = .triangle, .hz = 1 + 0.1 * @as(f64, @floatFromInt(index)) }),
            .noise => builder.noise(.{ .shape = .smooth, .hz = 1, .seed = seed }),
            .tween => builder.tween(.{ .from = 0, .to = 1, .duration = seconds(3), .ease = weft.Ease.in_out, .start = c0, .previous = null }),
            .spring => builder.spring(.{ .from = 0, .goals = path, .time = .{ .flicks = 500 * ms }, .overshoot = 0.2 }),
            .newtonian => builder.newtonian(.{ .from = 0, .goals = path, .speed = 2, .accel = 8, .decel = 4 }),
            .bounce => (builder.bounce(.{ .low = 0, .high = 1, .speed = 0.7, .start = c0 }) catch |err| fail(err)).position,
            .cues => builder.cues(.{ .first = c0, .count = 2 }),
            .track => builder.track(track_id),
            .chase => builder.chase(.{ .target = input, .from = 0, .time = .{ .flicks = 300 * ms }, .overshoot = 0.1 }),
            .follow => builder.follow(.{
                .from = 0,
                .regions = span,
                .pick = .random,
                .mover = .{ .spring = .{ .time = .{ .flicks = 300 * ms }, .overshoot = 0.1 } },
                .tolerance = 0.01,
                .pause_min = .{ .flicks = 0 },
                .pause_max = .{ .flicks = 200 * ms },
                .seed = seed,
            }),
            .shift => builder.shift(.{ .buckets = 8, .period = seconds(2), .low = -1, .high = 1, .odds = 0.25, .shape = .smooth, .seed = seed }),
            .delay => delay: {
                const id = builder.delay(0) catch |err| fail(err);
                builder.close(id, input) catch |err| fail(err);
                break :delay id;
            },
            .crossing => builder.crossing(.{ .input = input, .level = 0.25, .direction = .both }),
            .oscillator => builder.oscillator(.{ .shape = .sine, .rate = input }),
        } catch |err| fail(err);
    }
    return builder.finish();
}

/// Case 9: each op's cost a node, 64 nodes of it playing forwards at 60 Hz for 10 s, less a
/// program of only the input wave. A simulated op's cost includes its eight steps a frame.
fn per_node(io: std.Io) void {
    const rate = weft.Rate.from_hz(60).?;
    const frames = 600;
    for (std.enums.values(Kind)) |kind| {
        const program = kind_program(kind);
        var best: i96 = std.math.maxInt(i96);
        var total: f64 = 0;
        for (0..repeats) |_| {
            var state = weft.State.init_with_checkpoints(program, kind_slab[0..program.slab_count], &kind_checkpoints);
            const start = now(io);
            for (0..frames) |frame| {
                state.eval(weft.Time.from_ticks(@intCast(frame), rate).?);
                total += state.slab[program.slab_count - 1];
            }
            best = @min(best, now(io) - start);
        }
        var label_buffer: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buffer, "node    {t}, per node a frame", .{kind}) catch unreachable;
        report(label, best, frames * 64, total);
    }
}

var seek_compiled: @TypeOf(compiled) = undefined;
var seek_slab: [112]f64 = undefined;
var seek_checkpoints: [610 * 112]f64 = undefined;

/// Case 10: Play's file on a reader with checkpoints, read at 600 s, then at 300.99 s: a restore
/// and the second of steps after it, a seek's worst case.
fn seek(io: std.Io) void {
    seek_compiled.compile(play_signals) catch |err| fail(err);
    const program = seek_compiled.program;
    var best: i96 = std.math.maxInt(i96);
    var total: f64 = 0;
    for (0..repeats) |_| {
        var state = weft.State.init_with_checkpoints(program, seek_slab[0..program.slab_count], &seek_checkpoints);
        state.eval(seconds(600));
        const start = now(io);
        // Just before 301 s: the checkpoint at 300 s, then 475 steps, the most a seek runs.
        state.eval(.{ .flicks = 300 * flicks_per_second + @divExact(99 * flicks_per_second, 100) });
        best = @min(best, now(io) - start);
        total += state.slab[0];
    }
    report("seek    600 s back to 300.99 s, per read", best, 1, total);
}

var recompiled: @TypeOf(compiled) = undefined;
var recompiled_slab: [112]f64 = undefined;
var recompiled_checkpoints: [610 * 112]f64 = undefined;
var edited: [8192]u8 = undefined;

/// Case 11: Play's file at 600 s, then the same file with the first tween's `over` changed, a
/// pure line no simulated node reads: the compile, the carry of the reader, and the first eval.
fn recompile(io: std.Io) void {
    const from = "rise = tween(from: 0, to: 1, at: c1, over: 1s,";
    const to = "rise = tween(from: 0, to: 1, at: c1, over: 2s,";
    const at = std.mem.indexOf(u8, play_signals, from) orelse fail(error.EditNotFound);
    @memcpy(edited[0..play_signals.len], play_signals);
    @memcpy(edited[at..][0..to.len], to);
    const text = edited[0..play_signals.len];
    var best: i96 = std.math.maxInt(i96);
    var total: f64 = 0;
    for (0..repeats) |_| {
        seek_compiled.compile(play_signals) catch |err| fail(err);
        var old_state = weft.State.init_with_checkpoints(seek_compiled.program, seek_slab[0..seek_compiled.program.slab_count], &seek_checkpoints);
        old_state.eval(seconds(600));
        const start = now(io);
        recompiled.compile(text) catch |err| fail(err);
        const program = recompiled.program;
        var state = weft.State.init_with_checkpoints(program, recompiled_slab[0..program.slab_count], &recompiled_checkpoints);
        if (!recompiled.carry(&state, &seek_compiled, &old_state)) fail(error.NotCarried);
        state.eval(.{ .flicks = 600 * flicks_per_second + 11_760_000 });
        best = @min(best, now(io) - start);
        total += state.slab[0];
    }
    report("recomp  a pure edit at 600 s, carried", best, 1, total);
}

/// Play's lanes page as text, passed in by `build.zig`.
const play_lanes = @embedFile("play_lanes");

var audio_compiled: weft.lang.Compiled(.{
    .tokens = 1024,
    .tree = 512,
    .names = 64,
    .nodes = 24,
    .slab = 16384,
    .cues = 6,
    .goals = 3,
    .regions = 4,
    .tracks = 4,
    .track_samples = 16,
}) = undefined;
var audio_slab: [16384]f64 = undefined;
var audio_checkpoints: [16 * 112]f64 = undefined;
var audio_events: [1024]weft.Event = undefined;

const Audio = struct {
    program: weft.Program,
    io: std.Io,
    worst: i96 = 0,
    over: u32 = 0,
    blocks: u32 = 0,
    total: f64 = 0,
};

/// One block of 128 frames at 48 kHz, exactly 1,881,600 flicks and 8/3 ms.
const block_flicks: i64 = 1_881_600;
const block_ns: i96 = 8_000_000 / 3;

/// The audio thread: from a fresh reader, a block's events and an eval at its end every
/// `block_ns` of wall time for 5 s, each block's work timed and the thread asleep until the next
/// is due. A block that ends past its deadline is over budget.
fn audio_thread(run: *Audio) void {
    var state = weft.State.init_with_checkpoints(run.program, audio_slab[0..run.program.slab_count], audio_checkpoints[0..if (run.program.simulated) audio_checkpoints.len else 0]);
    const begin = now(run.io);
    var t0: i64 = 0;
    while (run.blocks < 1875) : (run.blocks += 1) {
        const due = begin + @as(i96, run.blocks) * block_ns;
        const wait = due - now(run.io);
        if (wait > 0) run.io.sleep(.fromNanoseconds(wait), .awake) catch {};
        const start = now(run.io);
        const found = state.events(.{ .flicks = t0 }, .{ .flicks = t0 + block_flicks }, &audio_events);
        state.eval(.{ .flicks = t0 + block_flicks });
        const spent = now(run.io) - start;
        run.worst = @max(run.worst, spent);
        if (spent > block_ns) run.over += 1;
        run.total += @floatFromInt(found.count + found.dropped);
        run.total += state.slab[0];
        t0 += block_flicks;
    }
}

/// Case 12: `audio_thread` over `text`, compiled here, on a thread of its own.
fn audio(io: std.Io, name: []const u8, text: []const u8) void {
    audio_compiled.compile(text) catch |err| fail(err);
    var run: Audio = .{ .program = audio_compiled.program, .io = io };
    const thread = std.Thread.spawn(.{}, audio_thread, .{&run}) catch |err| fail(err);
    thread.join();
    var label_buffer: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buffer, "audio   {s}, worst block", .{name}) catch unreachable;
    report(label, run.worst, 1, run.total);
    const per_node_ns = @divFloor(run.worst, @as(i96, @intCast(run.program.nodes.len)));
    std.debug.print("        {d} blocks, {d} over 2.667 ms, worst {d} ns a node of {d}\n", .{
        run.blocks,
        run.over,
        per_node_ns,
        run.program.nodes.len,
    });
}

fn fail(err: anyerror) noreturn {
    std.debug.panic("bench: a case failed to build: {t}", .{err});
}

/// One line: the case, the time per unit in a readable unit, and the sum that keeps it honest.
fn report(label: []const u8, nanoseconds: i96, units: u64, total: f64) void {
    assert(nanoseconds >= 0);
    assert(units > 0);
    const per: f64 = @as(f64, @floatFromInt(nanoseconds)) / @as(f64, @floatFromInt(units));
    const unit: []const u8, const scaled: f64 = if (per >= 1e6)
        .{ "ms", per / 1e6 }
    else if (per >= 1e3)
        .{ "us", per / 1e3 }
    else
        .{ "ns", per };
    std.debug.print("{s:<40} {d:>9.1} {s}   (sum {e:.3})\n", .{ label, scaled, unit, total });
}
