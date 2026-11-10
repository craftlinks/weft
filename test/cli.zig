//! The weft command's output against its goldens (step 14), and a client's nouns. Each command
//! writes the bytes a person or an agent reads; the goldens in test/golden/cli are those bytes,
//! reviewed once and locked.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why Goldens
//! The output is the contract an agent reads, so a change to it is a change to a golden, in the
//! same commit, with the reason. Nothing is compared by meaning: the bytes are the test.
//!
//! ## 2. Inputs
//! Every input is inline or the standard library, which is embedded in the library, so the tests
//! read no file and need no working directory.
//!
//! ## 3. A Client's Nouns
//! A fake client registers `dot`, which the checker accepts beside the primitives and Weft's back
//! end refuses; the client then finds its calls in `checked`, with their values, as a real
//! client's back end would.

const std = @import("std");
const testing = std.testing;
const weft = @import("weft");
const commands = @import("commands");

const describe_golden = @embedFile("golden/cli/describe.json");
const parse_golden = @embedFile("golden/cli/parse.json");
const check_golden = @embedFile("golden/cli/check_errors.txt");
const check_ok_golden = @embedFile("golden/cli/check_ok.txt");
const sample_golden = @embedFile("golden/cli/sample.json");
const sample_filtered_golden = @embedFile("golden/cli/sample_filtered.json");

const sequence =
    \\seed 7
    \\cue c0 = 0s
    \\cue c1 = 1s
    \\moves = [c1: 1]
    \\out = spring(moves, time: 0.5s, overshoot: 0.2)
    \\
;

const std_library: []const weft.lang.Source = &.{.{ .name = "std", .text = weft.lang.std_library }};

var output: [1 << 18]u8 = undefined;
var compiled: commands.Compiled = undefined;

// Locks the describe output: every primitive with its parameters, then the standard library's
// modules with their defaults and bodies, and no nouns.
test "describe lists the primitives and the standard library's modules" {
    var writer: std.Io.Writer = .fixed(&output);
    try commands.describe(&writer, std_library, &.{});
    try testing.expectEqualStrings(describe_golden, writer.buffered());
}

// Locks the flat tree of a five-line file, item by item.
test "parse writes the flat tree of a file" {
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(try commands.parse(&writer, .{ .name = "sequence.weft", .text = sequence }));
    try testing.expectEqualStrings(parse_golden, writer.buffered());
}

// Locks three errors, each with its line, its caret, and its hint: a misspelt parameter, a
// missing unit, and a module cycle.
test "check reports each error with its line and hint" {
    var writer: std.Io.Writer = .fixed(&output);
    const bad =
        \\n = noise(smooth, 1hz)
        \\c = chase(n, tme: 1s)
        \\d = wave(sine, 1)
        \\module a(x) = b(x)
        \\module b(x) = a(x)
        \\e = a(1)
        \\f = oklab(0.5, 0, 0) * oklab(0.5, 0, 0)
        \\module p(q, q) = q
        \\g = p(1, 2)
        \\cue late = 2s
        \\cue early = 1s
        \\h = tween(from: 0, to: 1, at: early, over: 1s)
        \\i = min(1, 2)
        \\
    ;
    try testing.expect(!try commands.check(&compiled, &writer, .{ .name = "bad.weft", .text = bad }, &.{}));
    try testing.expectEqualStrings(check_golden, writer.buffered());
}

// Locks the summary of a file that compiles, with a library: its nodes, its slab, cues, goals,
// regions, and tracks, and
// whether it is seekable and stepped.
test "check summarises a file that compiles" {
    var writer: std.Io.Writer = .fixed(&output);
    const text = sequence ++ "b = breathe(out, 0.1)\nf = follow([0..1], by: spring(time: 0.3s), seed: 2)\nuse std\n";
    try testing.expect(try commands.check(&compiled, &writer, .{ .name = "ok.weft", .text = text }, std_library));
    try testing.expectEqualStrings(check_ok_golden, writer.buffered());
}

// Locks the sample output: a spring's range and its value every 0.5 s over 2 s.
test "sample writes each signal over the window, and its events" {
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "sequence.weft", .text = sequence }, &.{}, &.{"out"}, .{
        .from = 0,
        .to = 1_411_200_000,
        .step = 352_800_000,
    }, .{}));
    try testing.expectEqualStrings(sample_golden, writer.buffered());
}

// Locks the refusals: a name that is not a signal, and the windows the sampler cannot run.
test "sample refuses a name that is not a signal, and a window it cannot run" {
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(!try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "sequence.weft", .text = sequence }, &.{}, &.{"moves"}, .{
        .from = 0,
        .to = 705_600_000,
        .step = 70_560_000,
    }, .{}));
    try testing.expectEqualStrings("error: \"moves\" is not a signal of the file\n", writer.buffered());
    const second = 705_600_000;
    try testing.expect(!(commands.Window{ .from = 0, .to = second, .step = 0 }).valid());
    try testing.expect(!(commands.Window{ .from = second, .to = 0, .step = 1 }).valid());
    try testing.expect(!(commands.Window{ .from = 0, .to = second, .step = 1 }).valid());
    try testing.expect((commands.Window{ .from = 0, .to = 0, .step = 1 }).valid());
}

const dot_noun: weft.lang.schema.Entry = .{
    .name = "dot",
    .op = .client,
    .role = .signal,
    .params = &.{
        .{ .name = "at", .kind = .signal, .positional = true },
        .{ .name = "size", .kind = .number, .default = .{ .number = 1 } },
    },
    .summary = "a client's own noun",
};

// Locks section 3: the noun is checked, Weft's back end refuses it, and the client finds its
// call and its value; describe lists it among the nouns.
test "a client's noun is checked beside the primitives and refused by the back end" {
    const clients = [_]weft.lang.schema.Entry{dot_noun};
    try testing.expectError(error.Invalid, compiled.compile_client(&clients, &.{}, "out = dot(wave(sine, 1hz), size: 2)\n"));
    try testing.expectEqual(weft.lang.diagnostic.Code.refused, compiled.errors()[0].code);
    var found: usize = 0;
    for (compiled.checked.calls, 0..) |call, at| {
        if (call.entry.op != .client) continue;
        try testing.expectEqualStrings("dot", call.entry.name);
        try testing.expectEqual(@as(f64, 2), compiled.checked.call_values(@intCast(at))[1].number);
        found += 1;
    }
    try testing.expectEqual(@as(usize, 1), found);

    var writer: std.Io.Writer = .fixed(&output);
    try commands.describe(&writer, &.{}, &clients);
    const nouns = std.mem.indexOf(u8, writer.buffered(), "\"nouns\":[{\"name\":\"dot\",\"role\":\"signal\",\"op\":\"client\"").?;
    try testing.expect(nouns > 0);
}

/// A file with a library, a module, cues, goals, a region, a track, and lanes, for the least
/// `Limits` that `check` prints (step 22).
const least_source =
    \\use std
    \\cue c0 = 0s
    \\cue c1 = 1s
    \\track k = 0.5 in 0..1
    \\moves = [c1: 1]
    \\s = snappy(moves)
    \\f = follow([0..1], by: spring(time: 0.5s), seed: 2)
    \\b = lanes(4, noise(smooth, 1hz) * k)
    \\module twice(x) = x * 2
    \\t = twice(s)
    \\
;

const least_libraries: []const weft.lang.Source = &.{.{ .name = "std", .text = weft.lang.std_library }};

/// What `check` prints for `least_source`, as a `Limits`.
const least: weft.lang.Limits = .{ .tokens = 97, .tree = 47, .names = 10, .nodes = 7, .slab = 25, .cues = 2, .goals = 1, .regions = 1, .tracks = 1, .modules = 5, .libraries = 1 };

/// Whether `least_source` compiles under `limits`, each in a `Compiled` of its own.
fn compiles_with(comptime limits: weft.lang.Limits) bool {
    const Holder = struct {
        var compiled: weft.lang.Compiled(limits) = undefined;
    };
    // A caller passes at most `limits.libraries`: fewer than the file uses fails to find one.
    Holder.compiled.compile_with(least_libraries[0..limits.libraries], least_source) catch return false;
    return true;
}

// Locks step 22: the limits `check` prints are the least the file compiles with. It compiles at
// exactly them, and fails with any one of them one less.
test "check prints the least limits a file compiles with" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try testing.expect(try commands.check(&compiled, &writer, .{ .name = "least.weft", .text = least_source }, least_libraries));
    const needs = compiled.needs();
    inline for (@typeInfo(weft.lang.Limits).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "track_samples") or std.mem.eql(u8, name, "errors")) continue;
        try testing.expectEqual(@field(least, name), @field(needs, name));
    }
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "limits: .{ .tokens = 97, .tree = 47,") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "a lane costs 2 of the slab\n") != null);
    try testing.expect(compiles_with(least));
    inline for (@typeInfo(weft.lang.Limits).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "track_samples") or std.mem.eql(u8, name, "errors")) continue;
        comptime var less = least;
        @field(less, name) -= 1;
        errdefer std.debug.print("compiles with one less {s}\n", .{name});
        try testing.expect(!compiles_with(less));
    }
}

// Locks `--events` and `--lanes` (step 22): lanes 1 and 2 of a region, a signal of one lane
// whole, and only the events of `h`, of those lanes.
test "sample keeps the events and lanes asked for" {
    const text =
        \\cue c0 = 0s
        \\h = lanes(4, bounce(0..1, speed: 2, at: c0, stagger: 100ms))
        \\w = wave(sine, 1hz)
        \\x = crossing(w, level: 0)
        \\n = lanes(4, noise(smooth, 1hz))
        \\
    ;
    var writer: std.Io.Writer = .fixed(&output);
    const window: commands.Window = .{ .from = 0, .to = 705_600_000, .step = 352_800_000 };
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "filtered.weft", .text = text }, &.{}, &.{ "h", "w" }, window, .{
        .events = &.{"h"},
        .lanes = .{ 1, 2 },
    }));
    try testing.expectEqualStrings(sample_filtered_golden, writer.buffered());
}

// Locks that the command samples a file of any slab: 40,000 lanes of followers need more than
// the 262,144 values v0.1.0's command held.
test "sample runs a region larger than a fixed slab" {
    const text = "cue c0 = 0s\nf = lanes(40000, follow([0..1], by: spring(time: 0.5s), seed: 2))\n";
    var writer: std.Io.Writer = .fixed(&output);
    const window: commands.Window = .{ .from = 0, .to = 70_560_000, .step = 70_560_000 };
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "big.weft", .text = text }, &.{}, &.{"f"}, window, .{ .lanes = .{ 0, 1 } }));
    try testing.expect(compiled.program.slab_count > 1 << 18);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"lanes\":40000,\"lane_first\":0") != null);
}
