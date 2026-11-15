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
//! ## 2. The Entries
//! Four small entries, written here, of op `client`: `osc`, `filt`, `field`, and `gate`.

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
fn checks(entries: []const schema.Entry, source: []const u8) !void {
    try testing.expectError(error.Invalid, compiled.compile_client(entries, &.{}, source));
    try testing.expectEqual(weft.lang.diagnostic.Code.refused, compiled.errors()[0].code);
}

/// The output slot and lanes of the expression the declaration `at` of the file binds.
fn expression(at: usize) check.Expr {
    const declaration = compiled.checked.declarations[at];
    return compiled.checked.exprs[declaration.signal.expr];
}

fn fails(entries: []const schema.Entry, source: []const u8, message: []const u8, hint: []const u8) !void {
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
