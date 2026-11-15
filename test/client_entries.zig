//! What a client's entry says about its call (step 54): the lane rule, the events, the outputs'
//! names, and the hint for a fixed parameter, all fields of `schema.Entry`.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What Is Locked
//! A client's entry of op `client` is checked beside Weft's table, and Weft's back end then refuses
//! it (`refused`), so each test reads what the checker made, `compiled.checked`:
//! - a first output's name and the names after it are outputs 0, 1, 2, and a wrong name gets a
//!   hint listing every one, as Weft's `bounce` does;
//! - an entry with no first name has the call itself as output 0;
//! - an entry's `lanes` of `region` gives its call the region's lanes, the default `inputs` the
//!   lanes of what it reads;
//! - `fixed_hint` is what a signal given to a fixed parameter is told, and without one the hint
//!   says what to write;
//! - every entry of Weft's table fits `schema.outputs_max`.
//!
//! Step 55a adds what a client's entry says the checker acts on, each a field of `schema.Entry`
//! or `schema.Param`:
//! - `shape`: `agree` holds two parameters to one shape, a number broadcast; `of` takes a
//!   parameter's shape; `constructor` makes one component a parameter;
//! - `fed`: the call may be fed by `<-`, once;
//! - `after`: a parameter left out takes the `to` of the call another parameter names, and
//!   fails with its own words after any other;
//! - `by_lane` on a cue, with the `stagger` lane rule, takes `series[lane]` inside a region;
//! - a parameter of kind `mover` holds its mover's signals to one lane.
//!
//! ## 2. The Entries
//! Small entries, written here, of op `client`: `osc`, `filt`, `field`, and `gate`, and for
//! step 55a `pair`, `size`, `make3`, `hold`, `chain`, `begin`, and `drive`.

const std = @import("std");
const testing = std.testing;
const weft = @import("weft");
const schema = weft.lang.schema;
const check = weft.lang.check;

const Compiled = weft.lang.Compiled(.{ .tokens = 256, .tree = 256, .names = 16, .nodes = 32, .slab = 128, .cues = 4, .libraries = 0, .modules = 4 });
var compiled: Compiled = undefined;

const osc: schema.Entry = .{
    .name = "osc",
    .op = .client,
    .role = .signal,
    .first_output = "first",
    .outputs = &.{ "second", "third" },
    .summary = "an oscillator with three outputs",
    .params = &.{.{ .name = "hz", .kind = .number, .positional = true, .doc = "the rate" }},
};

const filt: schema.Entry = .{
    .name = "filt",
    .op = .client,
    .role = .signal,
    .outputs = &.{"band"},
    .summary = "a filter whose first output has no name",
    .params = &.{.{ .name = "input", .kind = .number, .positional = true, .doc = "the input" }},
};

const field: schema.Entry = .{
    .name = "field",
    .op = .client,
    .role = .signal,
    .lanes = .region,
    .summary = "a signal that takes the region's lanes",
    .params = &.{},
};

const plain: schema.Entry = .{
    .name = "plain",
    .op = .client,
    .role = .signal,
    .summary = "a signal that takes its inputs' lanes",
    .params = &.{.{ .name = "input", .kind = .number, .positional = true, .doc = "the input" }},
};

fn gate(hint: []const u8) schema.Entry {
    return .{
        .name = "gate",
        .op = .client,
        .role = .signal,
        .fixed_hint = hint,
        .summary = "a signal with a parameter fixed at build",
        .params = &.{.{ .name = "level", .kind = .number, .positional = true, .live = false, .doc = "the level" }},
    };
}

/// Checks `source` with `entries`, which the back end then refuses as `refused`.
fn checks(comptime entries: []const schema.Entry, source: []const u8) !void {
    try testing.expectError(error.Invalid, compiled.compile_client(entries, &.{}, source));
    try testing.expectEqual(weft.lang.diagnostic.Code.refused, compiled.errors()[0].code);
}

/// The output slot and lanes of the expression the declaration `at` of the file binds.
fn expression(at: usize) check.Expr {
    const declaration = compiled.checked.declarations[at];
    return compiled.checked.exprs[declaration.signal.expr];
}

fn fails(comptime entries: []const schema.Entry, source: []const u8, message: []const u8, hint: []const u8) !void {
    try testing.expectError(error.Invalid, compiled.compile_client(entries, &.{}, source));
    const found = compiled.errors()[0];
    try testing.expectEqualStrings(message, found.message_text());
    try testing.expectEqualStrings(hint, found.hint_text());
}

// Locks a first output's name: `x.first`, `x.second`, `x.third` are slots 0, 1, 2, and `x.fourth`
// is `unknown_output` at `fourth`, with a hint that lists the three.
test "an entry names its first output and the ones after it" {
    const entries = [_]schema.Entry{osc};
    try checks(&entries, "x = osc(1)\na = x.first\nb = x.second\nc = x.third\n");
    try testing.expectEqual(@as(u32, 0), expression(1).b);
    try testing.expectEqual(@as(u32, 1), expression(2).b);
    try testing.expectEqual(@as(u32, 2), expression(3).b);
    try testing.expectEqual(@as(usize, 4), compiled.checked.declarations.len);

    const source = "x = osc(1)\nd = x.fourth\n";
    try testing.expectError(error.Invalid, compiled.compile_client(&entries, &.{}, source));
    const found = compiled.errors()[0];
    try testing.expectEqual(weft.lang.diagnostic.Code.unknown_output, found.code);
    try testing.expectEqualStrings("osc has no output `fourth`", found.message_text());
    try testing.expectEqualStrings("its outputs are `first`, `second`, and `third`", found.hint_text());
    try testing.expectEqualStrings("fourth", source[found.start..][0..found.len]);
}

// Locks an entry with no first name: `band` is slot 1, and `low` is refused with the call itself
// named in the hint.
test "an entry with no first name has the call itself as output 0" {
    const entries = [_]schema.Entry{filt};
    try checks(&entries, "f = filt(1)\nb = f.band\n");
    try testing.expectEqual(@as(u32, 1), expression(1).b);
    try fails(&entries, "f = filt(1)\nb = f.low\n", "filt has no output `low`", "its outputs are the call itself and `band`");
}

// Locks an entry with only a named first output: `x.out` is slot 0, and `x.bad` is
// `unknown_output` at `bad` with the hint "its only output is `out`", not a list.
test "an entry with one named output says so" {
    const solo: schema.Entry = .{
        .name = "solo",
        .op = .client,
        .role = .signal,
        .first_output = "out",
        .summary = "a signal with one named output",
        .params = &.{.{ .name = "input", .kind = .number, .positional = true, .doc = "the input" }},
    };
    const entries = [_]schema.Entry{solo};
    try checks(&entries, "x = solo(1)\ny = x.out\n");
    try testing.expectEqual(@as(u32, 0), expression(1).b);
    const source = "x = solo(1)\ny = x.bad\n";
    try testing.expectError(error.Invalid, compiled.compile_client(&entries, &.{}, source));
    const found = compiled.errors()[0];
    try testing.expectEqual(weft.lang.diagnostic.Code.unknown_output, found.code);
    try testing.expectEqualStrings("solo has no output `bad`", found.message_text());
    try testing.expectEqualStrings("its only output is `out`", found.hint_text());
    try testing.expectEqualStrings("bad", source[found.start..][0..found.len]);
}

// Locks Weft's own `bounce`: `position` is slot 0 as before, and `speed` gets the hint as it read.
test "a bounce's outputs read as they did" {
    try testing.expectEqual(@as(?u32, 0), weft.lang.table.find("bounce", .signal).?.output("position"));
    try testing.expectEqual(@as(?u32, 1), weft.lang.table.find("bounce", .signal).?.output("velocity"));
    try fails(&.{}, "cue c = 0s\nb = bounce(0..1, speed: 1, at: c)\ns = b.speed\n", "bounce has no output `speed`", "its outputs are `position` and `velocity`");
}

// Locks the lane rule: an entry with `lanes = .region` has 4 lanes inside `lanes(4, …)` and 1
// outside, and the same entry with the default has the lanes of its inputs, 1 for a number.
test "an entry's lane rule says how its call takes lanes" {
    const entries = [_]schema.Entry{ field, plain };
    try checks(&entries, "a = lanes(4, field())\nb = field()\nc = lanes(4, plain(1))\n");
    try testing.expectEqual(@as(u32, 4), expression(0).lanes);
    try testing.expectEqual(@as(u32, 1), expression(1).lanes);
    var found: u32 = 0;
    for (compiled.checked.exprs) |item| {
        if (item.tag != .call) continue;
        if (!std.mem.eql(u8, compiled.checked.calls[item.a].entry.name, "plain")) continue;
        try testing.expectEqual(@as(u32, 1), item.lanes);
        found += 1;
    }
    try testing.expectEqual(@as(u32, 1), found);
    try testing.expectEqual(@as(u32, 4), expression(2).lanes);
    try testing.expectEqual(schema.LaneRule.region, field.lane_rule());
    try testing.expectEqual(schema.LaneRule.inputs, plain.lane_rule());
    const noun: schema.Entry = .{ .name = "n", .op = .noun, .role = .signal, .summary = "", .params = &.{} };
    try testing.expectEqual(schema.LaneRule.apart, noun.lane_rule());
}

// Locks the fixed hint: a signal given to a parameter fixed at build is told the entry's sentence,
// and, with none, to write a number.
test "a fixed parameter's hint is the entry's own" {
    const message = "gate's `level` is fixed when it is built, so a signal cannot set it";
    try fails(&.{gate("use a track")}, "w = gate(1)\nx = gate(w)\n", message, "use a track");
    try fails(&.{gate("")}, "w = gate(1)\nx = gate(w)\n", message, "write a number");
}

// Locks the limit: no entry of Weft's table, and none of the client entries here, has more than
// `outputs_max` outputs.
test "every entry fits the outputs limit" {
    for (weft.lang.table.entries) |entry| {
        try testing.expect(entry.outputs.len + @intFromBool(entry.first_output.len > 0) <= schema.outputs_max);
    }
    try testing.expect(osc.outputs.len + 1 <= schema.outputs_max);
}

const pair: schema.Entry = .{
    .name = "pair",
    .op = .client,
    .role = .signal,
    .shape = .{ .agree = .{ "a", "b" } },
    .summary = "two values of one shape",
    .params = &.{
        .{ .name = "a", .kind = .number, .positional = true, .shaped = true, .doc = "the first" },
        .{ .name = "b", .kind = .number, .positional = true, .shaped = true, .doc = "the second" },
    },
};

const size: schema.Entry = .{
    .name = "size",
    .op = .client,
    .role = .signal,
    .shape = .{ .of = "x" },
    .summary = "a signal of its input's shape",
    .params = &.{.{ .name = "x", .kind = .signal, .positional = true, .shaped = true, .doc = "the input" }},
};

const make3: schema.Entry = .{
    .name = "make3",
    .op = .client,
    .role = .signal,
    .shape = .{ .constructor = .{} },
    .summary = "a vec3 of three numbers",
    .params = &.{
        .{ .name = "x", .kind = .number, .positional = true, .doc = "the first" },
        .{ .name = "y", .kind = .number, .positional = true, .doc = "the second" },
        .{ .name = "z", .kind = .number, .positional = true, .doc = "the third" },
    },
};

const hold: schema.Entry = .{
    .name = "hold",
    .op = .client,
    .role = .signal,
    .lanes = .region,
    .fed = true,
    .summary = "its input from one step before",
    .params = &.{.{ .name = "initial", .kind = .number, .positional = true, .doc = "the start" }},
};

const chain: schema.Entry = .{
    .name = "chain",
    .op = .client,
    .role = .signal,
    .shape = .{ .agree = .{ "from", "to" } },
    .after = .{ .by = "after", .takes = "to" },
    .summary = "a move that may continue another",
    .params = &.{
        .{ .name = "from", .kind = .number, .shaped = true, .default = .after, .doc = "where it starts" },
        .{ .name = "to", .kind = .number, .shaped = true, .doc = "where it ends" },
        .{ .name = "after", .kind = .signal, .shaped = true, .default = .absent, .doc = "the move before" },
    },
};

const begin: schema.Entry = .{
    .name = "begin",
    .op = .client,
    .role = .signal,
    .lanes = .stagger,
    .summary = "a start at a cue, by lane",
    .params = &.{
        .{ .name = "at", .kind = .cue, .by_lane = true, .doc = "the cue" },
        .{ .name = "stagger", .kind = .time, .default = .{ .time = 0 }, .doc = "the delay a lane" },
    },
};

const drive: schema.Entry = .{
    .name = "drive",
    .op = .client,
    .role = .signal,
    .summary = "a signal moved by a mover",
    .params = &.{.{ .name = "by", .kind = .mover, .doc = "the law" }},
};

// Locks `agree`: a vec2 and a vec3 fail "`a` and `b` differ: a vec2 and a vec3" at the call, a
// number beside a vec2 gives a vec2 either way round, and two numbers give a number.
test "an entry's agree rule holds two parameters to one shape" {
    const entries = [_]schema.Entry{pair};
    try fails(&entries, "x = pair(vec2(1, 2), vec3(1, 2, 3))\n", "`a` and `b` differ: a vec2 and a vec3", "");
    try checks(&entries, "x = pair(1, vec2(1, 2))\ny = pair(vec2(1, 2), 1)\nz = pair(1, 2)\n");
    try testing.expectEqual(@as(u8, 2), expression(0).shape.components);
    try testing.expectEqual(@as(u8, 2), expression(1).shape.components);
    try testing.expectEqual(@as(u8, 1), expression(2).shape.components);
    try fails(&entries, "x = pair(1, srgb(1, 0, 0))\n", "`a` and `b` differ: a number and a colour", "write the number as a colour, such as `oklab(0.5, 0, 0)`");
}

// Locks `of`: `size(x)` is a number for a number, a vec3 for a vec3, and a colour for a colour.
test "an entry's of rule takes a parameter's shape" {
    const entries = [_]schema.Entry{size};
    try checks(&entries, "a = size(1)\nb = size(vec3(1, 2, 3))\nc = size(srgb(1, 0, 0))\n");
    try testing.expectEqual(@as(u8, 1), expression(0).shape.components);
    try testing.expectEqual(@as(u8, 3), expression(1).shape.components);
    try testing.expect(!expression(1).shape.colour);
    try testing.expectEqual(@as(u8, 3), expression(2).shape.components);
    try testing.expect(expression(2).shape.colour);
}

// Locks `constructor`: `make3(1, 2, 3)` is a vec3, and a colour constructor's value is a colour.
test "an entry's constructor rule makes one component a parameter" {
    const entries = [_]schema.Entry{make3};
    try checks(&entries, "v = make3(1, 2, 3)\n");
    try testing.expectEqual(@as(u8, 3), expression(0).shape.components);
    try testing.expect(!expression(0).shape.colour);
    comptime var colour = make3;
    colour.shape = .{ .constructor = .{ .colour = true } };
    try checks(&.{colour}, "v = make3(1, 2, 3)\n");
    try testing.expect(expression(0).shape.colour);
}

// Locks `fed`: `h = hold(0)` is fed once by `h <- 1`, a second feed fails `delay_fed_twice`, a
// call that is not fed fails `not_a_delay`, and a region of `hold` is fed as one.
test "a fed entry is fed by an arrow once" {
    const entries = [_]schema.Entry{ hold, plain };
    try checks(&entries, "h = hold(0)\nh <- 1\ng = lanes(3, hold(0))\ng <- 2\n");
    try testing.expectError(error.Invalid, compiled.compile_client(&entries, &.{}, "h = hold(0)\nh <- 1\nh <- 2\n"));
    try testing.expectEqual(weft.lang.diagnostic.Code.delay_fed_twice, compiled.errors()[0].code);
    try testing.expectEqualStrings("the delay `h` is already fed", compiled.errors()[0].message_text());
    try testing.expectError(error.Invalid, compiled.compile_client(&entries, &.{}, "p = plain(0)\np <- 1\n"));
    try testing.expectEqual(weft.lang.diagnostic.Code.not_a_delay, compiled.errors()[0].code);
    try testing.expectError(error.Invalid, compiled.compile_client(&entries, &.{}, "x = hold(0) + 1\n"));
    try testing.expectEqual(weft.lang.diagnostic.Code.not_a_delay, compiled.errors()[0].code);
}

// Locks `after`: `from` is left out after a call of the same entry, and is that call's `to` (1),
// also through a region; after another call it fails with the entry's name and the parameters'
// names; and an `after` of another shape fails "`after` is a vec2, and this chain a number".
test "an entry with after continues the call it names" {
    const entries = [_]schema.Entry{ chain, plain };
    try checks(&entries, "a = chain(from: 0, to: 1)\nb = chain(to: 2, after: a)\n" ++
        "r = lanes(2, chain(from: 0, to: 5))\nc = chain(to: 3, after: r)\n");
    var found: u32 = 0;
    for (compiled.checked.calls, 0..) |call, at| {
        if (!std.mem.eql(u8, call.entry.name, "chain")) continue;
        const values = compiled.checked.call_values(@intCast(at));
        if (values[1].number == 2) {
            try testing.expectEqual(@as(f64, 1), values[0].number);
            found += 1;
        }
        if (values[1].number == 3) {
            try testing.expectEqual(@as(f64, 5), values[0].number);
            found += 1;
        }
    }
    try testing.expectEqual(@as(u32, 2), found);
    const hint = "`from` may be left out only when `after` names a chain";
    try fails(&entries, "w = plain(1)\nd = chain(to: 3, after: w)\n", "chain needs `from`, since `after` is not a name bound to a chain", hint);
    try fails(&entries, "d = chain(to: 3)\n", "chain needs `from`", hint);
    try fails(&entries, "v = vec2(1, 2)\na = chain(from: 0, to: 1, after: v)\n", "`after` is a vec2, and this chain a number", "");
}

// Locks `by_lane` on a client's cue: inside `lanes(3, …)` `begin(at: beat[lane])` has 3 lanes and
// its `at` is a cue by lane; outside a region the cue fails; with `stagger:` it fails both set.
test "a client's cue by lane takes series[lane] in a region" {
    const entries = [_]schema.Entry{begin};
    const head = "cue beat = [1s, 2s, 3s]\n";
    try checks(&entries, head ++ "x = lanes(3, begin(at: beat[lane]))\n");
    var by_lane = false;
    for (compiled.checked.calls, 0..) |call, at| {
        if (!std.mem.eql(u8, call.entry.name, "begin")) continue;
        by_lane = compiled.checked.call_values(@intCast(at))[0] == .cue_by_lane;
    }
    try testing.expect(by_lane);
    var lanes: u32 = 0;
    for (compiled.checked.exprs) |item| {
        if (item.tag != .call) continue;
        if (std.mem.eql(u8, compiled.checked.calls[item.a].entry.name, "begin")) lanes = item.lanes;
    }
    try testing.expectEqual(@as(u32, 3), lanes);
    try fails(&entries, head ++ "x = begin(at: beat[lane])\n", "`beat[lane]` is a cue for each lane, so it is used inside `lanes(n, …)`", "wrap the call in a region, such as `lanes(3, …)`");
    try fails(&entries, head ++ "x = lanes(3, begin(at: beat[lane], stagger: 1ms))\n", "`stagger:` and a cue chosen by lane both set when each lane starts", "each lane already starts at its own cue; drop `stagger:`");
    comptime var plain_cue = begin;
    plain_cue.params = &.{
        .{ .name = "at", .kind = .cue, .doc = "the cue" },
        .{ .name = "stagger", .kind = .time, .default = .{ .time = 0 }, .doc = "the delay a lane" },
    };
    try testing.expectError(error.Invalid, compiled.compile_client(&.{plain_cue}, &.{}, head ++ "x = lanes(3, begin(at: beat[lane]))\n"));
    try testing.expectEqual(weft.lang.diagnostic.Code.wrong_lanes, compiled.errors()[0].code);
}

// Locks the mover rule: a mover whose live `overshoot` has 3 lanes fails "`overshoot` takes one
// value for every lane, found 3 lanes" for a client's `drive`, and one of one lane passes.
test "a client's mover parameter holds its signals to one lane" {
    const entries = [_]schema.Entry{drive};
    try checks(&entries, "x = drive(by: spring(time: 1s, overshoot: 0.1))\n");
    try fails(&entries, "w = lanes(3, lane)\nx = drive(by: spring(time: 1s, overshoot: w))\n", "`overshoot` takes one value for every lane, found 3 lanes", "a node has one law; let the lanes differ in what it reads instead");
}

// Locks `of` on a shaped number: `size(2)` is one value and `size(vec2(1, 2))`, arriving as a
// constant vector, is a vec2, where a signal parameter's expression gave its shape before.
test "an entry's of rule reads a number parameter's shape" {
    comptime var numbers = size;
    numbers.params = &.{.{ .name = "x", .kind = .number, .positional = true, .shaped = true, .doc = "the input" }};
    try checks(&.{numbers}, "a = size(2)\nb = size(vec2(1, 2))\n");
    try testing.expectEqual(@as(u8, 1), expression(0).shape.components);
    try testing.expectEqual(@as(u8, 2), expression(1).shape.components);
}

// Step 56: a client's entries are joined to Weft's at compile time, and the formatter, the hint
// for a misspelt call, and a defaulted integer or a live frequency read the one list.

const mark: schema.Entry = .{
    .name = "mark",
    .op = .client,
    .role = .signal,
    .summary = "a signal with two named parameters",
    .params = &.{
        .{ .name = "at", .kind = .number, .positional = true, .doc = "where" },
        .{ .name = "size", .kind = .number, .default = .{ .number = 1 }, .doc = "how big" },
        .{ .name = "tint", .kind = .number, .default = .{ .number = 0 }, .doc = "which shade" },
    },
};

const repeat: schema.Entry = .{
    .name = "repeat",
    .op = .client,
    .role = .signal,
    .summary = "a signal with a defaulted integer",
    .params = &.{.{ .name = "count", .kind = .integer, .default = .{ .number = 3 }, .doc = "how many" }},
};

const ring: schema.Entry = .{
    .name = "ring",
    .op = .client,
    .role = .signal,
    .summary = "a signal with a live frequency",
    .params = &.{.{ .name = "rate", .kind = .frequency, .positional = true, .live = true, .doc = "cycles a second" }},
};

/// The value of the first parameter of the call the declaration `at` of the file binds.
fn first_value(at: usize) check.Value {
    const call = compiled.checked.calls[expression(at).a];
    return compiled.checked.values[call.values];
}

// Locks the formatter's use of a client's entries: `mark(1, tint: 2, size: 3)` becomes `mark(1,
// size: 3, tint: 2)` through `entries_of`, the order of the entry's parameters, and keeps its
// written order through Weft's own list, which does not know `mark`.
test "a client's call formats into its entry's order" {
    const clients = [_]schema.Entry{mark};
    try checks(&clients, "m = mark(1, tint: 2, size: 3)\n");
    var buffer: [256]u8 = undefined;
    const joined = try weft.lang.format.format(&compiled.syntax.tree, weft.lang.entries_of(&clients), &buffer);
    try testing.expectEqualStrings("m = mark(1, size: 3, tint: 2)\n", joined);
    const alone = try weft.lang.format.format(&compiled.syntax.tree, &weft.lang.table.entries, &buffer);
    try testing.expectEqualStrings("m = mark(1, tint: 2, size: 3)\n", alone);
}

// Locks the hint for a misspelt call: `marks(1)` beside a client's `mark` is told `mark`, and a
// Weft call is still offered (`hold`, for `holt`).
test "a misspelt client call gets did you mean" {
    const clients = [_]schema.Entry{mark};
    try fails(&clients, "m = marks(1)\n", "there is no call `marks`", "did you mean `mark`?");
    try fails(&clients, "m = noice(1)\n", "there is no call `noice`", "did you mean `noise`?");
}

// Locks TW10: a defaulted integer and a written one both read `.integer = 3`.
test "a defaulted integer reads as an integer" {
    const clients = [_]schema.Entry{repeat};
    try checks(&clients, "a = repeat()\nb = repeat(count: 3)\n");
    try testing.expectEqual(check.Value{ .integer = 3 }, first_value(0));
    try testing.expectEqual(check.Value{ .integer = 3 }, first_value(1));
}

// Locks TW1: a live frequency given `2hz` reads `.frequency = 2`, given a signal's name reads
// `.signal`, and given the bare number 2 is today's error with the hint to write the unit.
test "a live frequency takes a signal and a literal needs its unit" {
    const clients = [_]schema.Entry{ osc, ring };
    try checks(&clients, "a = ring(2hz)\ns = osc(1)\nb = ring(s)\n");
    try testing.expectEqual(check.Value{ .frequency = 2 }, first_value(0));
    try testing.expectEqual(.signal, std.meta.activeTag(first_value(2)));
    try fails(&clients, "a = ring(2)\n", "`rate` takes a frequency", "write `2hz`");
}
