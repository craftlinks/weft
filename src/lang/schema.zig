//! The table of primitives: every call the language knows, as data.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a Table
//! The parser and the checker never name a primitive. A call is checked against its entry here:
//! its parameters, in order, each with a kind, whether a signal may set it, whether it may be
//! written by position, and its default. So the checker is one loop over any entry, the formatter
//! orders named arguments by the same entry, and step 14's `describe` prints this table, which a
//! client extends with its own nouns. A back end then reads each call by its entry's `op`.
//!
//! ## 2. Roles
//! An entry is a signal or a mover. `spring` and `newtonian` have one of each: with goals they are
//! signals, and in a `by:` slot, where the kind is `mover`, they are a follower's law. A lookup
//! names the role it wants, so the two never meet.
//!
//! ## 3. Names Match the Builder
//! Every entry is one builder call with the builder's own names, so the table, the builder, and
//! its documentation say the same thing. Shorter names come from modules (step 13).
//!
//! ## 4. TigerStyle Invariants
//! - The table is comptime and checked: positional parameters come first, names are unique in an
//!   entry, a default suits its kind, and an entry has at most `params_max` parameters.

const std = @import("std");
const assert = std.debug.assert;
const wave = @import("../core/wave.zig");
const noise = @import("../core/noise.zig");
const simulation = @import("../core/simulation.zig");
const graph = @import("../core/graph.zig");

pub const params_max = 8;

pub const Kind = enum {
    /// A number literal.
    number,
    /// A whole number literal, at least zero.
    integer,
    /// A time literal, in whole flicks.
    time,
    /// A frequency literal, in hz.
    frequency,
    /// Any signal: a name, a call, arithmetic, or a number, which becomes a constant node.
    signal,
    /// A cue: its name, or an element of a series.
    cue,
    /// A cue series by name, or one cue.
    cues,
    /// A list of goals, or the name of one.
    path,
    /// A list of ranges, or the name of one.
    regions,
    number_range,
    time_range,
    /// One of the parameter's `words`.
    word,
    /// One of the easing words, or a cubic Bezier's four control points, `[x1, y1, x2, y2]`.
    ease,
    /// A call to a mover entry.
    mover,
    /// A whole number; by default worked out from the declaration's name.
    seed,
};

pub const Default = union(enum) {
    required,
    /// Absent, which the op understands: no `after`.
    absent,
    number: f64,
    time: i64,
    /// An index into the parameter's `words`.
    word: u8,
    time_range: [2]i64,
    /// From minus to plus infinity.
    unbounded,
    /// From the declaration's name.
    seed,
    /// The whole series, or one cue.
    whole,
};

pub const Param = struct {
    name: []const u8,
    kind: Kind,
    /// A signal may set it, read at each step (`graph.zig` section 14).
    live: bool = false,
    positional: bool = false,
    /// It takes a vector or a colour of one shape as well as one value (step 16), and the back
    /// end builds one node per component.
    shaped: bool = false,
    default: Default = .required,
    words: []const []const u8 = &.{},
};

pub const Role = enum { signal, mover };

/// What a back end builds for an entry.
pub const Op = enum {
    wave,
    noise,
    tween,
    spring,
    newtonian,
    chase,
    oscillator,
    follow,
    shift,
    delay,
    bounce,
    crossing,
    cues,
    input,
    map,
    spring_mover,
    newtonian_mover,
    /// `vec2`, `vec3`, and `oklab`: scalars packed into one value (step 16).
    pack,
    /// `srgb`: a colour from three numbers, converted to OKLab at compile time.
    srgb,
    /// A client's noun: checked like the rest, built by the client from `Checked.calls`.
    client,
};

pub const Entry = struct {
    name: []const u8,
    op: Op,
    role: Role,
    params: []const Param,
    /// Its outputs beyond the first, by name; the first is the call itself.
    outputs: []const []const u8 = &.{},
    summary: []const u8,

    /// The index of the parameter `name`, if the entry has one.
    pub fn param(entry: *const Entry, name: []const u8) ?u32 {
        for (entry.params, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate.name, name)) return @intCast(index);
        }
        return null;
    }

    pub fn positional_count(entry: *const Entry) u32 {
        var count: u32 = 0;
        for (entry.params) |candidate| count += @intFromBool(candidate.positional);
        return count;
    }

    /// The index of output `name`: 0 is the call itself.
    pub fn output(entry: *const Entry, name: []const u8) ?u32 {
        if (std.mem.eql(u8, name, "position") and entry.op == .bounce) return 0;
        for (entry.outputs, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate, name)) return @intCast(index + 1);
        }
        return null;
    }
};

fn words_of(comptime E: type) []const []const u8 {
    return comptime std.meta.fieldNames(E);
}

pub const ease_words: []const []const u8 = &.{ "linear", "in", "out", "in_out" };
pub const wave_words = words_of(wave.Shape);
pub const noise_words = words_of(noise.Shape);
pub const pick_words = words_of(simulation.Pick);
pub const shift_words = words_of(simulation.ShiftShape);
pub const direction_words = words_of(graph.Crossing.Direction);

/// The value of word `index` of an enum whose words were taken from its fields.
pub fn word_value(comptime E: type, index: u8) E {
    assert(index < @typeInfo(E).@"enum".field_names.len);
    return @fromBackingInt(@intCast(index));
}

const zero_pause: Default = .{ .time_range = .{ 0, 0 } };

pub const entries = [_]Entry{
    .{ .name = "wave", .op = .wave, .role = .signal, .summary = "a wave of a shape at a frequency", .params = &.{
        .{ .name = "shape", .kind = .word, .positional = true, .words = wave_words },
        .{ .name = "hz", .kind = .frequency, .positional = true },
    } },
    .{ .name = "noise", .op = .noise, .role = .signal, .summary = "seeded noise, smooth or in steps", .params = &.{
        .{ .name = "shape", .kind = .word, .positional = true, .words = noise_words },
        .{ .name = "hz", .kind = .frequency, .positional = true },
        .{ .name = "seed", .kind = .seed, .default = .seed },
    } },
    .{ .name = "tween", .op = .tween, .role = .signal, .summary = "a move from one value to another, from a cue", .params = &.{
        .{ .name = "from", .kind = .number, .shaped = true },
        .{ .name = "to", .kind = .number, .shaped = true },
        .{ .name = "at", .kind = .cue },
        .{ .name = "over", .kind = .time },
        .{ .name = "ease", .kind = .ease, .default = .{ .word = 0 }, .words = ease_words },
        .{ .name = "after", .kind = .signal, .shaped = true, .default = .absent },
    } },
    .{ .name = "spring", .op = .spring, .role = .signal, .summary = "a spring toward goals at cues", .params = &.{
        .{ .name = "goals", .kind = .path, .positional = true, .shaped = true },
        .{ .name = "from", .kind = .number, .shaped = true, .default = .{ .number = 0 } },
        .{ .name = "time", .kind = .time },
        .{ .name = "overshoot", .kind = .number, .default = .{ .number = 0 } },
    } },
    .{ .name = "newtonian", .op = .newtonian, .role = .signal, .summary = "a Newtonian move toward goals at cues", .params = &.{
        .{ .name = "goals", .kind = .path, .positional = true, .shaped = true },
        .{ .name = "from", .kind = .number, .shaped = true, .default = .{ .number = 0 } },
        .{ .name = "speed", .kind = .number },
        .{ .name = "accel", .kind = .number },
        .{ .name = "decel", .kind = .number },
    } },
    .{ .name = "chase", .op = .chase, .role = .signal, .summary = "a spring chasing a signal", .params = &.{
        .{ .name = "target", .kind = .signal, .positional = true, .shaped = true },
        .{ .name = "from", .kind = .number, .default = .{ .number = 0 } },
        .{ .name = "time", .kind = .time, .live = true },
        .{ .name = "overshoot", .kind = .number, .live = true, .default = .{ .number = 0 } },
    } },
    .{ .name = "oscillator", .op = .oscillator, .role = .signal, .summary = "a wave whose rate is a signal", .params = &.{
        .{ .name = "shape", .kind = .word, .positional = true, .words = wave_words },
        .{ .name = "rate", .kind = .signal },
        .{ .name = "phase", .kind = .number, .default = .{ .number = 0 } },
    } },
    .{ .name = "follow", .op = .follow, .role = .signal, .summary = "a follower of goals drawn from regions", .params = &.{
        .{ .name = "regions", .kind = .regions, .positional = true },
        .{ .name = "from", .kind = .number, .default = .{ .number = 0 } },
        .{ .name = "by", .kind = .mover },
        .{ .name = "pick", .kind = .word, .default = .{ .word = 1 }, .words = pick_words },
        .{ .name = "tolerance", .kind = .number, .default = .{ .number = 0.01 } },
        .{ .name = "pause", .kind = .time_range, .default = zero_pause },
        .{ .name = "seed", .kind = .seed, .default = .seed },
    } },
    .{ .name = "shift", .op = .shift, .role = .signal, .summary = "a shift register of drawn buckets", .params = &.{
        .{ .name = "range", .kind = .number_range, .positional = true },
        .{ .name = "buckets", .kind = .integer },
        .{ .name = "period", .kind = .time },
        .{ .name = "odds", .kind = .number },
        .{ .name = "shape", .kind = .word, .words = shift_words },
        .{ .name = "seed", .kind = .seed, .default = .seed },
    } },
    .{ .name = "delay", .op = .delay, .role = .signal, .summary = "its input from one step before, fed by `<-`", .params = &.{
        .{ .name = "initial", .kind = .number, .positional = true },
    } },
    .{ .name = "bounce", .op = .bounce, .role = .signal, .outputs = &.{"velocity"}, .summary = "a value bouncing between two walls", .params = &.{
        .{ .name = "range", .kind = .number_range, .positional = true },
        .{ .name = "speed", .kind = .number },
        .{ .name = "at", .kind = .cue },
    } },
    .{ .name = "crossing", .op = .crossing, .role = .signal, .summary = "a gate on a level, firing at each crossing", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true },
        .{ .name = "level", .kind = .number },
        .{ .name = "direction", .kind = .word, .default = .{ .word = 0 }, .words = direction_words },
    } },
    .{ .name = "cues", .op = .cues, .role = .signal, .summary = "the count of cues passed, firing at each", .params = &.{
        .{ .name = "first", .kind = .cues, .positional = true },
        .{ .name = "count", .kind = .integer, .default = .whole },
    } },
    .{ .name = "input", .op = .input, .role = .signal, .summary = "a live value the client sets", .params = &.{
        .{ .name = "range", .kind = .number_range, .positional = true, .default = .unbounded },
        .{ .name = "initial", .kind = .number, .default = .{ .number = 0 } },
    } },
    .{ .name = "map", .op = .map, .role = .signal, .summary = "a signal moved from one range to another", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true },
        .{ .name = "from", .kind = .number_range, .positional = true },
        .{ .name = "to", .kind = .number_range },
    } },
    .{ .name = "vec2", .op = .pack, .role = .signal, .summary = "a 2D vector of two signals", .params = &.{
        .{ .name = "x", .kind = .signal, .positional = true },
        .{ .name = "y", .kind = .signal, .positional = true },
    } },
    .{ .name = "vec3", .op = .pack, .role = .signal, .summary = "a 3D vector of three signals", .params = &.{
        .{ .name = "x", .kind = .signal, .positional = true },
        .{ .name = "y", .kind = .signal, .positional = true },
        .{ .name = "z", .kind = .signal, .positional = true },
    } },
    .{ .name = "oklab", .op = .pack, .role = .signal, .summary = "a colour of three signals: lightness and the a and b axes of OKLab", .params = &.{
        .{ .name = "l", .kind = .signal, .positional = true },
        .{ .name = "a", .kind = .signal, .positional = true },
        .{ .name = "b", .kind = .signal, .positional = true },
    } },
    .{ .name = "srgb", .op = .srgb, .role = .signal, .summary = "a colour of three sRGB numbers in [0, 1], kept as OKLab", .params = &.{
        .{ .name = "r", .kind = .number, .positional = true },
        .{ .name = "g", .kind = .number, .positional = true },
        .{ .name = "b", .kind = .number, .positional = true },
    } },
    .{ .name = "spring", .op = .spring_mover, .role = .mover, .summary = "a follower's spring", .params = &.{
        .{ .name = "time", .kind = .time, .live = true },
        .{ .name = "overshoot", .kind = .number, .live = true, .default = .{ .number = 0 } },
    } },
    .{ .name = "newtonian", .op = .newtonian_mover, .role = .mover, .summary = "a follower's Newtonian move", .params = &.{
        .{ .name = "speed", .kind = .number, .live = true },
        .{ .name = "accel", .kind = .number, .live = true },
        .{ .name = "decel", .kind = .number, .live = true },
    } },
};

comptime {
    @setEvalBranchQuota(20_000);
    for (entries) |entry| {
        assert(entry.params.len <= params_max);
        var named = false;
        for (entry.params, 0..) |param_a, index_a| {
            if (param_a.positional) assert(!named) else named = true;
            if (param_a.kind == .word or param_a.kind == .ease) assert(param_a.words.len > 0);
            switch (param_a.default) {
                .word => |word| assert((param_a.kind == .word or param_a.kind == .ease) and word < param_a.words.len),
                .number => assert(param_a.kind == .number),
                .time => assert(param_a.kind == .time),
                .time_range => assert(param_a.kind == .time_range),
                .unbounded => assert(param_a.kind == .number_range),
                .seed => assert(param_a.kind == .seed),
                .whole => assert(param_a.kind == .integer),
                .absent => assert(param_a.kind == .signal),
                .required => {},
            }
            for (entry.params[index_a + 1 ..]) |param_b| assert(!std.mem.eql(u8, param_a.name, param_b.name));
        }
    }
    assert(std.mem.eql(u8, ease_words[3], "in_out"));
    assert(std.mem.eql(u8, pick_words[1], "random"));
}

/// The entry called `name` in `role`.
pub fn find(name: []const u8, role: Role) ?*const Entry {
    for (&entries) |*entry| {
        if (entry.role == role and std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

/// Every entry's name once, for suggestions.
pub const call_names = names: {
    var list: [entries.len][]const u8 = undefined;
    var count = 0;
    for (entries) |entry| {
        var seen = false;
        for (list[0..count]) |name| seen = seen or std.mem.eql(u8, name, entry.name);
        if (!seen) {
            list[count] = entry.name;
            count += 1;
        }
    }
    const final = list[0..count].*;
    break :names final;
};

const testing = std.testing;

// Locks the two roles of section 2, and the parameter lookups.
test "spring is a signal with goals and a mover without" {
    const signal = find("spring", .signal).?;
    const mover = find("spring", .mover).?;
    try testing.expectEqual(Op.spring, signal.op);
    try testing.expectEqual(Op.spring_mover, mover.op);
    try testing.expectEqual(@as(?u32, 0), signal.param("goals"));
    try testing.expectEqual(null, mover.param("goals"));
    try testing.expectEqual(@as(u32, 1), signal.positional_count());
    try testing.expectEqual(@as(?u32, 1), find("bounce", .signal).?.output("velocity"));
    try testing.expectEqual(null, find("sine", .signal));
    try testing.expectEqual(graph.Crossing.Direction.both, word_value(graph.Crossing.Direction, 2));
}
