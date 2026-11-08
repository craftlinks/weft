//! A recompile's carry (step 15) against a fresh reader: a reader that keeps its state across an
//! edit reads exactly what a reader of the new program started from nothing reads.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Claim
//! `Compiled.carry` is only an optimisation: it must never change a value. So each test compiles
//! a file, runs a reader of it some way, edits the file, carries the reader into the new program,
//! and compares it bit for bit with a fresh reader of the new program, forwards, backwards
//! across checkpoints, and past where the old reader had been.
//!
//! ## 2. When It Refuses
//! An edit to a simulated declaration, or to anything it reads, makes its history a new one, so
//! the carry refuses and the reader starts fresh; so does a file that feeds a delay.

const std = @import("std");
const testing = std.testing;
const weft = @import("weft");

const limits: weft.lang.Limits = .{
    .tokens = 1024,
    .tree = 512,
    .names = 64,
    .nodes = 64,
    .slab = 256,
    .cues = 8,
    .goals = 16,
    .regions = 8,
    .tracks = 4,
    .track_samples = 64,
};
const Compiled = weft.lang.Compiled(limits);
const checkpoint_seconds = 64;

const Reader = struct {
    slab: [limits.slab]f64,
    checkpoints: [checkpoint_seconds * limits.slab]f64,
    state: weft.State,

    fn start(reader: *Reader, program: weft.Program) void {
        const size = program.slab_count;
        reader.state = .init_with_checkpoints(program, reader.slab[0..size], reader.checkpoints[0 .. checkpoint_seconds * size]);
    }
};

var old_file: Compiled = undefined;
var new_file: Compiled = undefined;
var old_reader: Reader = undefined;
var carried: Reader = undefined;
var fresh: Reader = undefined;

const base =
    \\seed 7
    \\cue c0 = 0s
    \\cue c1 = 2s
    \\track chase_s = 0.5 in 0.125..2
    \\noise = noise(smooth, 1hz, seed: 1)
    \\chase = chase(noise, time: chase_s, overshoot: 0.1)
    \\soft = follow([0..1], from: 0.5, by: spring(time: 1s), pause: 0s..1s, seed: 6)
    \\wave = wave(sine, 0.5hz)
    \\
;

fn seconds(count: f64) weft.Time {
    return .{ .flicks = @intFromFloat(@round(count * @as(f64, @floatFromInt(weft.time.flicks_per_second)))) };
}

/// Compiles both files, runs the old reader to `ran_to` seconds, and carries it into the new
/// program. Returns what `carry` returned.
fn edit(old_text: []const u8, new_text: []const u8, ran_to: f64) !bool {
    try old_file.compile(old_text);
    try new_file.compile(new_text);
    old_reader.start(old_file.program);
    var at: f64 = 0;
    while (at <= ran_to) : (at += 0.25) old_reader.state.eval(seconds(at));
    carried.start(new_file.program);
    fresh.start(new_file.program);
    return new_file.carry(&carried.state, &old_file, &old_reader.state);
}

/// The carried and the fresh reader read the same bits for each of `names` at every time.
fn expect_same_reads(names: []const []const u8, times: []const f64) !void {
    for (times) |at| {
        carried.state.eval(seconds(at));
        fresh.state.eval(seconds(at));
        for (names) |name| {
            const id = new_file.signal(name).?;
            const a = carried.state.value(id);
            const b = fresh.state.value(id);
            if (@as(u64, @bitCast(a)) != @as(u64, @bitCast(b))) {
                std.debug.print("{s} at {d} s: carried {d}, fresh {d}\n", .{ name, at, a, b });
                return error.TestUnexpectedResult;
            }
        }
    }
}

const simulated_names: []const []const u8 = &.{ "chase", "soft" };
const probe_times: []const f64 = &.{ 30, 30.5, 31, 45, 12, 3, 0.75, 40, 59.5 };

// Locks section 1: an edit to a pure line, a new line above the simulated ones, and a comment
// carry the reader, which then reads what a fresh reader reads, and has run far fewer steps.
test "a carried reader reads what a fresh reader reads" {
    const edited =
        \\seed 7
        \\cue c0 = 0s
        \\cue c1 = 2s
        \\track chase_s = 0.5 in 0.125..2
        \\extra = wave(saw, 3hz) * 2 # a new line, so every later node moves
        \\noise = noise(smooth, 1hz, seed: 1)
        \\chase = chase(noise, time: chase_s, overshoot: 0.1)
        \\soft   =   follow([0..1], from: 0.5, by: spring(time: 1s), pause: 0s..1s, seed: 6)
        \\wave = wave(sine, 2hz)
        \\
    ;
    try testing.expect(try edit(base, edited, 30));
    carried.state.eval(seconds(30));
    try testing.expect(carried.state.steps_run < 1000);
    try expect_same_reads(simulated_names, probe_times);
    try expect_same_reads(&.{ "wave", "extra" }, probe_times);
}

// Locks section 2: an edit to a simulated line, or to the noise a chase reads, starts fresh.
test "an edit to a simulated declaration or its input starts fresh" {
    const chase_edit = try std.mem.replaceOwned(u8, testing.allocator, base, "overshoot: 0.1", "overshoot: 0.2");
    defer testing.allocator.free(chase_edit);
    try testing.expect(!try edit(base, chase_edit, 10));
    const noise_edit = try std.mem.replaceOwned(u8, testing.allocator, base, "seed: 1", "seed: 2");
    defer testing.allocator.free(noise_edit);
    try testing.expect(!try edit(base, noise_edit, 10));
    const track_edit = try std.mem.replaceOwned(u8, testing.allocator, base, "0.5 in", "0.75 in");
    defer testing.allocator.free(track_edit);
    try testing.expect(!try edit(base, track_edit, 10));
    try expect_same_reads(simulated_names, probe_times);
}

// Locks section 2: a file that feeds a delay never carries.
test "a file with a delay never carries" {
    const looped = base ++ "fb = delay(0)\nloop = chase(1 + fb * -0.8, time: 0.5s)\nfb <- loop\n";
    try testing.expect(!try edit(looped, looped ++ "# a comment\n", 10));
}

// Locks `carry_tracks`: a write to a track survives an edit, and one outside new bounds does not.
test "a track's writes survive a recompile" {
    try old_file.compile(base);
    try new_file.compile(base);
    const old_track = old_file.track("chase_s").?;
    try old_file.tables.tracks.write(old_track, seconds(5), 1.5);
    try old_file.tables.tracks.write(old_track, seconds(8), 0.25);
    new_file.carry_tracks(&old_file);
    const track = new_file.track("chase_s").?;
    try testing.expectEqual(@as(f64, 0.5), new_file.tables.tracks.value(track, seconds(4)));
    try testing.expectEqual(@as(f64, 1.5), new_file.tables.tracks.value(track, seconds(6)));
    try testing.expectEqual(@as(f64, 0.25), new_file.tables.tracks.value(track, seconds(9)));
    const narrow = try std.mem.replaceOwned(u8, testing.allocator, base, "0.125..2", "0.125..1");
    defer testing.allocator.free(narrow);
    try new_file.compile(narrow);
    new_file.carry_tracks(&old_file);
    try testing.expectEqual(@as(f64, 0.5), new_file.tables.tracks.value(new_file.track("chase_s").?, seconds(6)));
    try testing.expectEqual(@as(f64, 0.25), new_file.tables.tracks.value(new_file.track("chase_s").?, seconds(9)));
}
