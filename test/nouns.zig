//! Nouns that only describe (step 27): a client's score beside a program, in one file.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What Is Locked
//! A client such as an explainer tool registers nouns for the things it owns: a stage, axes, a
//! plot, a caption. The file then holds both its motion and its score. These tests lock that:
//! - the file compiles to a program, where a `client` entry would refuse it;
//! - a noun's values reach the client in its entry's order: a string's text, a cue, a word, the
//!   noun another noun names, and each signal's node, with its lanes and its shape;
//! - a noun is not a signal, a string is not a number, and each mistake is one error that says
//!   what to write instead;
//! - a file with nouns formats to canonical text and back;
//! - an entry may take `schema.params_max` parameters, 24 since step 36, every one by name.
//!
//! ## 2. The Nouns
//! Four entries shaped like an explainer's, and the score that uses them, are in `score.zig`,
//! which `cli.zig` shares for a client's command (step 32).

const std = @import("std");
const testing = std.testing;
const weft = @import("weft");
const schema = weft.lang.schema;

const shared = @import("score.zig");
const nouns = shared.nouns;

const Compiled = weft.lang.Compiled(.{ .tokens = 512, .tree = 512, .names = 32, .nodes = 32, .slab = 512, .cues = 4, .libraries = 1, .modules = 8 });
var compiled: Compiled = undefined;
var slab: [512]f64 = undefined;
var output: [4096]u8 = undefined;

const score = shared.score;

fn fails(source: []const u8, code: weft.lang.diagnostic.Code, message: []const u8) !void {
    try testing.expectError(error.Invalid, compiled.compile_client(&nouns, &.{}, source));
    const found = compiled.errors()[0];
    testing.expectEqual(code, found.code) catch |err| {
        std.debug.print("message: {s}\n", .{found.message_text()});
        return err;
    };
    try testing.expectEqualStrings(message, found.message_text());
}

// Locks section 1: the file compiles, the nouns come in the file's order with their values, and
// each signal's node has the lanes and the shape it was written with.
test "a score's nouns sit beside its program, and the client reads both" {
    try compiled.compile_client(&nouns, &.{}, score);
    const program = compiled.program;
    var state = weft.State.init(program, slab[0..program.slab_count]);
    state.eval(.{ .flicks = weft.time.flicks_per_second / 2 });

    var iterator = compiled.nouns();
    const ax = iterator.next().?;
    try testing.expectEqualStrings("ax", ax.name);
    try testing.expectEqualStrings("axes", ax.entry.name);
    try testing.expectEqual([2]f64{ -3, 3 }, ax.values[0].number_range);

    const f = iterator.next().?;
    try testing.expectEqualStrings("f", f.name);
    // `on` names the axes' binding, which resolves to the noun above.
    try testing.expectEqualStrings("ax", compiled.noun_of(f.values[0].noun).name);
    const x = compiled.node_of(f.values[1]);
    const y = compiled.node_of(f.values[2]);
    try testing.expectEqual(@as(u32, 5), state.extent(x).lanes);
    try testing.expectEqualSlices(f64, &.{ -2, -1, 0, 1, 2 }, state.values(x));
    try testing.expectEqualSlices(f64, &.{ 4, 1, 0, 1, 4 }, state.values(y));
    // One lane beside five: a noun's signals do not join.
    try testing.expectEqual(@as(f64, 0.5), state.value(compiled.node_of(f.values[3])));
    try testing.expectEqual(@as(u32, 3), state.extent(compiled.node_of(f.values[4])).components);

    const n1 = iterator.next().?;
    try testing.expectEqual(compiled.cue("b1").?.index, n1.values[0].cue);
    try testing.expectEqualStrings("Here is a parabola: f(x) = a x^2.", n1.values[1].string);
    try testing.expectEqual(@as(u8, 0), n1.values[2].word);

    // No escapes: a backslash and a `#` are text.
    const n2 = iterator.next().?;
    try testing.expectEqualStrings("Its \\frac{rise}{run} # is its slope.", n2.values[1].string);
    try testing.expectEqual(@as(u8, 1), n2.values[2].word);

    const name = iterator.next().?;
    try testing.expectEqualStrings("f", compiled.noun_of(name.values[0].noun).name);
    try testing.expectEqualStrings("?", name.values[1].string);
    try testing.expect(iterator.next() == null);
    try testing.expectEqualStrings("say", compiled.noun("n2").?.entry.name);
    try testing.expect(compiled.noun("xs") == null);

    // A track the noun reads still moves it: the plot is a function of t and of the knob.
    try compiled.tables.tracks.write(compiled.track("a").?, .{ .flicks = 0 }, 2);
    state.eval(.{ .flicks = 0 });
    try testing.expectEqualSlices(f64, &.{ 8, 2, 0, 2, 8 }, state.values(y));
}

// Locks each refusal, with the message an agent reads.
test "a noun is not a signal, and a string is only a string" {
    try fails("ax = axes(x: 0..1, y: 0..1)\nout = ax + 1\n", .wrong_type, "`ax` is a noun, `axes`, not a signal");
    try fails("out = axes(x: 0..1, y: 0..1) * 2\n", .wrong_type, "`axes` describes a thing, and is not a signal");
    try fails("out = lanes(3, axes(x: 0..1, y: 0..1))\n", .wrong_type, "`axes` describes a thing, and is not a signal");
    try fails("ax = axes(x: 0..1, y: 0..1)\nout = ax.x\n", .unknown_output, "`ax` is a noun, `axes`, and a noun has no outputs");
    try fails("out = wave(sine, 1hz) + \"loud\"\n", .wrong_type, "a string is not a signal");
    try fails("out = tween(from: \"low\", to: 1, at: c, over: 1s)\n", .wrong_type, "expected a number, found string");
    try fails("cue c = 0s\nn = say(c, 3)\n", .wrong_type, "`text` takes a string");
    try fails("cue c = 0s\nn = say(c, \"open)\n", .unclosed_string, "this string has no closing quote on its line");
    try fails("cue c = 0s\nn = say(c, \"a\")\nf = plot(n, 1, y: 1)\n", .wrong_type, "`n` is `say`, which `on` does not take");
    try fails("cue c = 0s\nf = plot(c, 1, y: 1)\n", .wrong_type, "`c` is a cue, and `on` takes a noun");
    try fails("f = plot(axes(x: 0..1, y: 0..1), 1, y: 1)\n", .wrong_type, "`on` takes the name of a noun");
    try fails("name = label(later)\nlater = axes(x: 0..1, y: 0..1)\n", .used_before_declared, "`later` is used before it is declared, on line 2");
}

// Locks that the two kinds of client entry stay apart: a `client` signal still refuses the file.
test "a client signal beside a noun still refuses the file" {
    const both = nouns ++ [_]schema.Entry{.{
        .name = "dot",
        .op = .client,
        .role = .signal,
        .params = &.{.{ .name = "at", .kind = .signal, .positional = true }},
        .summary = "a signal the client builds",
    }};
    try testing.expectError(error.Invalid, compiled.compile_client(&both, &.{}, "ax = axes(x: 0..1, y: 0..1)\nout = dot(1)\n"));
    try testing.expectEqual(weft.lang.diagnostic.Code.refused, compiled.errors()[0].code);
}

// Locks the canonical format: a score formats to itself, strings byte for byte.
test "a score with strings formats to itself" {
    try compiled.compile_client(&nouns, &.{}, score);
    const formatted = try compiled.syntax.format_into(&output);
    try testing.expectEqualStrings(score, formatted);
    const loose = "cue c=0s\nn  =  say( c ,\"two  spaces,  kept\" , voice : aside )\n";
    try compiled.compile_client(&nouns, &.{}, loose);
    try testing.expectEqualStrings(
        "cue c = 0s\nn = say(c, \"two  spaces,  kept\", voice: aside)\n",
        try compiled.syntax.format_into(&output),
    );
}

// Locks a noun's part in a recompile: a simulated signal inside a noun carries like any other,
// here across an edit of another noun's string. An edit of `ax` would start `f` fresh, since a
// binding's fingerprint takes in every binding it names.
test "a simulated signal inside a noun carries across an edit" {
    const before = "cue c = 0s\nax = axes(x: 0..1, y: 0..1)\nf = plot(ax, 1, y: chase(wave(sine, 1hz), time: 0.2s))\nn = say(c, \"one\")\n";
    const after = "cue c = 0s\nax = axes(x: 0..1, y: 0..1)\nf = plot(ax, 1, y: chase(wave(sine, 1hz), time: 0.2s))\nn = say(c, \"another\")\n";
    const Pair = struct {
        var old: Compiled = undefined;
        var old_slab: [64]f64 = undefined;
        var new_slab: [64]f64 = undefined;
        var old_checkpoints: [4 * 64]f64 = undefined;
        var new_checkpoints: [4 * 64]f64 = undefined;
    };
    try Pair.old.compile_client(&nouns, &.{}, before);
    try compiled.compile_client(&nouns, &.{}, after);
    const old_program = Pair.old.program;
    var old_state = weft.State.init_with_checkpoints(old_program, Pair.old_slab[0..old_program.reader_slab_count()], Pair.old_checkpoints[0 .. 4 * old_program.slab_count]);
    const second: weft.Time = .{ .flicks = weft.time.flicks_per_second };
    old_state.eval(second);
    const program = compiled.program;
    var state = weft.State.init_with_checkpoints(program, Pair.new_slab[0..program.reader_slab_count()], Pair.new_checkpoints[0 .. 4 * program.slab_count]);
    try testing.expect(compiled.carry(&state, &Pair.old, &old_state));
    state.eval(second);
    const y_old = Pair.old.node_of(Pair.old.noun("f").?.values[2]);
    const y_new = compiled.node_of(compiled.noun("f").?.values[2]);
    try testing.expectEqual(old_state.value(y_old), state.value(y_new));
}

/// A noun at the limit (step 36): `schema.params_max` number parameters, none positional, the
/// last named `weight` so a misspelling of it has a near name to suggest.
const wide = [_]schema.Entry{.{
    .name = "wide",
    .op = .noun,
    .role = .signal,
    .params = &wide_params,
    .summary = "a noun with as many parameters as an entry may have",
}};
const wide_params = params: {
    var params: [schema.params_max]schema.Param = undefined;
    for (&params, 0..) |*param, at| param.* = .{
        .name = if (at == params.len - 1) "weight" else std.fmt.comptimePrint("a{d}", .{at}),
        .kind = .number,
    };
    break :params params;
};

// Locks step 36's edge: 24 parameters, given by name from the last to the first, check and
// compile, and parameter k reads k + 1, so the slots above 16 are each their own; the call
// formats to itself; a misspelt `weight`, the 24th, is suggested, and given twice is one error.
test "an entry with 24 parameters, each given by name, checks, compiles, and formats" {
    try testing.expectEqual(@as(usize, 24), schema.params_max);
    var text: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text);
    try writer.writeAll("w = wide(weight: 24");
    for (1..schema.params_max) |k| try writer.print(", a{d}: {d}", .{ schema.params_max - 1 - k, schema.params_max - k });
    try writer.writeAll(")\n");
    const source = writer.buffered();

    try compiled.compile_client(&wide, &.{}, source);
    const w = compiled.noun("w").?;
    try testing.expectEqual(@as(usize, 24), w.values.len);
    for (w.values, 0..) |value, k| try testing.expectEqual(@as(f64, @floatFromInt(k + 1)), value.number);
    try testing.expectEqualStrings(source, try compiled.syntax.format_into(&output));

    try testing.expectError(error.Invalid, compiled.compile_client(&wide, &.{}, "w = wide(wieght: 1)\n"));
    try testing.expectEqual(weft.lang.diagnostic.Code.unknown_parameter, compiled.errors()[0].code);
    try testing.expectEqualStrings("did you mean `weight`?", compiled.errors()[0].hint_text());
    try testing.expectError(error.Invalid, compiled.compile_client(&wide, &.{}, "w = wide(weight: 1, weight: 2)\n"));
    try testing.expectEqual(weft.lang.diagnostic.Code.duplicate_argument, compiled.errors()[0].code);
    try testing.expectEqual(@as(usize, 1), compiled.errors().len);
}
