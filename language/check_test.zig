//! The checker's rules, tested on a vocabulary of the language's own (step 55b).
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What Is Locked
//! The checker acts on what an entry declares, so each rule is held here on a small vocabulary
//! written in this file, with no back end: a plain signal, a pair that must agree, a signal of its
//! input's shape, constructors, a fed call, a noun, a call that continues another, a cue by lane,
//! a mover and a call that takes one, a parameter with a range and one with a need, and a call
//! that folds. Weft's own tests keep testing Weft's table. Items 1 to 9 of the step are each here,
//! with the values they lock.
//!
//! ## 2. The Vocabulary
//! The tags are the language's three or numbers no one names (`@enumFromInt(3)` and up), as a
//! back end's are. `fold` doubles its first operand and `convert` halves the first three values, so
//! a folded number and a converted colour are easy to tell from what was written.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const parse = @import("parse.zig");
const schema = @import("schema.zig");
const check = @import("check.zig");
const Entry = schema.Entry;
const Code = @import("error.zig").Code;

const tag_plain: schema.Op = @fromBackingInt(@intCast(3));

const plain: Entry = .{
    .name = "plain",
    .op = tag_plain,
    .role = .signal,
    .summary = "a signal of one value",
    .params = &.{.{ .name = "level", .kind = .number, .positional = true, .range = .{ 0, 1 }, .hint = "write a level from 0 to 1" }},
};

const pair: Entry = .{
    .name = "pair",
    .op = tag_plain,
    .role = .signal,
    .shape = .{ .agree = .{ "a", "b" } },
    .summary = "two values of one shape",
    .params = &.{
        .{ .name = "a", .kind = .number, .positional = true, .shaped = true },
        .{ .name = "b", .kind = .number, .positional = true, .shaped = true },
    },
};

const size: Entry = .{
    .name = "size",
    .op = tag_plain,
    .role = .signal,
    .shape = .{ .of = "x" },
    .summary = "a signal of its input's shape",
    .params = &.{.{ .name = "x", .kind = .signal, .positional = true, .shaped = true }},
};

const duo: Entry = .{
    .name = "duo",
    .op = tag_plain,
    .role = .signal,
    .shape = .{ .constructor = .{} },
    .summary = "a vec2",
    .params = &.{
        .{ .name = "x", .kind = .signal, .positional = true },
        .{ .name = "y", .kind = .signal, .positional = true },
    },
};

const trio: Entry = .{
    .name = "trio",
    .op = tag_plain,
    .role = .signal,
    .shape = .{ .constructor = .{} },
    .summary = "a vec3",
    .params = &.{
        .{ .name = "x", .kind = .signal, .positional = true },
        .{ .name = "y", .kind = .signal, .positional = true },
        .{ .name = "z", .kind = .signal, .positional = true },
    },
};

const rgb: Entry = .{
    .name = "rgb",
    .op = tag_plain,
    .role = .signal,
    .shape = .{ .constructor = .{ .colour = true, .converts = true } },
    .summary = "a colour of three numbers",
    .params = &.{
        .{ .name = "r", .kind = .number, .positional = true, .range = .{ 0, 1 }, .hint = "write each of r, g, and b from 0 to 1" },
        .{ .name = "g", .kind = .number, .positional = true, .range = .{ 0, 1 }, .hint = "write each of r, g, and b from 0 to 1" },
        .{ .name = "b", .kind = .number, .positional = true, .range = .{ 0, 1 }, .hint = "write each of r, g, and b from 0 to 1" },
    },
};

const hold: Entry = .{
    .name = "hold",
    .op = tag_plain,
    .role = .signal,
    .lanes = .region,
    .fed = true,
    .example = "hold(0)",
    .summary = "its input from one step before",
    .params = &.{.{ .name = "initial", .kind = .number, .positional = true }},
};

const label: Entry = .{
    .name = "label",
    .op = .noun,
    .role = .signal,
    .summary = "a noun",
    .params = &.{.{ .name = "text", .kind = .string, .positional = true }},
};

const link: Entry = .{
    .name = "link",
    .op = tag_plain,
    .role = .signal,
    .shape = .{ .agree = .{ "from", "to" } },
    .after = .{ .by = "after", .takes = "to" },
    .summary = "a move that may continue another",
    .params = &.{
        .{ .name = "from", .kind = .number, .shaped = true, .default = .after },
        .{ .name = "to", .kind = .number, .shaped = true },
        .{ .name = "after", .kind = .signal, .shaped = true, .default = .absent },
    },
};

const start: Entry = .{
    .name = "start",
    .op = tag_plain,
    .role = .signal,
    .lanes = .stagger,
    .summary = "a start at a cue, by lane",
    .params = &.{
        .{ .name = "at", .kind = .cue, .by_lane = true },
        .{ .name = "stagger", .kind = .time, .default = .{ .time = 0 } },
    },
};

const drive: Entry = .{
    .name = "drive",
    .op = tag_plain,
    .role = .signal,
    .summary = "a signal moved by a mover",
    .params = &.{.{ .name = "by", .kind = .mover }},
};

const slide: Entry = .{
    .name = "slide",
    .op = tag_plain,
    .role = .mover,
    .lanes = .one,
    .example = "slide(time: 1s)",
    .summary = "a mover",
    .params = &.{.{ .name = "time", .kind = .number, .live = true }},
};

const limited: Entry = .{
    .name = "limited",
    .op = tag_plain,
    .role = .signal,
    .summary = "a signal with a whole number from 1 to 3",
    .params = &.{.{ .name = "n", .kind = .integer, .positional = true, .range = .{ 1, 3 }, .hint = "write 1, 2, or 3" }},
};

const plane: Entry = .{
    .name = "plane",
    .op = tag_plain,
    .role = .signal,
    .summary = "takes a vec2 of one lane",
    .params = &.{.{ .name = "x", .kind = .signal, .positional = true, .shaped = true, .need = .{ .components = 2, .lanes = .one } }},
};

const crowd: Entry = .{
    .name = "crowd",
    .op = tag_plain,
    .role = .signal,
    .summary = "takes a number in each of many lanes",
    .params = &.{.{ .name = "x", .kind = .signal, .positional = true, .need = .{ .components = 1, .lanes = .many } }},
};

const tint: Entry = .{
    .name = "tint",
    .op = tag_plain,
    .role = .signal,
    .summary = "takes a colour",
    .params = &.{.{ .name = "x", .kind = .signal, .positional = true, .shaped = true, .need = .{ .colour = true } }},
};

const double: Entry = .{
    .name = "double",
    .op = tag_plain,
    .role = .signal,
    .folds = true,
    .shape = .{ .of = "x" },
    .summary = "twice its input",
    .params = &.{.{ .name = "x", .kind = .signal, .positional = true, .shaped = true }},
};

const entries = [_]Entry{ plain, pair, size, duo, trio, rgb, hold, label, link, start, drive, slide, limited, plane, crowd, tint, double };

fn fold(entry: *const Entry, operands: [2]f64) f64 {
    assert(std.mem.eql(u8, entry.name, "double"));
    return operands[0] * 2;
}

fn convert(entry: *const Entry, values: [4]f64) [4]f64 {
    assert(std.mem.eql(u8, entry.name, "rgb"));
    return .{ values[0] / 2, values[1] / 2, values[2] / 2, 0 };
}

fn seed_hash(base: u64, ordinal: u64) u64 {
    return base +% ordinal;
}

const vocabulary: schema.Vocabulary = .{
    .entries = &entries,
    .fold = fold,
    .convert = convert,
    .seed_hash = seed_hash,
};

const tree_size = 512;
const names_size = 64;

var fixture: parse.Fixture = undefined;
var bindings: [names_size]check.Binding = undefined;
var declarations: [names_size]check.Declaration = undefined;
var calls: [tree_size]check.Call = undefined;
var value_slab: [2 * tree_size]check.Value = undefined;
var value_items: [2 * tree_size]u32 = undefined;
var exprs: [tree_size]check.Expr = undefined;
var cue_times: [8]i64 = undefined;
var cue_forms: [8]check.CueForm = undefined;
var goals: [16]check.Goal = undefined;
var paths: [16]check.Run = undefined;
var regions: [4]check.Region = undefined;
var region_runs: [4]check.Run = undefined;
var tracks: [4]check.Track = undefined;
var modules: [4]check.Module = undefined;
var frames: [check.frames_max]check.Frame = undefined;
var instances: [names_size]check.Instance = undefined;
var tree: parse.Tree = undefined;
var checked: check.Checked = undefined;

/// Checks `source` against the vocabulary above; the diagnostics are `fixture.diagnostics`.
fn run(source: []const u8) void {
    tree = fixture.run(source);
    assert(fixture.diagnostics.total() == 0);
    checked = check.check(&tree, .{
        .vocabulary = &vocabulary,
        .modules = &modules,
        .frames = &frames,
        .instances = &instances,
        .bindings = &bindings,
        .declarations = &declarations,
        .calls = &calls,
        .values = &value_slab,
        .value_items = &value_items,
        .exprs = &exprs,
        .cue_times = &cue_times,
        .cue_forms = &cue_forms,
        .goals = &goals,
        .paths = &paths,
        .regions = &regions,
        .region_runs = &region_runs,
        .tracks = &tracks,
    }, &fixture.diagnostics);
}

/// Source that checks with no diagnostic.
fn passes(source: []const u8) !void {
    run(source);
    for (fixture.diagnostics.items()) |found| std.debug.print("{s}: {s}\n", .{ found.message_text(), found.hint_text() });
    try testing.expect(checked.ok);
}

/// Source whose first diagnostic has `code`, `message`, and `hint`, at the text `at`.
fn fails(source: []const u8, code: Code, message: []const u8, hint: []const u8, at: []const u8) !void {
    run(source);
    try testing.expect(!checked.ok);
    const found = fixture.diagnostics.items()[0];
    try testing.expectEqual(code, found.code);
    try testing.expectEqualStrings(message, found.message_text());
    try testing.expectEqualStrings(hint, found.hint_text());
    try testing.expectEqualStrings(at, source[found.start..][0..found.len]);
}

/// The expression the declaration `at` binds.
fn expression(at: usize) check.Expr {
    return checked.exprs[checked.declarations[at].signal.expr];
}

// Locks item 1: a pair of a vec2 and a vec3 fails "`a` and `b` differ", a number beside a vec2 is
// a vec2 either way round, `of` gives a signal its input's shape, and a constructor's value has
// one component a parameter, a vec3 or, with `colour`, a colour.
test "an entry's shape rule says the shape of its call" {
    try fails("x = pair(duo(1, 2), trio(1, 2, 3))\n", .wrong_shape, "`a` and `b` differ: a vec2 and a vec3", "", "pair(duo(1, 2), trio(1, 2, 3))");
    try passes("a = pair(1, duo(1, 2))\nb = pair(duo(1, 2), 1)\nc = pair(1, 2)\nd = size(trio(1, 2, 3))\ne = size(1)\nf = rgb(1, 0, 0)\n");
    try testing.expectEqual(@as(u8, 2), expression(0).shape.components);
    try testing.expectEqual(@as(u8, 2), expression(1).shape.components);
    try testing.expectEqual(@as(u8, 1), expression(2).shape.components);
    try testing.expectEqual(@as(u8, 3), expression(3).shape.components);
    try testing.expectEqual(@as(u8, 1), expression(4).shape.components);
    try testing.expect(expression(5).shape.colour);
    try fails("x = pair(1, rgb(1, 0, 0))\n", .wrong_shape, "`a` and `b` differ: a number and a colour", "write the number as a colour, such as `oklab(0.5, 0, 0)`", "pair(1, rgb(1, 0, 0))");
}

// Locks item 2: `hold(0)` is fed once by `<-`, and a region of it as one; a second feed fails
// `delay_fed_twice`, a call that is not fed fails `not_a_delay`, a hold in an expression fails.
test "a fed entry is fed by an arrow, once" {
    try passes("h = hold(0)\nh <- 1\ng = lanes(3, hold(0))\ng <- 2\n");
    try fails("h = hold(0)\nh <- 1\nh <- 2\n", .delay_fed_twice, "the delay `h` is already fed", "", "h <- 2");
    try fails("p = plain(0)\np <- 1\n", .not_a_delay, "only a delay is fed with `<-`, and `p` is not one", "declare it as `p = hold(0)`", "p");
    try fails("x = hold(0) + 1\n", .not_a_delay, "a delay is fed by its name, so it is a declaration's whole value", "declare it alone, such as `fb = hold(0)`, feed it with `fb <- …`, then use `fb`", "hold(0) + 1");
}

// Locks item 3: a noun is a declaration's whole value, and a signal where it is not.
test "an entry of kind noun is a declaration and never a value" {
    try testing.expectEqual(schema.EntryKind.noun, label.kind());
    try testing.expectEqual(schema.EntryKind.signal, plain.kind());
    try passes("n = label(\"words\")\n");
    try fails("x = label(\"words\") + 1\n", .wrong_type, "`label` describes a thing, and is not a signal", "give it a line of its own, such as `name = label(…)`", "label");
}

// Locks item 4: `link(to: 2, after: a)` takes `from` 1 from `a`, also through a region, and after
// another call it fails D9's words rebuilt from the names.
test "an entry with after continues the call it names" {
    try passes("a = link(from: 0, to: 1)\nb = link(to: 2, after: a)\nr = lanes(2, link(from: 0, to: 5))\nc = link(to: 3, after: r)\n");
    var seen: u32 = 0;
    for (checked.calls, 0..) |call, at| {
        if (!std.mem.eql(u8, call.entry.name, "link")) continue;
        const found = checked.call_values(@intCast(at));
        if (found[1].number == 2) {
            try testing.expectEqual(@as(f64, 1), found[0].number);
            seen += 1;
        }
        if (found[1].number == 3) {
            try testing.expectEqual(@as(f64, 5), found[0].number);
            seen += 1;
        }
    }
    try testing.expectEqual(@as(u32, 2), seen);
    const hint = "`from` may be left out only when `after` names a link";
    try fails("w = plain(1)\nd = link(to: 3, after: w)\n", .missing_argument, "link needs `from`, since `after` is not a name bound to a link", hint, "w");
    try fails("d = link(to: 3)\n", .missing_argument, "link needs `from`", hint, "link");
    try fails("v = duo(1, 2)\na = link(from: 0, to: 1, after: v)\n", .wrong_shape, "`after` is a vec2, and this link a number", "", "link(from: 0, to: 1, after: v)");
}

// Locks item 5: `start(at: beat[lane])` has 3 lanes in `lanes(3, …)` and a cue by lane; outside a
// region it fails, and with `stagger:` it fails both set.
test "a cue by lane is taken wherever a parameter declares it" {
    try passes("cue beat = [1s, 2s, 3s]\nx = lanes(3, start(at: beat[lane]))\n");
    var by_lane = false;
    var lanes_found: u32 = 0;
    for (checked.exprs) |item| {
        if (item.tag != .call) continue;
        if (!std.mem.eql(u8, checked.calls[item.a].entry.name, "start")) continue;
        lanes_found = item.lanes;
        by_lane = checked.call_values(item.a)[0] == .cue_by_lane;
    }
    try testing.expect(by_lane);
    try testing.expectEqual(@as(u32, 3), lanes_found);
    try fails("cue beat = [1s, 2s, 3s]\nx = start(at: beat[lane])\n", .wrong_lanes, "`beat[lane]` is a cue for each lane, so it is used inside `lanes(n, …)`", "wrap the call in a region, such as `lanes(3, …)`", "beat[lane]");
    try fails("cue beat = [1s, 2s, 3s]\nx = lanes(3, start(at: beat[lane], stagger: 1ms))\n", .wrong_lanes, "`stagger:` and a cue chosen by lane both set when each lane starts", "each lane already starts at its own cue; drop `stagger:`", "1ms");
    try fails("cue beat = [1s, 2s, 3s]\nx = lanes(3, cue_taker(beat[lane]))\n", .unknown_call, "there is no call `cue_taker`", "", "cue_taker");
}

// Locks the mover rule: a mover whose live `time` has 3 lanes fails for a call that takes it, and
// one of one lane passes; a non-mover reads "`by` takes a mover" with the vocabulary's example.
test "a mover parameter holds its mover's signals to one lane" {
    try passes("x = drive(by: slide(time: 1))\n");
    try fails("w = lanes(3, lane)\nx = drive(by: slide(time: w))\n", .wrong_lanes, "`time` takes one value for every lane, found 3 lanes", "a node has one law; let the lanes differ in what it reads instead", "w");
    try fails("x = drive(by: 3)\n", .wrong_type, "`by` takes a mover", "`slide(time: 1s)`", "3");
}

// Locks item 6: a number outside a range is refused at the number with the parameter's name and
// hint, an integer must be whole, a constructor's component is held to its own range, and a
// number inside is kept.
test "a parameter's range refuses a number outside it" {
    try passes("a = plain(0.5)\nb = limited(3)\nc = plain(1 / 4)\n");
    try fails("a = plain(2)\n", .out_of_range, "`level` is from 0 to 1", "write a level from 0 to 1", "2");
    try fails("a = plain(1 + 1)\n", .out_of_range, "`level` is from 0 to 1", "write a level from 0 to 1", "1 + 1");
    try fails("a = limited(4)\n", .out_of_range, "`n` is a whole number from 1 to 3", "write 1, 2, or 3", "4");
    try fails("a = limited(2.5)\n", .out_of_range, "`n` is a whole number from 1 to 3", "write 1, 2, or 3", "2.5");
    try fails("a = pair(rgb(0, 0, 1.5), 1)\n", .out_of_range, "`b` is from 0 to 1", "write each of r, g, and b from 0 to 1", "1.5");
}

// Locks item 6's need: a signal that does not have the shape or the lanes a parameter takes
// fails "`x` of plane takes a vec2, and this is one number" and the like.
test "a parameter's need refuses a signal of another shape or lanes" {
    try passes("a = plane(duo(1, 2))\nb = lanes(3, crowd(lane))\nc = tint(rgb(1, 0, 0))\n");
    try fails("a = plane(1)\n", .wrong_shape, "`x` of plane takes a vec2, and this is one number", "", "1");
    try fails("a = plane(lanes(3, duo(1, 2)))\n", .wrong_shape, "`x` of plane takes a vec2, and this is 3 lanes of a vec2", "", "lanes(3, duo(1, 2))");
    try fails("a = crowd(1)\n", .wrong_shape, "`x` of crowd takes a number in each of many lanes, and this is one number", "", "1");
    try fails("a = tint(duo(1, 2))\n", .wrong_shape, "`x` of tint takes a colour, and this is a vec2", "", "duo(1, 2)");
}

// Locks item 7: a call of constants folds through the vocabulary: `double(2)` is the constant 4,
// and `double(double(1.5))` is 6.
test "an entry that folds is a constant when its inputs are" {
    try passes("a = double(2)\nb = double(double(1.5))\nc = double(plain(1))\n");
    try testing.expectEqual(check.Expr.Tag.constant, expression(0).tag);
    try testing.expectEqual(@as(f64, 4), expression(0).number);
    try testing.expectEqual(@as(f64, 6), expression(1).number);
    try testing.expectEqual(check.Expr.Tag.call, expression(2).tag);
}

// Locks item 8: a constructor that `converts` gives the vocabulary's values, here halved:
// `rgb(1, 0.5, 0)` held by a shaped number is the vector 0.5, 0.25, 0.
test "a constructor's conversion is the vocabulary's" {
    try passes("a = pair(rgb(1, 0.5, 0), rgb(0, 0, 0))\n");
    for (checked.calls, 0..) |call, at| {
        if (!std.mem.eql(u8, call.entry.name, "pair")) continue;
        const found = checked.call_values(@intCast(at))[0].vector;
        try testing.expectEqual(@as(f64, 0.5), found.values[0]);
        try testing.expectEqual(@as(f64, 0.25), found.values[1]);
        try testing.expectEqual(@as(f64, 0), found.values[2]);
        try testing.expect(found.shape.colour);
    }
}

// Locks item 9: `lanes(n, body)` is the language's own form, found though the vocabulary holds no
// entry of that name: its value is its body's shape and it has n lanes.
test "a region is the language's own form" {
    try passes("x = lanes(4, duo(1, lane))\n");
    try testing.expectEqual(@as(u8, 2), expression(0).shape.components);
    try testing.expectEqual(@as(u32, 4), expression(0).lanes);
    try testing.expectEqual(schema.Op.lanes, checked.calls[expression(0).a].entry.op);
    try fails("x = lanes(0, 1)\n", .out_of_range, "a region has from 1 to 1048576 lanes", "for example `lanes(1000, …)`", "0");
}

// Locks the hints that name an example: a feed to an unknown name gives the fed entry's example,
// and a vocabulary with none gives no hint.
test "a hint names the vocabulary's example" {
    try fails("x <- 1\n", .unknown_name, "`x` is not declared", "declare it above, such as `x = hold(0)`", "x");
}
