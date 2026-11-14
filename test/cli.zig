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
        \\i = print(1, 2)
        \\
    ;
    try testing.expect(!try commands.check(&compiled, &writer, .{ .name = "bad.weft", .text = bad }, &.{}, &.{}));
    try testing.expectEqualStrings(check_golden, writer.buffered());
}

// Locks the summary of a file that compiles, with a library: its nodes, its slab, cues, goals,
// regions, and tracks, and
// whether it is seekable and stepped.
test "check summarises a file that compiles" {
    var writer: std.Io.Writer = .fixed(&output);
    const text = sequence ++ "b = breathe(out, 0.1)\nf = follow([0..1], by: spring(time: 0.3s), seed: 2)\nuse std\n";
    try testing.expect(try commands.check(&compiled, &writer, .{ .name = "ok.weft", .text = text }, std_library, &.{}));
    try testing.expectEqualStrings(check_ok_golden, writer.buffered());
}

// Locks the sample output: a spring's range and its value every 0.5 s over 2 s.
test "sample writes each signal over the window, and its events" {
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "sequence.weft", .text = sequence }, &.{}, &.{}, &.{"out"}, .{
        .from = 0,
        .to = 1_411_200_000,
        .step = 352_800_000,
    }, .{}));
    try testing.expectEqualStrings(sample_golden, writer.buffered());
}

// Locks the refusals: a name that is not a signal, and the windows the sampler cannot run.
test "sample refuses a name that is not a signal, and a window it cannot run" {
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(!try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "sequence.weft", .text = sequence }, &.{}, &.{}, &.{"moves"}, .{
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

// Locks what `describe` says of a noun that only describes (step 27): its op, that its signals
// keep their own lanes, a string's kind and default, and the entries a `noun` parameter takes.
test "describe lists a describing noun with its string and noun parameters" {
    const clients = [_]weft.lang.schema.Entry{.{
        .name = "label",
        .op = .noun,
        .role = .signal,
        .params = &.{
            .{ .name = "of", .kind = .noun, .positional = true, .words = &.{ "axes", "plot" } },
            .{ .name = "text", .kind = .string, .default = .{ .text = "?" } },
        },
        .summary = "a name beside a noun",
    }};
    var writer: std.Io.Writer = .fixed(&output);
    try commands.describe(&writer, &.{}, &clients);
    const expected = "\"nouns\":[{\"name\":\"label\",\"role\":\"signal\",\"op\":\"noun\",\"summary\":\"a name beside a noun\"," ++
        "\"lanes\":\"apart\",\"events\":null,\"outputs\":[],\"params\":[" ++
        "{\"name\":\"of\",\"kind\":\"noun\",\"live\":false,\"shaped\":false,\"positional\":true,\"default\":null,\"words\":[\"axes\",\"plot\"]}," ++
        "{\"name\":\"text\",\"kind\":\"string\",\"live\":false,\"shaped\":false,\"positional\":false,\"default\":\"?\",\"words\":[]}]}]";
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), expected) != null);
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
const least: weft.lang.Limits = .{ .tokens = 142, .tree = 64, .names = 10, .nodes = 7, .slab = 25, .cues = 2, .goals = 1, .regions = 1, .tracks = 1, .modules = 7, .libraries = 1 };

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
    try testing.expect(try commands.check(&compiled, &writer, .{ .name = "least.weft", .text = least_source }, least_libraries, &.{}));
    const needs = compiled.needs();
    inline for (@typeInfo(weft.lang.Limits).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "track_samples") or std.mem.eql(u8, name, "errors")) continue;
        try testing.expectEqual(@field(least, name), @field(needs, name));
    }
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "limits: .{ .tokens = 142, .tree = 64,") != null);
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
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "filtered.weft", .text = text }, &.{}, &.{}, &.{ "h", "w" }, window, .{
        .events = &.{"h"},
        .lanes = .{ 1, 2 },
    }));
    try testing.expectEqualStrings(sample_filtered_golden, writer.buffered());
}

// Locks `--events` through `Compiled.event_sources` (step 23): a bounce in a region with no
// stagger, one bounce spread over four lanes, keeps its 5 hits in [0, 3 s), where it kept none;
// the same bounce staggered keeps 20, 5 a lane; a `vec2` spring keeps both its components' goals;
// and a crossing keeps the 3 rising crossings of a 1 Hz wave in [0, 3 s). Each event is named by
// its binding, with or without `--events`, and a source two bindings share is named by the first.
test "sample keeps the events of a spread, a pack, and a crossing" {
    const text =
        \\cue go = 0s
        \\cue c1 = 1s
        \\plain = lanes(4, bounce(0..1, speed: 2, at: go))
        \\staggered = lanes(4, bounce(0..1, speed: 2, at: go, stagger: 100ms))
        \\v = spring([go: vec2(0, 0), c1: vec2(1, 2)], time: 0.5s)
        \\w = wave(sine, 1hz)
        \\x = crossing(w, level: 0.5)
        \\
    ;
    const window: commands.Window = .{ .from = 0, .to = 2_116_800_000, .step = 705_600_000 };
    const cases = [_]struct { name: []const u8, events: usize }{
        .{ .name = "plain", .events = 5 },
        .{ .name = "staggered", .events = 20 },
        .{ .name = "v", .events = 2 },
        .{ .name = "x", .events = 3 },
    };
    for (cases) |case| {
        var writer: std.Io.Writer = .fixed(&output);
        try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "sources.weft", .text = text }, &.{}, &.{}, &.{"w"}, window, .{
            .events = &.{case.name},
        }));
        const sampled = writer.buffered();
        const events_at = std.mem.indexOf(u8, sampled, "\"events\":[").?;
        errdefer std.debug.print("{s}: {s}\n", .{ case.name, sampled[events_at..] });
        try testing.expectEqual(case.events, std.mem.count(u8, sampled[events_at..], "{\"t\":"));
        // Each named by its binding, through the spread and the pack too.
        var name_buffer: [32]u8 = undefined;
        const named = try std.fmt.bufPrint(&name_buffer, "\"name\":\"{s}\"", .{case.name});
        try testing.expectEqual(case.events, std.mem.count(u8, sampled[events_at..], named));
    }
    // Without `--events`, every event is named by its binding as well: 5 + 20 + 2 + 3.
    var all: std.Io.Writer = .fixed(&output);
    try testing.expect(try commands.sample(testing.allocator, &compiled, &all, .{ .name = "sources.weft", .text = text }, &.{}, &.{}, &.{"w"}, window, .{}));
    const every = all.buffered()[std.mem.indexOf(u8, all.buffered(), "\"events\":[").?..];
    try testing.expectEqual(@as(usize, 30), std.mem.count(u8, every, "{\"t\":"));
    try testing.expectEqual(@as(usize, 30), std.mem.count(u8, every, "\"name\":"));
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, every, "\"name\":\"plain\""));
    // Both names together keep each one's events once, in one order.
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "sources.weft", .text = text }, &.{}, &.{}, &.{"w"}, window, .{
        .events = &.{ "x", "plain", "x" },
    }));
    const sampled = writer.buffered();
    try testing.expectEqual(@as(usize, 8), std.mem.count(u8, sampled[std.mem.indexOf(u8, sampled, "\"events\":[").?..], "{\"t\":"));

    // `alias` shares `first`'s bounce, so its events are named `first`, declared first.
    const shared = "cue go = 0s\nfirst = bounce(0..1, speed: 2, at: go)\nalias = first\n";
    writer = .fixed(&output);
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "shared.weft", .text = shared }, &.{}, &.{}, &.{"first"}, window, .{
        .events = &.{"alias"},
    }));
    const aliased = writer.buffered()[std.mem.indexOf(u8, writer.buffered(), "\"events\":[").?..];
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, aliased, "\"name\":\"first\""));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, aliased, "\"name\":\"alias\""));
}

// Locks that the command samples a file of any slab: 40,000 lanes of followers need more than
// the 262,144 values v0.1.0's command held.
test "sample runs a region larger than a fixed slab" {
    const text = "cue c0 = 0s\nf = lanes(40000, follow([0..1], by: spring(time: 0.5s), seed: 2))\n";
    var writer: std.Io.Writer = .fixed(&output);
    const window: commands.Window = .{ .from = 0, .to = 70_560_000, .step = 70_560_000 };
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "big.weft", .text = text }, &.{}, &.{}, &.{"f"}, window, .{ .lanes = .{ 0, 1 } }));
    try testing.expect(compiled.program.slab_count > 1 << 18);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"lanes\":40000,\"lane_first\":0") != null);
}

/// Room for the outputs of step 38's tests, whose signals overflow `commands.values_max`.
var wide_output: [4][2 << 20]u8 = undefined;

/// The signals of a `sample` output: what lies between `"signals":[` and `],"events":[`.
fn signals_of(sampled: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, sampled, "\"signals\":[").? + "\"signals\":[".len;
    return sampled[start..std.mem.indexOf(u8, sampled, "],\"events\":[").?];
}

/// The events of a `sample` output, from `"events":[` to the end.
fn events_of(sampled: []const u8) []const u8 {
    return sampled[std.mem.indexOf(u8, sampled, "\"events\":[").?..];
}

// Locks step 38's walks, at 1024 times: `small` (1024 values) and `mid` (40 lanes, 40,960) fit
// in one walk's 65,536 values and share it, `wide` (40,960 more) takes a walk of its own, `big`
// (80 lanes, 81,920) fits in none and streams, and `b` (1,024) is the last walk. The bytes are
// the five signals sampled one at a time, spliced, and the events, read along the first walk
// and its last piece past the window's last time, are each lone run's: a follower's and a
// bounce's, 397 of them in 102.35 s, as the command before step 38 gave them.
test "sample reads its signals in one walk where they fit, in batches where not, and streams the rest" {
    const text =
        \\cue c0 = 0s
        \\f = follow([-1..1], by: spring(time: 0.3s), pause: 0s..200ms, seed: 2)
        \\small = chase(f, time: 0.2s)
        \\ramp = tween(from: 0, to: 1000, at: c0, over: 100s)
        \\mid = lanes(40, floor(ramp) + lane)
        \\wide = lanes(40, floor(ramp) - lane)
        \\big = lanes(80, floor(ramp) * lane)
        \\b = bounce(0..1, speed: 2, at: c0)
        \\
    ;
    const names = [_][]const u8{ "small", "mid", "wide", "big", "b" };
    const window: commands.Window = .{ .from = 0, .to = 1023 * 70_560_000 + 35_280_000, .step = 70_560_000 };
    try testing.expectEqual(@as(usize, 1024), window.count());
    try testing.expectEqual(@as(usize, 65_536), commands.values_max);
    var writer: std.Io.Writer = .fixed(&wide_output[0]);
    const source: commands.Source = .{ .name = "walks.weft", .text = text };
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, source, &.{}, &.{}, &names, window, .{}));
    const together = writer.buffered();
    // The same signals one at a time, spliced.
    var spliced: std.Io.Writer = .fixed(&wide_output[1]);
    try spliced.print("{{\"from\":0,\"to\":{d},\"step\":70560000,\"signals\":[", .{window.to});
    var events_alone: []const u8 = "";
    for (names, 0..) |name, at| {
        var alone: std.Io.Writer = .fixed(&wide_output[2 + at % 2]);
        try testing.expect(try commands.sample(testing.allocator, &compiled, &alone, source, &.{}, &.{}, &.{name}, window, .{}));
        if (at > 0) try spliced.writeAll(",");
        try spliced.writeAll(signals_of(alone.buffered()));
        if (at > 0) try testing.expectEqualStrings(events_alone, events_of(alone.buffered()));
        events_alone = events_of(alone.buffered());
    }
    try spliced.writeAll("],");
    try spliced.writeAll(events_alone);
    try testing.expectEqualStrings(spliced.buffered(), together);
    try testing.expectEqual(@as(usize, 397), std.mem.count(u8, events_of(together), "{\"t\":"));
}

// Locks that step 38's events, read in pieces along the walk, are what one query of the window
// gives, whatever the step: a bounce of speed 2 hits at 0.5 s and at 1 s in [0, 1.25 s), each
// once, the second in the last piece, past the last time; 64 lanes of a fast bounce overflow the
// 1024 kept, which are the earliest; and a crossing of a follower, which steps, keeps its own
// with `--events`.
test "sample's events are the window's, whatever its step" {
    const text =
        \\cue c0 = 0s
        \\b = bounce(0..1, speed: 2, at: c0)
        \\f = follow([-1..1], by: spring(time: 0.3s), pause: 0s..200ms, seed: 2)
        \\x = crossing(f, level: 0)
        \\h = lanes(64, bounce(0..1, speed: 20, at: c0, stagger: 10ms))
        \\
    ;
    const source: commands.Source = .{ .name = "pieces.weft", .text = text };
    const to = 1_446_480_000; // 2.05 s
    const cases = [_]struct { to: i64, events: []const []const u8, count: usize }{
        .{ .to = 882_000_000, .events = &.{"b"}, .count = 2 },
        .{ .to = to, .events = &.{}, .count = commands.events_max },
        .{ .to = to, .events = &.{"x"}, .count = 0 },
    };
    for (cases) |case| {
        var one: std.Io.Writer = .fixed(&wide_output[0]);
        const whole: commands.Window = .{ .from = 0, .to = case.to, .step = case.to };
        try testing.expect(try commands.sample(testing.allocator, &compiled, &one, source, &.{}, &.{}, &.{"f"}, whole, .{ .events = case.events }));
        var pieces: std.Io.Writer = .fixed(&wide_output[1]);
        const fine: commands.Window = .{ .from = 0, .to = case.to, .step = 352_800_000 };
        try testing.expect(try commands.sample(testing.allocator, &compiled, &pieces, source, &.{}, &.{}, &.{"f"}, fine, .{ .events = case.events }));
        try testing.expectEqualStrings(events_of(one.buffered()), events_of(pieces.buffered()));
        if (case.count > 0) {
            try testing.expectEqual(case.count, std.mem.count(u8, events_of(one.buffered()), "{\"t\":"));
        }
    }
}

/// The score of `nouns.zig` and its entries: a client's file, as its own command reads it.
const score_file = @import("score.zig");

// Locks step 32's `check` with a client's entries: the score compiles, its `ok:` line counts its
// five nouns, and a file with no nouns prints the same bytes with the entries as without them.
test "check takes a client's entries and counts its nouns" {
    var writer: std.Io.Writer = .fixed(&output);
    const source: commands.Source = .{ .name = "score.weft", .text = score_file.score };
    try testing.expect(try commands.check(&compiled, &writer, source, &.{}, &score_file.nouns));
    try testing.expectEqualStrings(
        "ok: 11 nodes, a slab of 29, 2 cues, 0 goals, 0 regions, 1 tracks, 5 nouns, seekable, closed form\n" ++
            "limits: .{ .tokens = 132, .tree = 65, .names = 10, .nodes = 11, .slab = 29, .cues = 2, .goals = 0, .regions = 0, .tracks = 1, .modules = 0, .libraries = 0 }\n" ++
            "a lane costs 4 of the slab\n",
        writer.buffered(),
    );
    // Without the entries the nouns are unknown calls, as before this step.
    writer = .fixed(&output);
    try testing.expect(!try commands.check(&compiled, &writer, source, &.{}, &.{}));
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "error: there is no call `axes`") != null);
    // A file with no nouns: the entries change nothing, and there is no ", 0 nouns".
    const text = sequence ++ "b = breathe(out, 0.1)\nf = follow([0..1], by: spring(time: 0.3s), seed: 2)\nuse std\n";
    writer = .fixed(&output);
    try testing.expect(try commands.check(&compiled, &writer, .{ .name = "ok.weft", .text = text }, std_library, &score_file.nouns));
    try testing.expectEqualStrings(check_ok_golden, writer.buffered());
}

// Locks step 32's `sample` with a client's entries: every signal of the score in its order, and
// no noun, cue, or track; a file whose only bindings are nouns samples to no signals; a noun
// named with `--signal` is refused with what to do instead.
test "sample takes a client's entries and lists only its signals" {
    var writer: std.Io.Writer = .fixed(&output);
    const window: commands.Window = .{ .from = 0, .to = 705_600_000, .step = 705_600_000 };
    const source: commands.Source = .{ .name = "score.weft", .text = score_file.score };
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, source, &.{}, &score_file.nouns, &.{}, window, .{}));
    const sampled = writer.buffered();
    try testing.expect(std.mem.startsWith(u8, sampled, "{\"from\":0,\"to\":705600000,\"step\":705600000,\"signals\":[{\"name\":\"xs\",\"lanes\":5,"));
    try testing.expect(std.mem.indexOf(u8, sampled, "\"values\":[[-2,-1,0,1,2],[-2,-1,0,1,2]]},{\"name\":\"reveal\",") != null);
    try testing.expect(std.mem.endsWith(u8, sampled, "\"values\":[0,1]}],\"events\":[]}\n"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, sampled, "{\"name\":"));

    writer = .fixed(&output);
    const only_nouns: commands.Source = .{ .name = "nouns.weft", .text = "ax = axes(x: -3..3, y: -1..9)\nname = label(ax, text: \"axes\")\n" };
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, only_nouns, &.{}, &score_file.nouns, &.{}, window, .{}));
    try testing.expectEqualStrings("{\"from\":0,\"to\":705600000,\"step\":705600000,\"signals\":[],\"events\":[]}\n", writer.buffered());

    writer = .fixed(&output);
    try testing.expect(!try commands.sample(testing.allocator, &compiled, &writer, source, &.{}, &score_file.nouns, &.{"ax"}, window, .{}));
    try testing.expectEqualStrings("error: \"ax\" is a noun, `axes`, not a signal; bind a signal it reads on a line of its own to sample it\n", writer.buffered());
}

// Locks the bound on libraries: a third is an error that says how many fit, from `check` and
// `sample` alike, where the library would otherwise assert.
test "a third library is refused with an error" {
    const three: []const weft.lang.Source = &.{
        .{ .name = "std", .text = weft.lang.std_library },
        .{ .name = "two", .text = weft.lang.std_library },
        .{ .name = "three", .text = weft.lang.std_library },
    };
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(!try commands.check(&compiled, &writer, .{ .name = "ok.weft", .text = sequence }, three, &.{}));
    try testing.expectEqualStrings("error: at most 2 libraries, given 3\n", writer.buffered());
    writer = .fixed(&output);
    const window: commands.Window = .{ .from = 0, .to = 0, .step = 1 };
    try testing.expect(!try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "ok.weft", .text = sequence }, three, &.{}, &.{}, window, .{}));
    try testing.expectEqualStrings("error: at most 2 libraries, given 3\n", writer.buffered());
}

// Locks `cue_name` (step 32): a plain cue, a cue written after another (step 29), the first, the
// third, and the last cue of a series with its place, and null one past the table.
test "a cue's name from its index" {
    const text =
        \\cue c0 = 0s
        \\cue b2 = 2s
        \\cue hit = b2 + 500ms
        \\cue bar = 3s..7s every 1s
        \\
    ;
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(try commands.check(&compiled, &writer, .{ .name = "cues.weft", .text = text }, &.{}, &.{}));
    const CueName = weft.lang.CueName;
    try testing.expectEqualDeep(@as(?CueName, .{ .name = "c0" }), compiled.cue_name(0));
    try testing.expectEqualDeep(@as(?CueName, .{ .name = "hit" }), compiled.cue_name(2));
    try testing.expectEqualDeep(@as(?CueName, .{ .name = "bar", .element = 0 }), compiled.cue_name(3));
    try testing.expectEqualDeep(@as(?CueName, .{ .name = "bar", .element = 2 }), compiled.cue_name(5));
    try testing.expectEqualDeep(@as(?CueName, .{ .name = "bar", .element = 4 }), compiled.cue_name(7));
    try testing.expectEqual(@as(?CueName, null), compiled.cue_name(8));
}
