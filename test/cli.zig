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
    try testing.expect(try commands.sample(&compiled, &writer, .{ .name = "sequence.weft", .text = sequence }, &.{}, &.{"out"}, .{
        .from = 0,
        .to = 1_411_200_000,
        .step = 352_800_000,
    }));
    try testing.expectEqualStrings(sample_golden, writer.buffered());
}

// Locks the refusals: a name that is not a signal, and the windows the sampler cannot run.
test "sample refuses a name that is not a signal, and a window it cannot run" {
    var writer: std.Io.Writer = .fixed(&output);
    try testing.expect(!try commands.sample(&compiled, &writer, .{ .name = "sequence.weft", .text = sequence }, &.{}, &.{"moves"}, .{
        .from = 0,
        .to = 705_600_000,
        .step = 70_560_000,
    }));
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
