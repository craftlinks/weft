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
//! write    the chase page with its springs' time from a track,  per frame, at 600 s
//!          a write of the track at the playhead, then the eval
//! compile  Play's `signals.weft` (step 12), parse to program      per compile
//! modules  a patch of modules nested 8 deep, 511 instances           per compile
//! lanes    a noise, a staggered tween, a map, a product, and a      per frame, at 1,000 and
//!          staggered bounce over n lanes: an eval, then the events  100,000 lanes
//! ```
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
    write(io);
    compile(io);
    modules(io);
    lanes(io, 1_000);
    lanes(io, 100_000);
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
