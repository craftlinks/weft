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
//!
//! ## 4. A Client's Limits
//! A client of its own `Limits`, more cues than the command's and fewer nodes and libraries,
//! checks and samples through `commands.For` (step 37): once compiled, its `summary` and
//! `sample_compiled` print what `check` and `sample` would, and its limit errors name its own
//! numbers. A client's slab refusal names the declaration that needs the most (step 35).

const std = @import("std");
const testing = std.testing;
const weft = @import("weft");
const jig = @import("jig");
const weft_text = @import("weft_text");
const commands = @import("commands");

const describe_golden = @embedFile("golden/cli/describe.json");
const parse_golden = @embedFile("golden/cli/parse.json");
const check_golden = @embedFile("golden/cli/check_errors.txt");
const check_ok_golden = @embedFile("golden/cli/check_ok.txt");
const check_client_golden = @embedFile("golden/cli/check_client.txt");
const sample_golden = @embedFile("golden/cli/sample.json");
const sample_filtered_golden = @embedFile("golden/cli/sample_filtered.json");
const check_costs_golden = @embedFile("golden/cli/check_costs.txt");

const sequence =
    \\seed 7
    \\cue c0 = 0s
    \\cue c1 = 1s
    \\moves = [c1: 1]
    \\out = spring(moves, time: 0.5s, overshoot: 0.2)
    \\
;

const std_library: []const jig.Source = &.{.{ .name = "std", .text = weft_text.std_library }};

var output: [1 << 18]u8 = undefined;
var compiled: commands.Compiled = undefined;

// Locks the describe output: every primitive with its parameters, the numbers the language
// knows (step 40), then the standard library's modules with their defaults and bodies, and no
// nouns.
test "describe lists the primitives and the standard library's modules" {
    var writer: std.Io.Writer = .fixed(&output);
    try commands.describe(&writer, std_library, &.{});
    try testing.expectEqualStrings(describe_golden, writer.buffered());
}

// Locks the flat tree of a five-line file, item by item.
test "parse writes the flat tree of a file" {
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(try commands.parse(&writer, .{ .name = "sequence.jig", .text = sequence }));
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
    try testing.expect(!try commands.check(&compiled, &writer, .{ .name = "bad.jig", .text = bad }, &.{}, &.{}));
    try testing.expectEqualStrings(check_golden, writer.buffered());
}

// Locks the summary of a file that compiles, with a library: its nodes, its slab, cues, goals,
// regions, and tracks, and
// whether it is seekable and stepped.
test "check summarises a file that compiles" {
    var writer: std.Io.Writer = .fixed(&output);
    const text = sequence ++ "b = breathe(out, 0.1)\nf = follow([0..1], by: spring(time: 0.3s), seed: 2)\nuse std\n";
    try testing.expect(try commands.check(&compiled, &writer, .{ .name = "ok.jig", .text = text }, std_library, &.{}));
    try testing.expectEqualStrings(check_ok_golden, writer.buffered());
}

// Locks the sample output: a spring's range and its value every 0.5 s over 2 s.
test "sample writes each signal over the window, and its events" {
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "sequence.jig", .text = sequence }, &.{}, &.{}, &.{"out"}, .{
        .from = 0,
        .to = 1_411_200_000,
        .step = 352_800_000,
    }, .{}));
    try testing.expectEqualStrings(sample_golden, writer.buffered());
}

// Locks the refusals: a name that is not a signal, and the windows the sampler cannot run.
test "sample refuses a name that is not a signal, and a window it cannot run" {
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(!try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "sequence.jig", .text = sequence }, &.{}, &.{}, &.{"moves"}, .{
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

const dot_noun: jig.schema.Entry = .{
    .name = "dot",
    .op = .client,
    .role = .signal,
    .params = &.{
        .{ .name = "at", .kind = .signal, .positional = true },
        .{ .name = "size", .kind = .number, .default = .{ .number = 1 } },
    },
    .summary = "a client's own noun",
};

const osc_signal: jig.schema.Entry = .{
    .name = "osc",
    .op = .client,
    .role = .signal,
    .summary = "an oscillator the client builds",
    .params = &.{.{ .name = "hz", .kind = .number, .positional = true, .doc = "the rate" }},
};

const tap_signal: jig.schema.Entry = .{
    .name = "tap",
    .op = .client,
    .role = .signal,
    .summary = "a filter reading a signal",
    .params = &.{.{ .name = "input", .kind = .number, .positional = true, .live = true, .doc = "the input" }},
};

// Locks step 57: `check` on a file of a client's signals, one cue among them, is ok with the
// checker's counts (2 calls, 1 cue, nothing else), a line saying no program was built that names
// the first signal, and the least limits of the language's tables, byte for byte as the golden
// (`limits` has no `nodes`, `slab`, or `track_samples`); `sample` prints one line and is false.
// A misspelt parameter is today's error rendering and false.
test "check says ok for a file Weft does not build, and sample says why not" {
    const clients = [_]jig.schema.Entry{ osc_signal, tap_signal };
    const text = "cue c0 = 0s\nx = osc(2)\ny = tap(x)\n";
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(try commands.check(&compiled, &writer, .{ .name = "client.jig", .text = text }, &.{}, &clients));
    try testing.expectEqualStrings(check_client_golden, writer.buffered());

    writer = .fixed(&output);
    const window: commands.Window = .{ .from = 0, .to = 0, .step = 1 };
    const source: commands.Source = .{ .name = "client.jig", .text = text };
    try testing.expect(!try commands.sample(testing.allocator, &compiled, &writer, source, &.{}, &clients, &.{}, window, .{}));
    try testing.expectEqualStrings("sample: `osc` is a client's signal, which Weft does not build, so there is nothing to sample\n", writer.buffered());

    writer = .fixed(&output);
    const bad: commands.Source = .{ .name = "bad.jig", .text = "x = osc(hz: 2, h: 3)\n" };
    try testing.expect(!try commands.check(&compiled, &writer, bad, &.{}, &clients));
    try testing.expect(std.mem.startsWith(u8, writer.buffered(), "bad.jig:1:"));
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "error: ") != null);
}

// Locks section 3: the noun is checked, Weft's back end refuses it, and the client finds its
// call and its value; describe lists it among the nouns.
test "a client's noun is checked beside the primitives and refused by the back end" {
    const clients = [_]jig.schema.Entry{dot_noun};
    try testing.expectError(error.Invalid, compiled.compile_client(&clients, &.{}, "out = dot(wave(sine, 1hz), size: 2)\n"));
    try testing.expectEqual(jig.diagnostic.Code.refused, compiled.errors()[0].code);
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
// It builds no node, so its class is null, and a client's parameter has a sentence only where it
// gives one, `null` otherwise (step 35).
test "describe lists a describing noun with its string and noun parameters" {
    const clients = [_]jig.schema.Entry{.{
        .name = "label",
        .op = .noun,
        .role = .signal,
        .params = &.{
            .{ .name = "of", .kind = .noun, .positional = true, .words = &.{ "axes", "plot" } },
            .{ .name = "text", .kind = .string, .default = .{ .text = "?" }, .doc = "the name it shows" },
        },
        .summary = "a name beside a noun",
    }};
    var writer: std.Io.Writer = .fixed(&output);
    try commands.describe(&writer, &.{}, &clients);
    const expected = "\"nouns\":[{\"name\":\"label\",\"role\":\"signal\",\"op\":\"noun\",\"summary\":\"a name beside a noun\"," ++
        "\"lanes\":\"apart\",\"class\":null,\"events\":null,\"outputs\":[],\"params\":[" ++
        "{\"name\":\"of\",\"kind\":\"noun\",\"live\":false,\"shaped\":false,\"positional\":true,\"default\":null,\"words\":[\"axes\",\"plot\"],\"doc\":null}," ++
        "{\"name\":\"text\",\"kind\":\"string\",\"live\":false,\"shaped\":false,\"positional\":false,\"default\":\"?\",\"words\":[],\"doc\":\"the name it shows\"}]}]";
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

const least_libraries: []const jig.Source = &.{.{ .name = "std", .text = weft_text.std_library }};

/// What `check` prints for `least_source`, as a `Limits`.
const least: weft_text.Limits = .{ .tokens = 142, .tree = 64, .names = 10, .nodes = 7, .slab = 25, .cues = 2, .goals = 1, .regions = 1, .tracks = 1, .modules = 7, .libraries = 1 };

/// Whether `least_source` compiles under `limits`, each in a `Compiled` of its own.
fn compiles_with(comptime limits: weft_text.Limits) bool {
    const Holder = struct {
        var compiled: weft_text.Compiled(limits) = undefined;
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
    try testing.expect(try commands.check(&compiled, &writer, .{ .name = "least.jig", .text = least_source }, least_libraries, &.{}));
    const needs = compiled.needs();
    inline for (@typeInfo(weft_text.Limits).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "track_samples") or std.mem.eql(u8, name, "errors")) continue;
        try testing.expectEqual(@field(least, name), @field(needs, name));
    }
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "limits: .{ .tokens = 142, .tree = 64,") != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "a lane costs 2 of the slab\n") != null);
    try testing.expect(compiles_with(least));
    inline for (@typeInfo(weft_text.Limits).@"struct".field_names) |name| {
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
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "filtered.jig", .text = text }, &.{}, &.{}, &.{ "h", "w" }, window, .{
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
        try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "sources.jig", .text = text }, &.{}, &.{}, &.{"w"}, window, .{
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
    try testing.expect(try commands.sample(testing.allocator, &compiled, &all, .{ .name = "sources.jig", .text = text }, &.{}, &.{}, &.{"w"}, window, .{}));
    const every = all.buffered()[std.mem.indexOf(u8, all.buffered(), "\"events\":[").?..];
    try testing.expectEqual(@as(usize, 30), std.mem.count(u8, every, "{\"t\":"));
    try testing.expectEqual(@as(usize, 30), std.mem.count(u8, every, "\"name\":"));
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, every, "\"name\":\"plain\""));
    // Both names together keep each one's events once, in one order.
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "sources.jig", .text = text }, &.{}, &.{}, &.{"w"}, window, .{
        .events = &.{ "x", "plain", "x" },
    }));
    const sampled = writer.buffered();
    try testing.expectEqual(@as(usize, 8), std.mem.count(u8, sampled[std.mem.indexOf(u8, sampled, "\"events\":[").?..], "{\"t\":"));

    // `alias` shares `first`'s bounce, so its events are named `first`, declared first.
    const shared = "cue go = 0s\nfirst = bounce(0..1, speed: 2, at: go)\nalias = first\n";
    writer = .fixed(&output);
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "shared.jig", .text = shared }, &.{}, &.{}, &.{"first"}, window, .{
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
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "big.jig", .text = text }, &.{}, &.{}, &.{"f"}, window, .{ .lanes = .{ 0, 1 } }));
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
    const source: commands.Source = .{ .name = "walks.jig", .text = text };
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
    const source: commands.Source = .{ .name = "pieces.jig", .text = text };
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
    const source: commands.Source = .{ .name = "score.jig", .text = score_file.score };
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
    try testing.expect(try commands.check(&compiled, &writer, .{ .name = "ok.jig", .text = text }, std_library, &score_file.nouns));
    try testing.expectEqualStrings(check_ok_golden, writer.buffered());
}

// Locks step 32's `sample` with a client's entries: every signal of the score in its order, and
// no noun, cue, or track; a file whose only bindings are nouns samples to no signals; a noun
// named with `--signal` is refused with what to do instead.
test "sample takes a client's entries and lists only its signals" {
    var writer: std.Io.Writer = .fixed(&output);
    const window: commands.Window = .{ .from = 0, .to = 705_600_000, .step = 705_600_000 };
    const source: commands.Source = .{ .name = "score.jig", .text = score_file.score };
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, source, &.{}, &score_file.nouns, &.{}, window, .{}));
    const sampled = writer.buffered();
    try testing.expect(std.mem.startsWith(u8, sampled, "{\"from\":0,\"to\":705600000,\"step\":705600000,\"signals\":[{\"name\":\"xs\",\"lanes\":5,"));
    try testing.expect(std.mem.indexOf(u8, sampled, "\"values\":[[-2,-1,0,1,2],[-2,-1,0,1,2]]},{\"name\":\"reveal\",") != null);
    try testing.expect(std.mem.endsWith(u8, sampled, "\"values\":[0,1]}],\"events\":[]}\n"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, sampled, "{\"name\":"));

    writer = .fixed(&output);
    const only_nouns: commands.Source = .{ .name = "nouns.jig", .text = "ax = axes(x: -3..3, y: -1..9)\nname = label(ax, text: \"axes\")\n" };
    try testing.expect(try commands.sample(testing.allocator, &compiled, &writer, only_nouns, &.{}, &score_file.nouns, &.{}, window, .{}));
    try testing.expectEqualStrings("{\"from\":0,\"to\":705600000,\"step\":705600000,\"signals\":[],\"events\":[]}\n", writer.buffered());

    writer = .fixed(&output);
    try testing.expect(!try commands.sample(testing.allocator, &compiled, &writer, source, &.{}, &score_file.nouns, &.{"ax"}, window, .{}));
    try testing.expectEqualStrings("error: \"ax\" is a noun, `axes`, not a signal; bind a signal it reads on a line of its own to sample it\n", writer.buffered());
}

// Locks the bound on libraries: a third is an error that says how many fit, from `check` and
// `sample` alike, where the library would otherwise assert.
test "a third library is refused with an error" {
    const three: []const jig.Source = &.{
        .{ .name = "std", .text = weft_text.std_library },
        .{ .name = "two", .text = weft_text.std_library },
        .{ .name = "three", .text = weft_text.std_library },
    };
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(!try commands.check(&compiled, &writer, .{ .name = "ok.jig", .text = sequence }, three, &.{}));
    try testing.expectEqualStrings("error: at most 2 libraries, given 3\n", writer.buffered());
    writer = .fixed(&output);
    const window: commands.Window = .{ .from = 0, .to = 0, .step = 1 };
    try testing.expect(!try commands.sample(testing.allocator, &compiled, &writer, .{ .name = "ok.jig", .text = sequence }, three, &.{}, &.{}, window, .{}));
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
    try testing.expect(try commands.check(&compiled, &writer, .{ .name = "cues.jig", .text = text }, &.{}, &.{}));
    const CueName = jig.CueName;
    try testing.expectEqualDeep(@as(?CueName, .{ .name = "c0" }), compiled.cue_name(0));
    try testing.expectEqualDeep(@as(?CueName, .{ .name = "hit" }), compiled.cue_name(2));
    try testing.expectEqualDeep(@as(?CueName, .{ .name = "bar", .element = 0 }), compiled.cue_name(3));
    try testing.expectEqualDeep(@as(?CueName, .{ .name = "bar", .element = 2 }), compiled.cue_name(5));
    try testing.expectEqualDeep(@as(?CueName, .{ .name = "bar", .element = 4 }), compiled.cue_name(7));
    try testing.expectEqual(@as(?CueName, null), compiled.cue_name(8));
}

/// A client's own limits (step 37): more cues than the command's 512, fewer nodes than its 1024,
/// and one library where it holds two.
const client_limits: weft_text.Limits = .{
    .tokens = 1024,
    .tree = 1024,
    .names = 64,
    .nodes = 8,
    .slab = 4096,
    .cues = 1024,
    .goals = 16,
    .regions = 4,
    .tracks = 2,
    .track_samples = 64,
    .modules = 16,
    .libraries = 1,
};
const client_command = commands.For(client_limits);
var client_compiled: weft_text.Compiled(client_limits) = undefined;

/// A file of 601 cues, past the command's 512, and three nodes, within the client's 8.
const many_cues =
    \\cue bar = 0s..600s every 1s
    \\b = bounce(0..1, speed: 0.5, at: bar[599])
    \\bars = cues(bar)
    \\
;

/// Nine nodes, one past the client's 8: a wave and eight sums.
const nine_nodes = "a = wave(sine, 1hz)\nb = a + 1\nc = b + 1\nd = c + 1\ne = d + 1\nf = e + 1\n" ++
    "g = f + 1\nh = g + 1\ni = h + 1\n";

// Locks step 37: a client whose limits hold more cues than the command's and fewer nodes compiles
// its file once and checks and samples that `Compiled`. The command refuses 601 cues at its 512;
// the client's `summary` gives the 601 cues and `.cues = 601`, the bytes its `check` prints, and
// `sample_compiled` gives `bars` stepping 599, 600, 601, 601 at 598 s to 601 s, and the cues at
// 598, 599, and 600 s, the bytes its `sample` prints after compiling again.
test "a client checks and samples its own Compiled, at its own limits" {
    const source: commands.Source = .{ .name = "cues.jig", .text = many_cues };
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(!try commands.check(&compiled, &writer, source, &.{}, &.{}));
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "error: the file needs more than 512 cues") != null);

    // One compile, as a client's own load makes it, then its lines and its JSON.
    try client_compiled.compile_client(&.{}, &.{}, many_cues);
    writer = .fixed(&output);
    try client_command.summary(&client_compiled, &writer);
    const summarised = "ok: 3 nodes, a slab of 3, 601 cues, 0 goals, 0 regions, 0 tracks, seekable, closed form\n" ++
        "limits: .{ .tokens = 37, .tree = 17, .names = 3, .nodes = 3, .slab = 3, .cues = 601, .goals = 0, .regions = 0, .tracks = 0, .modules = 0, .libraries = 0 }\n";
    try testing.expectEqualStrings(summarised, writer.buffered());
    const second = 705_600_000;
    const window: commands.Window = .{ .from = 598 * second, .to = 601 * second, .step = second };
    var sampled: std.Io.Writer = .fixed(&wide_output[0]);
    try testing.expect(try client_command.sample_compiled(testing.allocator, &client_compiled, &sampled, &.{"bars"}, window, .{}));
    try testing.expectEqualStrings("{\"from\":421948800000,\"to\":424065600000,\"step\":705600000,\"signals\":[" ++
        "{\"name\":\"bars\",\"range\":[0,601],\"bounded\":true,\"values\":[599,600,601,601]}],\"events\":[" ++
        "{\"t\":421948800000,\"source\":2,\"instance\":0,\"name\":\"bars\",\"value\":598}," ++
        "{\"t\":422654400000,\"source\":2,\"instance\":0,\"name\":\"bars\",\"value\":599}," ++
        "{\"t\":423360000000,\"source\":2,\"instance\":0,\"name\":\"bars\",\"value\":600}]}\n", sampled.buffered());

    // `check` and `sample`, which compile, print the same bytes.
    writer = .fixed(&output);
    try testing.expect(try client_command.check(&client_compiled, &writer, source, &.{}, &.{}));
    try testing.expectEqualStrings(summarised, writer.buffered());
    var again: std.Io.Writer = .fixed(&wide_output[1]);
    try testing.expect(try client_command.sample(testing.allocator, &client_compiled, &again, source, &.{}, &.{}, &.{"bars"}, window, .{}));
    try testing.expectEqualStrings(sampled.buffered(), again.buffered());
}

// Locks step 37's limit errors: each names the client's number, not the command's. Nine nodes
// are past the client's 8, which the command holds; two libraries are past its one. Under the
// node error, the least `Limits` the file needs, counted past the limit (step 49): 17 nodes.
test "a client's limit errors name the client's limits" {
    const nine: commands.Source = .{ .name = "nine.jig", .text = nine_nodes };
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(try commands.check(&compiled, &writer, nine, &.{}, &.{}));
    writer = .fixed(&output);
    try testing.expect(!try client_command.check(&client_compiled, &writer, nine, &.{}, &.{}));
    try testing.expectEqualStrings("nine.jig:5:5: error: the program needs more than 8 nodes\n" ++
        "    e = d + 1\n        ^^^^^\n    hint: raise `Limits.nodes`\n" ++
        "limits: .{ .tokens = 58, .tree = 36, .names = 9, .nodes = 17, .slab = 17, .cues = 0, .goals = 0, .regions = 0, .tracks = 0, .modules = 0, .libraries = 0 }\n", writer.buffered());

    const two: []const jig.Source = &.{
        .{ .name = "std", .text = weft_text.std_library },
        .{ .name = "two", .text = weft_text.std_library },
    };
    const source: commands.Source = .{ .name = "ok.jig", .text = sequence };
    writer = .fixed(&output);
    try testing.expect(!try client_command.check(&client_compiled, &writer, source, two, &.{}));
    try testing.expectEqualStrings("error: at most 1 libraries, given 2\n", writer.buffered());
    writer = .fixed(&output);
    const window: commands.Window = .{ .from = 0, .to = 0, .step = 1 };
    try testing.expect(!try client_command.sample(testing.allocator, &client_compiled, &writer, source, two, &.{}, &.{}, window, .{}));
    try testing.expectEqualStrings("error: at most 1 libraries, given 2\n", writer.buffered());
}

// Locks that a file within both limits prints the same bytes from the client's calls as from the
// command's: the sample golden, the spring of `sequence`.
test "a client's calls print the command's bytes on a file both hold" {
    const source: commands.Source = .{ .name = "sequence.jig", .text = sequence };
    const window: commands.Window = .{ .from = 0, .to = 1_411_200_000, .step = 352_800_000 };
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(try client_command.sample(testing.allocator, &client_compiled, &writer, source, &.{}, &.{}, &.{"out"}, window, .{}));
    try testing.expectEqualStrings(sample_golden, writer.buffered());
    var weft_lines: std.Io.Writer = .fixed(&wide_output[0]);
    try testing.expect(try commands.check(&compiled, &weft_lines, source, &.{}, &.{}));
    var client_lines: std.Io.Writer = .fixed(&wide_output[1]);
    try testing.expect(try client_command.check(&client_compiled, &client_lines, source, &.{}, &.{}));
    try testing.expectEqualStrings(weft_lines.buffered(), client_lines.buffered());
}

/// A client's limits with a small slab, for its refusal (step 35).
const slab_limits: weft_text.Limits = .{ .nodes = 64, .slab = 1024, .libraries = 1 };
const slab_command = commands.For(slab_limits);
var slab_compiled: weft_text.Compiled(slab_limits) = undefined;

/// A plot of 100 lanes that uses a library's module twice, past a slab of 1024: each lane's two
/// noises, two chases of 4 values, and their sum take 11 values, and `base` one.
const big_plot =
    \\use lib
    \\cue c0 = 0s
    \\base = noise(smooth, 1hz)
    \\plot = lanes(100, wobble(noise(smooth, 1hz)) + wobble(noise(steps, 2hz)))
    \\
;
const wobble_library: []const jig.Source = &.{.{ .name = "lib", .text = "module wobble(x) = chase(x, time: 0.2s)\n" }};

/// A client's limits of 3 nodes and a slab of 2, for a refusal of both.
const tiny_limits: weft_text.Limits = .{ .nodes = 3, .slab = 2 };
const tiny_command = commands.For(tiny_limits);
var tiny_compiled: weft_text.Compiled(tiny_limits) = undefined;

// Locks step 35's slab refusal: it names the declaration that needs the most, on its name, with
// its values and lanes, and the client's limit. `plot` needs 1100 of the 1101 values, at 100 lanes
// of 11 values each, so the hint says fewer lanes first, then the `Limits.slab` that fits. A file
// of one lane each says only the limit, 3; a build the node limit stopped gives its error, then
// the least the slab needs, 6, of the declarations built until then, with `a`'s 4 lanes. Each
// refusal is followed by the least `Limits` the file needs, counted again (step 49): a slab of
// 1101, of 3, and, past the 3 nodes as well, 4 nodes and a slab of 7.
test "a slab refusal names the declaration that needs the most" {
    var writer: std.Io.Writer = .fixed(&output);
    const plot: commands.Source = .{ .name = "plot.jig", .text = big_plot };
    try testing.expect(!try slab_command.check(&slab_compiled, &writer, plot, wobble_library, &.{}));
    try testing.expectEqualStrings("plot.jig:4:1: error: the slab needs 1101 values, more than 1024; `plot` needs 1100 of them, at 100 lanes\n" ++
        "    plot = lanes(100, wobble(noise(smooth, 1hz)) + wobble(noise(steps, 2hz)))\n    ^^^^\n" ++
        "    hint: give `plot` fewer lanes, which cost 11 of the slab each, or raise `Limits.slab` to 1101\n" ++
        "limits: .{ .tokens = 45, .tree = 19, .names = 4, .nodes = 6, .slab = 1101, .cues = 1, .goals = 0, .regions = 0, .tracks = 0, .modules = 1, .libraries = 1 }\n", writer.buffered());

    writer = .fixed(&output);
    const one_lane: commands.Source = .{ .name = "one.jig", .text = "a = wave(sine, 1hz)\nb = wave(saw, 1hz)\nc = wave(square, 1hz)\n" };
    try testing.expect(!try tiny_command.check(&tiny_compiled, &writer, one_lane, &.{}, &.{}));
    try testing.expectEqualStrings("one.jig:1:1: error: the slab needs 3 values, more than 2; `a` needs 1 of them\n" ++
        "    a = wave(sine, 1hz)\n    ^\n    hint: raise `Limits.slab` to 3\n" ++
        "limits: .{ .tokens = 28, .tree = 12, .names = 3, .nodes = 3, .slab = 3, .cues = 0, .goals = 0, .regions = 0, .tracks = 0, .modules = 0, .libraries = 0 }\n", writer.buffered());

    writer = .fixed(&output);
    const four: commands.Source = .{ .name = "four.jig", .text = "a = lanes(4, noise(smooth, 1hz))\nb = wave(sine, 1hz)\nc = wave(saw, 1hz)\nd = wave(square, 1hz)\n" };
    try testing.expect(!try tiny_command.check(&tiny_compiled, &writer, four, &.{}, &.{}));
    try testing.expectEqualStrings("four.jig:4:5: error: the program needs more than 3 nodes\n" ++
        "    d = wave(square, 1hz)\n        ^^^^^^^^^^^^^^^^^\n    hint: raise `Limits.nodes`\n" ++
        "four.jig:1:1: error: the slab needs at least 6 values, more than 2; `a` needs 4 of them, at 4 lanes\n" ++
        "    a = lanes(4, noise(smooth, 1hz))\n    ^\n" ++
        "    hint: give `a` fewer lanes, which cost 1 of the slab each, or raise `Limits.slab`\n" ++
        "limits: .{ .tokens = 42, .tree = 18, .names = 4, .nodes = 4, .slab = 7, .cues = 0, .goals = 0, .regions = 0, .tracks = 0, .modules = 0, .libraries = 0 }\n", writer.buffered());
}

/// Two waves and `count` sums, each of the one before and a number of its own, 1 to `count`:
/// 2 + 2 * `count` nodes, each of one value.
fn waves_and_sums(comptime count: u32) []const u8 {
    comptime var text: []const u8 = "a = wave(sine, 1hz)\nb = wave(saw, 1hz)\ns1 = b + 1\n";
    inline for (2..count + 1) |k| {
        text = text ++ std.fmt.comptimePrint("s{d} = s{d} + {d}\n", .{ k, k - 1, k });
    }
    return text;
}

/// The last line of `output`, without its newline.
fn last_line(printed: []const u8) []const u8 {
    const body = std.mem.trimEnd(u8, printed, "\n");
    const start = if (std.mem.lastIndexOfScalar(u8, body, '\n')) |at| at + 1 else 0;
    return body[start..];
}

// Locks step 49's count at the edge of the lent nodes, four times the client's 8: two waves and
// 15 sums are 32 nodes, which it counts exactly, and a slab of 32; with a sixteenth sum they are
// 34, past the 32 it holds, so the line says at least 33. Both checks are false.
test "check counts nodes up to four times the limit, and says at least past it" {
    var writer: std.Io.Writer = .fixed(&output);
    const exact: commands.Source = .{ .name = "exact.jig", .text = waves_and_sums(15) };
    try testing.expect(!try client_command.check(&client_compiled, &writer, exact, &.{}, &.{}));
    const line = last_line(writer.buffered());
    try testing.expect(std.mem.startsWith(u8, line, "limits: .{ "));
    try testing.expect(std.mem.indexOf(u8, line, ".nodes = 32, .slab = 32,") != null);

    writer = .fixed(&output);
    const past: commands.Source = .{ .name = "past.jig", .text = waves_and_sums(16) };
    try testing.expect(!try client_command.check(&client_compiled, &writer, past, &.{}, &.{}));
    try testing.expect(std.mem.endsWith(u8, writer.buffered(), "\nlimits: at least .{ .nodes = 33 }\n"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, writer.buffered(), "error: "));
}

const token_limits: weft_text.Limits = .{ .tokens = 16 };
const token_command = commands.For(token_limits);
var token_compiled: weft_text.Compiled(token_limits) = undefined;

// Locks step 49's token count past `Limits.tokens` (16): a file of 16 tokens, the newlines and
// the `eof` among them, checks; two more, `+ 1`, make 18, which the line under the error gives.
test "check gives the tokens a file needs past the limit" {
    var writer: std.Io.Writer = .fixed(&output);
    const fits: commands.Source = .{ .name = "fits.jig", .text = "w = wave(sine, 1hz)\nx = w * 2\n" };
    try testing.expect(try token_command.check(&token_compiled, &writer, fits, &.{}, &.{}));
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "limits: .{ .tokens = 16,") != null);

    writer = .fixed(&output);
    const over: commands.Source = .{ .name = "over.jig", .text = "w = wave(sine, 1hz)\nx = w * 2 + 1\n" };
    try testing.expect(!try token_command.check(&token_compiled, &writer, over, &.{}, &.{}));
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "error: ") != null);
    try testing.expect(std.mem.endsWith(u8, writer.buffered(), "\nlimits: at least .{ .tokens = 18 }\n"));
}

/// The file of `check_costs.txt`: a comment, a seed, a cue, a module used twice, and lanes.
const costs_source =
    \\# a comment
    \\
    \\seed 7
    \\cue c0 = 0s
    \\module twice(v) = v * 2
    \\w = wave(sine, 1hz)
    \\x = twice(w) + twice(w * 3)
    \\row = lanes(4, lane * 0.25)
    \\
;

// Locks `check --costs` (step 49), worked by hand: `x` is 2, a product, 3, a product, 2, a
// product, and a sum, 7 nodes, the module's at each use; `row` is `lane` (4 values), 0.25, and a
// product (4 values), 3 nodes and a slab of 9; the module's own row has its 9 tokens and no node;
// the last row is the comment, eight newlines, and the `eof`. `check`'s lines come first, byte for
// byte as `check` prints them.
test "check_costs lists each declaration's tokens, nodes, and slab" {
    var writer: std.Io.Writer = .fixed(&output);
    const source: commands.Source = .{ .name = "costs.jig", .text = costs_source };
    try testing.expect(try commands.check_costs(&compiled, &writer, source, &.{}, &.{}));
    try testing.expectEqualStrings(check_costs_golden, writer.buffered());
    var lines: std.Io.Writer = .fixed(&wide_output[0]);
    try testing.expect(try commands.check(&compiled, &lines, source, &.{}, &.{}));
    try testing.expect(std.mem.startsWith(u8, check_costs_golden, lines.buffered()));
    var table: std.Io.Writer = .fixed(&wide_output[1]);
    try commands.costs(&compiled, &table);
    try testing.expectEqualStrings(check_costs_golden[lines.buffered().len..], table.buffered());
}

/// The header and the column names of `costs`' table.
const costs_head = " tokens   nodes    slab    line  declaration\n";

// Locks a feed's own row (step 49): the delay is `d`'s node, a slab of 3 with its cache; the
// feed's 0.5, product, 1, and sum are its own 4; `out`'s 2 and sum are 2.
test "check_costs gives a feed its own row" {
    var writer: std.Io.Writer = .fixed(&output);
    const source: commands.Source = .{ .name = "fed.jig", .text = "cue c0 = 0s\nd = delay(0)\nd <- d * 0.5 + 1\nout = d + 2\n" };
    try testing.expect(try commands.check_costs(&compiled, &writer, source, &.{}, &.{}));
    const table = writer.buffered()[std.mem.indexOf(u8, writer.buffered(), "costs: ").?..];
    try testing.expectEqualStrings("costs: 27 tokens, 7 nodes, a slab of 9\n" ++ costs_head ++
        "      7       4       4       3  feed d\n" ++
        "      5       2       2       4  bind out\n" ++
        "      6       1       3       2  bind d\n" ++
        "      4       0       0       1  cue c0\n" ++
        "      5       0       0       -  between declarations\n", table);
}

// Locks the table of a file past the client's 8 nodes (step 49): it is the counted program's, 17
// nodes, after the error and the `limits:` line; each sum is 2 nodes, its 1 and itself, in line
// order, then `a`'s wave.
test "check_costs past the node limit gives the counted program's table" {
    var writer: std.Io.Writer = .fixed(&output);
    const nine: commands.Source = .{ .name = "nine.jig", .text = nine_nodes };
    try testing.expect(!try client_command.check_costs(&client_compiled, &writer, nine, &.{}, &.{}));
    try testing.expectEqualStrings("nine.jig:5:5: error: the program needs more than 8 nodes\n" ++
        "    e = d + 1\n        ^^^^^\n    hint: raise `Limits.nodes`\n" ++
        "limits: .{ .tokens = 58, .tree = 36, .names = 9, .nodes = 17, .slab = 17, .cues = 0, .goals = 0, .regions = 0, .tracks = 0, .modules = 0, .libraries = 0 }\n" ++
        "costs: 58 tokens, 17 nodes, a slab of 17\n" ++ costs_head ++
        "      5       2       2       2  bind b\n" ++
        "      5       2       2       3  bind c\n" ++
        "      5       2       2       4  bind d\n" ++
        "      5       2       2       5  bind e\n" ++
        "      5       2       2       6  bind f\n" ++
        "      5       2       2       7  bind g\n" ++
        "      5       2       2       8  bind h\n" ++
        "      5       2       2       9  bind i\n" ++
        "      8       1       1       1  bind a\n" ++
        "     10       0       0       -  between declarations\n", writer.buffered());
}

/// Play's five files and the starter's, as their apps compile them.
const real_files = [_]commands.Source{
    .{ .name = "bouncers.jig", .text = @embedFile("play_bouncers") },
    .{ .name = "lanes.jig", .text = @embedFile("play_lanes") },
    .{ .name = "signals.jig", .text = @embedFile("play_signals") },
    .{ .name = "swarm.jig", .text = @embedFile("play_swarm") },
    .{ .name = "vectors.jig", .text = @embedFile("play_vectors") },
    .{ .name = "motion.jig", .text = @embedFile("starter_motion") },
};

/// The three numbers of a row or a header of `costs`' table, in its order.
fn three_numbers(line: []const u8) ![3]u64 {
    var numbers: [3]u64 = undefined;
    var words = std.mem.tokenizeAny(u8, line, " ,:");
    var found: usize = 0;
    while (words.next()) |word| {
        if (found == numbers.len) break;
        numbers[found] = std.fmt.parseInt(u64, word, 10) catch continue;
        found += 1;
    }
    if (found < numbers.len) return error.TestUnexpectedResult;
    return numbers;
}

// Locks the table's sums on real files (step 49): on each of Play's five files and the starter's,
// the rows' tokens, nodes, and slab sum to the header's, and the header's nodes and slab are the
// `ok:` line's, its tokens the file's own.
test "check_costs' rows sum to check's totals on real files" {
    for (real_files) |source| {
        errdefer std.debug.print("costs of {s}\n", .{source.name});
        var writer: std.Io.Writer = .fixed(&output);
        try testing.expect(try commands.check_costs(&compiled, &writer, source, &.{}, &.{}));
        const printed = writer.buffered();
        var ok_line: [96]u8 = undefined;
        const ok = try std.fmt.bufPrint(&ok_line, "ok: {d} nodes, a slab of {d},", .{
            compiled.program.nodes.len,
            compiled.program.slab_count,
        });
        try testing.expect(std.mem.startsWith(u8, printed, ok));
        var header_line: [96]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_line, "\ncosts: {d} tokens, {d} nodes, a slab of {d}\n", .{
            compiled.syntax.tree.tokens.len,
            compiled.program.nodes.len,
            compiled.program.slab_count,
        });
        const table_at = std.mem.indexOf(u8, printed, header).? + header.len;
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, printed[table_at..], "\n"), '\n');
        try testing.expectEqualStrings(costs_head[0 .. costs_head.len - 1], lines.next().?);
        var sums: [3]u64 = .{ 0, 0, 0 };
        var rows: usize = 0;
        while (lines.next()) |line| {
            const numbers = try three_numbers(line);
            for (&sums, numbers) |*sum, number| sum.* += number;
            rows += 1;
        }
        try testing.expectEqual(compiled.syntax.tree.declarations.len + 1, rows);
        try testing.expectEqual(@as(u64, compiled.syntax.tree.tokens.len), sums[0]);
        try testing.expectEqual(@as(u64, compiled.program.nodes.len), sums[1]);
        try testing.expectEqual(@as(u64, compiled.program.slab_count), sums[2]);
    }
}

// Locks the table of a file of a client's signals (step 49), the file of `check_client.txt`: no
// program, so every row has 0 nodes and 0 slab, after `check`'s lines unchanged; its 20 tokens
// are `x`'s 6 and `y`'s 6, the cue's 4, and three newlines and the `eof`.
test "check_costs on a file Weft does not build gives no nodes" {
    const clients = [_]jig.schema.Entry{ osc_signal, tap_signal };
    const text = "cue c0 = 0s\nx = osc(2)\ny = tap(x)\n";
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(try commands.check_costs(&compiled, &writer, .{ .name = "client.jig", .text = text }, &.{}, &clients));
    try testing.expectEqualStrings(check_client_golden ++ "costs: 20 tokens, 0 nodes, a slab of 0\n" ++ costs_head ++
        "      6       0       0       2  bind x\n" ++
        "      6       0       0       3  bind y\n" ++
        "      4       0       0       1  cue c0\n" ++
        "      4       0       0       -  between declarations\n", writer.buffered());
}
