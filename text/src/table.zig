//! Weft's vocabulary for the language: the table of its primitives, and the functions whose bits
//! are the core's.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Role
//! The language (Jig, `../../jig`, a module that imports nothing but `std`) checks a file against a
//! `schema.Vocabulary`. This file is Weft's: every primitive as a `schema.Entry`, each with the
//! class of the nodes it builds, read from the core's `Op.class`, and the four functions a
//! constant folds through, so a folded number has the bits its node would give.
//!
//! ## 2. What the language and the core must agree on
//! The language keeps a few numbers of its own (a second in flicks, the lane limit, the powers
//! `pow` takes) and its own `Function` tags. The comptime block below asserts each against the
//! core, so a drift fails the build.

const std = @import("std");
const assert = std.debug.assert;
const jig = @import("jig");
const weft = @import("weft");
const schema = jig.schema;
const wave = weft.wave;
const noise = weft.noise;
const simulation = weft.simulation;
const graph = weft.graph;
const range = weft.range;
const colour = weft.colour;
const elementary = weft.elementary;
const time = weft.time;

const Entry = schema.Entry;
const Default = schema.Default;
const Role = schema.Role;
const Class = schema.Class;
const ease_words = schema.ease_words;
const word_value = schema.word_value;
const missing_doc = schema.missing_doc;
const doc_valid = schema.doc_valid;
const params_max = schema.params_max;

fn words_of(comptime E: type) []const []const u8 {
    return comptime std.meta.fieldNames(E);
}

/// What Weft's back end builds for an entry. The language gives meaning to the first three
/// (`schema.Op`), which come first here, in the same order; an entry stores one as a `schema.Op`
/// (`tag`) and the back end reads it back (`op_of`).
pub const Op = enum(u8) {
    client = 0,
    noun = 1,
    /// `lanes(n, body)`: its body over a region of n lanes (step 17).
    lanes = 2,
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
    /// A function of one value, the entry's `function` (section 3c).
    function,
    /// `min` and `max`: the smaller and the larger of two values (section 3c).
    minimum,
    maximum,
};

comptime {
    // The language's three tags are Weft's first three, by name and number.
    const ours = std.meta.fieldNames(schema.Op);
    for (ours, 0..) |name, at| {
        assert(std.mem.eql(u8, name, std.meta.fieldNames(Op)[at]));
        assert(@backingInt(@field(schema.Op, name)) == @backingInt(@field(Op, name)));
    }
    assert(ours.len == 3);
}

/// The language's tag for `op`, which an entry stores.
pub fn tag(op: Op) schema.Op {
    return @fromBackingInt(@intCast(@backingInt(op)));
}

/// Weft's op of `entry`: the tag of any entry of Weft's table, and `client`, `noun`, or `lanes`
/// for a client's or the language's own.
pub fn op_of(entry: *const Entry) Op {
    return @fromBackingInt(@intCast(@backingInt(entry.op)));
}

/// The kind of a core node, `graph.Op`'s tag.
pub const OpTag = std.meta.Tag(graph.Op);

/// The core op a call of `op` builds for its own value, its inputs aside (section 3e), or null for
/// one that builds no node of its own: a mover, which is its follower's law, a client's signal,
/// which Weft's back end refuses, and a noun. A vector's tween, spring, Newtonian move, or chase
/// also builds a `pack` of its components, and an `srgb` its three `constant`s, all pure.
pub fn core_op(op: Op) ?OpTag {
    return switch (op) {
        .wave => .wave,
        .noise => .noise,
        .tween => .tween,
        .spring, .newtonian => .motion,
        .chase => .chase,
        .oscillator => .oscillator,
        .follow => .follow,
        .shift => .shift,
        .delay => .delay,
        .bounce => .bounce,
        .crossing => .crossing,
        .cues => .cues,
        .input => .input,
        .map => .map_range,
        .function => .apply,
        .minimum => .minimum,
        .maximum => .maximum,
        .pack, .srgb => .pack,
        // A spread of its body, or nothing when the body has the region's lanes already.
        .lanes => .spread,
        .spring_mover, .newtonian_mover, .client, .noun => null,
    };
}

/// `graph.Op.class` of an op with the tag `tag`, which reads the tag only.
fn core_class(node_tag: OpTag) range.Class {
    switch (node_tag) {
        inline else => |known| {
            const op = @unionInit(graph.Op, @tagName(known), undefined);
            return op.class();
        },
    }
}

pub const wave_words = words_of(wave.Shape);
pub const noise_words = words_of(noise.Shape);
pub const pick_words = words_of(simulation.Pick);
pub const shift_words = words_of(simulation.ShiftShape);
pub const direction_words = words_of(graph.Crossing.Direction);

const zero_pause: Default = .{ .time_range = .{ 0, 0 } };

const stagger_doc = "how much later each lane starts, inside `lanes(n, …)`";
const seed_doc = "a whole number that picks the draw, hashed with the file's `seed`; by default from the declaration's name";
const shape_doc = "the shape of one cycle, each in [-1, 1]";
const goals_doc = "the values it heads for, each from its cue, as `[cue: value, …]` or a path's name; a lone goal's cue may be `series[lane]`";
const goal_from_doc = "the value before the first goal, at rest";
const start_from_doc = "the value at the start cue, at rest";
const spring_time_doc = "the period of the spring's undamped swing, so omega is 2 pi over it";
const overshoot_doc = "how far a move from rest passes its goal, as a fraction of the move, in [0, 1)";
const speed_doc = "the top speed, in units a second";
const accel_doc = "the acceleration while speeding up, in units a second squared";
const decel_doc = "the deceleration while slowing to stop on the goal, in units a second squared";
const function_input_doc = "the signal it applies to, per component of a vector or a colour";
const radians_doc = "the signal, in radians, per component of a vector or a colour";

const chase_hint = "chase follows a moving value, and a follower's mover reads signals";

const written = [_]Entry{
    .{ .name = "wave", .op = tag(.wave), .role = .signal, .lanes = .stagger, .summary = "a wave of a shape at a frequency", .params = &.{
        .{ .name = "shape", .kind = .word, .positional = true, .words = wave_words, .doc = shape_doc },
        .{ .name = "hz", .kind = .frequency, .positional = true, .doc = "cycles a second" },
        .{ .name = "stagger", .kind = .time, .default = .{ .time = 0 }, .doc = "how much later each lane reads the wave, inside `lanes(n, …)`" },
    } },
    .{ .name = "noise", .op = tag(.noise), .role = .signal, .lanes = .region, .summary = "seeded noise, smooth or in steps", .params = &.{
        .{ .name = "shape", .kind = .word, .positional = true, .words = noise_words, .doc = "`smooth` is a curve over the drawn values with no kinks, and `steps` holds each for its cycle" },
        .{ .name = "hz", .kind = .frequency, .positional = true, .doc = "drawn values a second" },
        .{ .name = "seed", .kind = .seed, .default = .seed, .doc = seed_doc },
    } },
    .{ .name = "tween", .op = tag(.tween), .role = .signal, .shape = .{ .agree = .{ "from", "to" } }, .after = .{ .by = "after", .takes = "to" }, .lanes = .stagger, .summary = "a move from one value to another, from a cue", .params = &.{
        .{ .name = "from", .kind = .number, .shaped = true, .default = .after, .doc = "the value it starts from at its cue; left out, the `to` of the tween `after` names" },
        .{ .name = "to", .kind = .number, .shaped = true, .doc = "the value it lands on, exactly, at the end of `over`" },
        .{ .name = "at", .kind = .cue, .by_lane = true, .doc = "the cue it starts at, or `series[lane]` for a cue a lane" },
        .{ .name = "over", .kind = .time, .doc = "how long the move takes from its cue; `0s` is a step, `to` from the cue on" },
        .{ .name = "ease", .kind = .ease, .default = .{ .word = 0 }, .words = ease_words, .doc = "the curve of the move: a word, or a cubic Bezier's `[x1, y1, x2, y2]`" },
        .{ .name = "after", .kind = .signal, .shaped = true, .default = .absent, .doc = "the signal it gives before its cue; without one it holds `from` there" },
        .{ .name = "stagger", .kind = .time, .default = .{ .time = 0 }, .doc = stagger_doc },
    } },
    .{ .name = "spring", .op = tag(.spring), .role = .signal, .shape = .{ .agree = .{ "goals", "from" } }, .lanes = .stagger, .event = "the goal reached", .fixed_hint = chase_hint, .summary = "a spring toward goals at cues", .params = &.{
        .{ .name = "goals", .kind = .path, .positional = true, .shaped = true, .by_lane = true, .doc = goals_doc },
        .{ .name = "from", .kind = .number, .shaped = true, .default = .{ .number = 0 }, .doc = goal_from_doc },
        .{ .name = "time", .kind = .time, .doc = spring_time_doc },
        .{ .name = "overshoot", .kind = .number, .default = .{ .number = 0 }, .doc = overshoot_doc },
        .{ .name = "stagger", .kind = .time, .default = .{ .time = 0 }, .doc = "how much later each lane heads for its goals, inside `lanes(n, …)`" },
    } },
    .{ .name = "newtonian", .op = tag(.newtonian), .role = .signal, .shape = .{ .agree = .{ "goals", "from" } }, .lanes = .stagger, .event = "the goal reached", .fixed_hint = chase_hint, .summary = "a Newtonian move toward goals at cues", .params = &.{
        .{ .name = "goals", .kind = .path, .positional = true, .shaped = true, .by_lane = true, .doc = goals_doc },
        .{ .name = "from", .kind = .number, .shaped = true, .default = .{ .number = 0 }, .doc = goal_from_doc },
        .{ .name = "speed", .kind = .number, .doc = speed_doc },
        .{ .name = "accel", .kind = .number, .doc = accel_doc },
        .{ .name = "decel", .kind = .number, .doc = decel_doc },
        .{ .name = "stagger", .kind = .time, .default = .{ .time = 0 }, .doc = "how much later each lane heads for its goals, inside `lanes(n, …)`" },
    } },
    .{ .name = "chase", .op = tag(.chase), .role = .signal, .shape = .{ .of = "target" }, .summary = "a spring chasing a signal", .params = &.{
        .{ .name = "target", .kind = .signal, .positional = true, .shaped = true, .doc = "the signal it heads for, read at each step of 1/480 s" },
        .{ .name = "from", .kind = .number, .default = .{ .number = 0 }, .doc = start_from_doc },
        .{ .name = "time", .kind = .time, .live = true, .doc = spring_time_doc },
        .{ .name = "overshoot", .kind = .number, .live = true, .default = .{ .number = 0 }, .doc = overshoot_doc },
    } },
    .{ .name = "oscillator", .op = tag(.oscillator), .role = .signal, .summary = "a wave whose rate is a signal", .params = &.{
        .{ .name = "shape", .kind = .word, .positional = true, .words = wave_words, .doc = shape_doc },
        .{ .name = "rate", .kind = .signal, .doc = "the signal of its cycles a second, read at each step of 1/480 s, which may be negative" },
        .{ .name = "phase", .kind = .number, .default = .{ .number = 0 }, .doc = "where in its cycle it is at the start cue, in turns, in [0, 1)" },
    } },
    .{ .name = "follow", .op = tag(.follow), .role = .signal, .lanes = .region, .event = "the goal reached", .summary = "a follower of goals drawn from regions", .params = &.{
        .{ .name = "regions", .kind = .regions, .positional = true, .doc = "the ranges it draws its goals from, as `[low..high, …]` or their name" },
        .{ .name = "from", .kind = .number, .default = .{ .number = 0 }, .doc = start_from_doc },
        .{ .name = "by", .kind = .mover, .doc = "how it moves to each goal: `spring(time: …)` or `newtonian(speed: …, accel: …, decel: …)`" },
        .{ .name = "pick", .kind = .word, .default = .{ .word = 1 }, .words = pick_words, .doc = "how it picks the next range: `cycle` takes them in turn, `random` draws one" },
        .{ .name = "tolerance", .kind = .number, .default = .{ .number = 0.01 }, .doc = "within this of its goal, and at most this fast in units a second, it has arrived" },
        .{ .name = "pause", .kind = .time_range, .default = zero_pause, .doc = "the shortest and longest rest after it arrives, drawn each time" },
        .{ .name = "seed", .kind = .seed, .default = .seed, .doc = seed_doc },
    } },
    .{ .name = "shift", .op = tag(.shift), .role = .signal, .lanes = .region, .event = "the value of the bucket entered", .summary = "a shift register of drawn buckets", .params = &.{
        .{ .name = "range", .kind = .number_range, .positional = true, .doc = "the range its buckets' values are drawn from" },
        .{ .name = "buckets", .kind = .integer, .doc = "how many values it holds and visits in turn, from 1 to 64" },
        .{ .name = "period", .kind = .time, .doc = "how long one pass over every bucket takes" },
        .{ .name = "odds", .kind = .number, .doc = "the chance in [0, 1] that a bucket is drawn again each pass: 0 repeats, 1 never does" },
        .{ .name = "shape", .kind = .word, .words = shift_words, .doc = "`steps` holds each bucket, `linear` runs to the next, `smooth` curves through the midpoints" },
        .{ .name = "seed", .kind = .seed, .default = .seed, .doc = seed_doc },
    } },
    .{ .name = "delay", .op = tag(.delay), .role = .signal, .fed = true, .example = "delay(0)", .lanes = .region, .summary = "its input from one step before, fed by `<-`", .params = &.{
        .{ .name = "initial", .kind = .number, .positional = true, .doc = "its value at the start cue, before a step of 1/480 s has passed" },
    } },
    .{ .name = "bounce", .op = tag(.bounce), .role = .signal, .lanes = .stagger, .event = "the velocity just before the hit: +speed at the top, -speed at the bottom", .first_output = "position", .outputs = &.{"velocity"}, .summary = "a value bouncing between two walls", .params = &.{
        .{ .name = "range", .kind = .number_range, .positional = true, .doc = "the two walls, `low..high`" },
        .{ .name = "speed", .kind = .number, .doc = "how fast it moves between the walls, in units a second" },
        .{ .name = "at", .kind = .cue, .by_lane = true, .doc = "the cue it leaves the low wall at, going up, or `series[lane]` for a cue a lane" },
        .{ .name = "stagger", .kind = .time, .default = .{ .time = 0 }, .doc = stagger_doc },
    } },
    .{ .name = "crossing", .op = tag(.crossing), .role = .signal, .event = "the slope over the step of the crossing, in units a second", .summary = "a gate on a level, firing at each crossing", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .doc = "the signal it watches, compared at each step of 1/480 s for its events" },
        .{ .name = "level", .kind = .number, .doc = "the gate is 1 while the input is at or above it, and 0 below" },
        .{ .name = "direction", .kind = .word, .default = .{ .word = 0 }, .words = direction_words, .doc = "which crossings fire an event" },
    } },
    .{ .name = "cues", .op = tag(.cues), .role = .signal, .lanes = .one, .event = "the index of the cue in its table", .summary = "the count of cues passed, firing at each", .params = &.{
        .{ .name = "first", .kind = .cues, .positional = true, .doc = "the series it counts, by name, or the one cue it starts at" },
        .{ .name = "count", .kind = .integer, .default = .whole, .doc = "how many cues it counts from `first`, in time order; by default the whole series, or the one cue" },
    } },
    .{ .name = "input", .op = tag(.input), .role = .signal, .lanes = .one, .summary = "a live value the client sets", .params = &.{
        .{ .name = "range", .kind = .number_range, .positional = true, .default = .unbounded, .doc = "the range a value the client sets is clamped into" },
        .{ .name = "initial", .kind = .number, .default = .{ .number = 0 }, .doc = "its value until the client first sets one" },
    } },
    .{ .name = "map", .op = tag(.map), .role = .signal, .shape = .{ .of = "input" }, .summary = "a signal moved from one range to another", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = "the signal it moves, per component of a vector" },
        .{ .name = "from", .kind = .number_range, .positional = true, .doc = "the input's range that lands on `to`, with no clamp outside it" },
        .{ .name = "to", .kind = .number_range, .doc = "where `from` lands, low end on low end, so `1..0` flips it" },
    } },
    .{ .name = "abs", .op = tag(.function), .function = .abs, .role = .signal, .folds = true, .shape = .{ .of = "input" }, .summary = "the absolute value of a signal, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = function_input_doc },
    } },
    .{ .name = "sin", .op = tag(.function), .function = .sin, .role = .signal, .folds = true, .shape = .{ .of = "input" }, .summary = "the sine of a signal in radians, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = radians_doc },
    } },
    .{ .name = "cos", .op = tag(.function), .function = .cos, .role = .signal, .folds = true, .shape = .{ .of = "input" }, .summary = "the cosine of a signal in radians, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = radians_doc },
    } },
    .{ .name = "exp", .op = tag(.function), .function = .exp, .role = .signal, .folds = true, .shape = .{ .of = "input" }, .summary = "e to the power of a signal, held at e^709, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = function_input_doc },
    } },
    .{ .name = "ln", .op = tag(.function), .function = .ln, .role = .signal, .folds = true, .shape = .{ .of = "input" }, .summary = "the natural log of a signal, held at the log of 2^-1074 at and below 0, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = function_input_doc },
    } },
    .{ .name = "sqrt", .op = tag(.function), .function = .sqrt, .role = .signal, .folds = true, .shape = .{ .of = "input" }, .summary = "the square root of a signal, 0 at and below 0, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = function_input_doc },
    } },
    .{ .name = "floor", .op = tag(.function), .function = .floor, .role = .signal, .folds = true, .shape = .{ .of = "input" }, .summary = "the largest whole number at or below a signal, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = function_input_doc },
    } },
    .{ .name = "round", .op = tag(.function), .function = .round, .role = .signal, .folds = true, .shape = .{ .of = "input" }, .summary = "the nearest whole number to a signal, a half away from zero, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = function_input_doc },
    } },
    .{ .name = "pow", .op = tag(.function), .function = .{ .pow = 0 }, .role = .signal, .folds = true, .shape = .{ .of = "input" }, .summary = "a signal to a whole power from 2 to 8, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = function_input_doc },
        .{ .name = "n", .kind = .integer, .positional = true, .range = .{ elementary.power_min, elementary.power_max }, .hint = "for 1 write the signal itself; for more than 8 multiply two, such as `pow(x, 8) * pow(x, 2)`", .doc = "the power, a whole number literal from 2 to 8" },
    } },
    .{ .name = "min", .op = tag(.minimum), .role = .signal, .folds = true, .shape = .{ .combine = .{ "a", "b" } }, .summary = "the smaller of two signals, per component", .params = &.{
        .{ .name = "a", .kind = .signal, .positional = true, .shaped = true, .doc = "one of the two, a number meeting each component of a vector or a colour" },
        .{ .name = "b", .kind = .signal, .positional = true, .shaped = true, .doc = "the other, as `a`" },
    } },
    .{ .name = "max", .op = tag(.maximum), .role = .signal, .folds = true, .shape = .{ .combine = .{ "a", "b" } }, .summary = "the larger of two signals, per component", .params = &.{
        .{ .name = "a", .kind = .signal, .positional = true, .shaped = true, .doc = "one of the two, a number meeting each component of a vector or a colour" },
        .{ .name = "b", .kind = .signal, .positional = true, .shaped = true, .doc = "the other, as `a`" },
    } },
    .{ .name = "vec2", .op = tag(.pack), .role = .signal, .shape = .{ .constructor = .{} }, .summary = "a 2D vector of two signals", .params = &.{
        .{ .name = "x", .kind = .signal, .positional = true, .doc = "the first component, `.x`" },
        .{ .name = "y", .kind = .signal, .positional = true, .doc = "the second component, `.y`" },
    } },
    .{ .name = "vec3", .op = tag(.pack), .role = .signal, .shape = .{ .constructor = .{} }, .summary = "a 3D vector of three signals", .params = &.{
        .{ .name = "x", .kind = .signal, .positional = true, .doc = "the first component, `.x`" },
        .{ .name = "y", .kind = .signal, .positional = true, .doc = "the second component, `.y`" },
        .{ .name = "z", .kind = .signal, .positional = true, .doc = "the third component, `.z`" },
    } },
    .{ .name = "oklab", .op = tag(.pack), .role = .signal, .shape = .{ .constructor = .{ .colour = true } }, .summary = "a colour of three signals: lightness and the a and b axes of OKLab", .params = &.{
        .{ .name = "l", .kind = .signal, .positional = true, .doc = "the lightness, from 0 for black to 1 for white" },
        .{ .name = "a", .kind = .signal, .positional = true, .doc = "the green to red axis, green below 0 and red above" },
        .{ .name = "b", .kind = .signal, .positional = true, .doc = "the blue to yellow axis, blue below 0 and yellow above" },
    } },
    .{ .name = "srgb", .op = tag(.srgb), .role = .signal, .shape = .{ .constructor = .{ .colour = true, .converts = true } }, .summary = "a colour of three sRGB numbers in [0, 1], kept as OKLab", .params = &.{
        .{ .name = "r", .kind = .number, .positional = true, .range = .{ 0, 1 }, .hint = "write each of r, g, and b from 0 to 1", .doc = "red, from 0 to 1" },
        .{ .name = "g", .kind = .number, .positional = true, .range = .{ 0, 1 }, .hint = "write each of r, g, and b from 0 to 1", .doc = "green, from 0 to 1" },
        .{ .name = "b", .kind = .number, .positional = true, .range = .{ 0, 1 }, .hint = "write each of r, g, and b from 0 to 1", .doc = "blue, from 0 to 1" },
    } },
    schema.lanes_entry,
    .{ .name = "spring", .op = tag(.spring_mover), .role = .mover, .example = "spring(time: 0.5s)", .lanes = .one, .summary = "a follower's spring", .params = &.{
        .{ .name = "time", .kind = .time, .live = true, .doc = spring_time_doc },
        .{ .name = "overshoot", .kind = .number, .live = true, .default = .{ .number = 0 }, .doc = overshoot_doc },
    } },
    .{ .name = "newtonian", .op = tag(.newtonian_mover), .role = .mover, .example = "newtonian(speed: 1, accel: 2, decel: 2)", .lanes = .one, .summary = "a follower's Newtonian move", .params = &.{
        .{ .name = "speed", .kind = .number, .live = true, .doc = speed_doc },
        .{ .name = "accel", .kind = .number, .live = true, .doc = accel_doc },
        .{ .name = "decel", .kind = .number, .live = true, .doc = decel_doc },
    } },
};

/// The table, each entry with the class of the nodes its call builds, from the core.
pub const entries = filled: {
    @setEvalBranchQuota(10_000);
    var list = written;
    for (&list) |*entry| {
        entry.node_class = if (core_op(op_of(entry))) |core| switch (core_class(core)) {
            .pure => .pure,
            .exact => .exact,
            .simulated => .simulated,
            .live => .live,
        } else null;
    }
    const final = list;
    break :filled final;
};

comptime {
    @setEvalBranchQuota(20_000);
    for (&entries) |*entry| {
        schema.assert_entry(entry);
        assert((op_of(entry) == .function) == (entry.function != null));
        // Weft's own entries also keep a default to its kind, which a client's need not.
        for (entry.params) |param_a| {
            // Weft's `wave` and `noise` take no node for `hz`, so no frequency of its own is live.
            if (param_a.kind == .frequency) assert(!param_a.live);
            switch (param_a.default) {
                .word => |word| assert((param_a.kind == .word or param_a.kind == .ease) and word < param_a.words.len),
                .number => assert(param_a.kind == .number),
                .time => assert(param_a.kind == .time),
                .time_range => assert(param_a.kind == .time_range),
                .unbounded => assert(param_a.kind == .number_range),
                .seed => assert(param_a.kind == .seed),
                .whole => assert(param_a.kind == .integer),
                .absent => assert(param_a.kind == .signal),
                .text => assert(param_a.kind == .string),
                .after => assert(param_a.kind == .number and param_a.shaped and entry.after != null),
                .required => {},
            }
        }
    }
    assert(std.mem.eql(u8, ease_words[3], "in_out"));
    assert(std.mem.eql(u8, pick_words[1], "random"));
}

comptime {
    // What the language keeps of its own is the core's (section 2).
    assert(jig.limits.flicks_per_second == time.flicks_per_second);
    assert(jig.limits.lanes_max == graph.lanes_max);
    assert(jig.limits.power_min == elementary.power_min);
    assert(jig.limits.power_max == elementary.power_max);
    const theirs = std.meta.fieldNames(schema.Function);
    const ours = std.meta.fieldNames(graph.Function);
    assert(theirs.len == ours.len);
    for (theirs, ours) |a, b| assert(std.mem.eql(u8, a, b));
    for (schema.numbers) |known| {
        for (entries) |entry| assert(!std.mem.eql(u8, entry.name, known.name));
    }
}

/// The language's function as the core's, tag for tag.
pub fn core_function(function: schema.Function) graph.Function {
    return switch (function) {
        .pow => |n| .{ .pow = n },
        inline else => |_, function_tag| @unionInit(graph.Function, @tagName(function_tag), {}),
    };
}

/// The value of a call of a folding entry of Weft's table (section 3c): a function of one value
/// through the core's function, `min` and `max` through the core's own.
fn fold(entry: *const Entry, operands: [2]f64) f64 {
    switch (op_of(entry)) {
        .function => {
            assert(entry.params.len == 1 or entry.params.len == 2);
            const n: u64 = @intFromFloat(operands[1]);
            return core_function(entry.function_of(n).?).of(operands[0]);
        },
        .minimum => return graph.minimum(operands[0], operands[1]),
        .maximum => return graph.maximum(operands[0], operands[1]),
        else => unreachable,
    }
}

/// The sRGB numbers a call of `srgb` is written with, as the colour the language keeps.
fn convert(entry: *const Entry, values: [4]f64) [4]f64 {
    assert(op_of(entry) == .srgb);
    const lab = colour.from_srgb(.{ values[0], values[1], values[2] });
    return .{ lab[0], lab[1], lab[2], 0 };
}

/// What Weft gives the language's checker and formatter.
pub const vocabulary: schema.Vocabulary = .{
    .entries = &entries,
    .fold = fold,
    .convert = convert,
    .seed_hash = noise.hash,
};

/// The entry called `name` in `role`.
pub fn find(name: []const u8, role: Role) ?*const Entry {
    for (&entries) |*entry| {
        if (entry.role == role and std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

const testing = std.testing;

// Locks the two roles of section 2, and the parameter lookups.
test "spring is a signal with goals and a mover without" {
    const signal = find("spring", .signal).?;
    const mover = find("spring", .mover).?;
    try testing.expectEqual(Op.spring, op_of(signal));
    try testing.expectEqual(Op.spring_mover, op_of(mover));
    try testing.expectEqual(@as(?u32, 0), signal.param("goals"));
    try testing.expectEqual(null, mover.param("goals"));
    try testing.expectEqual(@as(u32, 1), signal.positional_count());
    try testing.expectEqual(@as(?u32, 1), find("bounce", .signal).?.output("velocity"));
    try testing.expectEqual(null, find("sine", .signal));
    try testing.expectEqual(graph.Crossing.Direction.both, word_value(graph.Crossing.Direction, 2));
}

// Locks step 35's rule for Weft's own table: every parameter says what it means in one sentence,
// so a new call cannot land without its sentences. A client's entries are not held to it.
test "every parameter of the table has its sentence" {
    if (missing_doc(&entries)) |missing| {
        std.debug.print("`{s}`'s parameter `{s}` has no sentence in `doc`\n", .{ missing[0], missing[1] });
        return error.TestExpectedDoc;
    }
    // The check itself: an empty doc, two sentences, and a closing full stop are refused.
    const bare: Entry = .{ .name = "bare", .op = .client, .role = .signal, .summary = "", .params = &.{
        .{ .name = "x", .kind = .signal },
    } };
    try testing.expectEqualDeep(@as(?[2][]const u8, .{ "bare", "x" }), missing_doc(&.{bare}));
    try testing.expect(!doc_valid("one. two"));
    try testing.expect(!doc_valid("one sentence."));
    try testing.expect(!doc_valid("One sentence"));
    try testing.expect(doc_valid("in [0, 1), so 0.5 is half"));
}

// Locks section 3e: each call's class is its own nodes', from the core's `Op.class`. A spring
// toward goals at cues is exact, a chase and a follower are simulated, an input is live, a wave and
// a tween are pure, `map`, `abs`, `vec2`, and `lanes` have their inputs' class, and a mover, a
// client's signal, and a noun build no node of their own.
test "a call's class comes from the core op it builds" {
    try testing.expectEqual(Class.exact, find("spring", .signal).?.class().?);
    try testing.expectEqual(Class.exact, find("newtonian", .signal).?.class().?);
    try testing.expectEqual(Class.simulated, find("chase", .signal).?.class().?);
    try testing.expectEqual(Class.simulated, find("follow", .signal).?.class().?);
    try testing.expectEqual(Class.simulated, find("crossing", .signal).?.class().?);
    try testing.expectEqual(Class.live, find("input", .signal).?.class().?);
    try testing.expectEqual(Class.pure, find("wave", .signal).?.class().?);
    try testing.expectEqual(Class.pure, find("tween", .signal).?.class().?);
    try testing.expectEqual(Class.pure, find("srgb", .signal).?.class().?);
    try testing.expectEqual(Class.inputs, find("map", .signal).?.class().?);
    try testing.expectEqual(Class.inputs, find("abs", .signal).?.class().?);
    try testing.expectEqual(Class.inputs, find("vec2", .signal).?.class().?);
    try testing.expectEqual(Class.inputs, find("lanes", .signal).?.class().?);
    try testing.expectEqual(null, find("spring", .mover).?.class());
    const noun: Entry = .{ .name = "axes", .op = .noun, .role = .signal, .summary = "", .params = &.{} };
    try testing.expectEqual(null, noun.class());
}

// Locks that `bounce` names its first output `position`, which its builder's tests use.
test "a bounce's first output is its position" {
    try testing.expectEqual(@as(?u32, 0), find("bounce", .signal).?.output("position"));
    try testing.expectEqualStrings("position", find("bounce", .signal).?.first_output);
}

// The formatter's tests, here since they format Weft's calls in the order of Weft's table (step 53).

fn format_text(source: []const u8, out: []u8) ![]const u8 {
    const Static = struct {
        var fixture: jig.parse.Fixture = undefined;
    };
    const tree = Static.fixture.run(source);
    try testing.expectEqual(@as(u32, 0), Static.fixture.diagnostics.total());
    return jig.format.format(&tree, &entries, out);
}

// Locks the round trip of section 3 on a canonical file with every declaration and form.
test "a canonical file formats to its own bytes" {
    const canonical =
        \\# Play's signals.
        \\seed 7
        \\
        \\cue c0 = 0s
        \\cue bar = 0s..600s every 2s # 301 cues
        \\track glide_v = 1 in 0.25..4
        \\
        \\moves = [c1: 1, c3: -0.5]
        \\x = a + b * -0.8 - -c
        \\v = b.velocity
        \\glide_a = follow(
        \\    [0..1],
        \\    from: 0.5,
        \\    by: newtonian(speed: glide_v, accel: 16, decel: 16),
        \\    # a comment moves with the argument after it
        \\    pause: 0s..500ms,
        \\    seed: 9, # nine
        \\)
        \\s = spring(
        \\    moves,
        \\    time: 0.5s,
        \\)
        \\fb <- chase(fb, time: 0.5s)
        \\
    ;
    var out: [1024]u8 = undefined;
    try testing.expectEqualStrings(canonical, try format_text(canonical, &out));
}

test "a module and a use line format to their canonical text" {
    const canonical =
        \\use std
        \\module heavy(goal, time: 0.9s) in 0..2 = spring(goal, time: time, overshoot: 0.1)
        \\module breathe(base, amount) = base * (1 + amount * wave(sine, 0.2hz))
        \\out = heavy([c1: 1])
        \\
    ;
    var out: [1024]u8 = undefined;
    try testing.expectEqualStrings(canonical, try format_text(canonical, &out));
    var messy: [1024]u8 = undefined;
    try testing.expectEqualStrings(canonical, try format_text(
        \\use   std
        \\module heavy( goal,time:0.9s ) in 0..2=spring(goal,time:time,overshoot:0.1)
        \\module breathe(base,amount)=base*(1+amount*wave(sine,0.2hz))
        \\out=heavy([c1:1])
        \\
    , &messy));
}

// Locks the rules of section 1 on a messy file: spacing, blank lines, the order of named
// arguments, and a call that loses its trailing comma joining one line.
test "a messy file formats to the canonical one" {
    var out: [1024]u8 = undefined;
    const formatted = try format_text(
        \\
        \\
        \\seed   7
        \\s=spring(moves,overshoot:0.2,time:0.5s)   #   kept as written
        \\
        \\
        \\
        \\f = follow([0..1], seed: 2, by: spring(overshoot: 0.1, time: 1s), from: 0.5)
        \\l = [
        \\    1,
        \\    2
        \\]
        \\
    , &out);
    try testing.expectEqualStrings(
        \\seed 7
        \\s = spring(moves, time: 0.5s, overshoot: 0.2) #   kept as written
        \\
        \\f = follow([0..1], from: 0.5, by: spring(time: 1s, overshoot: 0.1), seed: 2)
        \\l = [1, 2]
        \\
    , formatted);
    var again: [1024]u8 = undefined;
    try testing.expectEqualStrings(formatted, try format_text(formatted, &again));
}

// Locks `/` in section 1 (step 30): `a/b` formats to `a / b`, a negative divisor keeps its sign
// on the literal, and the result formats to itself.
test "a quotient formats with a space on each side" {
    var out: [256]u8 = undefined;
    const formatted = try format_text("x = a/b\ny = (a+1)/-4/2*c\n", &out);
    try testing.expectEqualStrings("x = a / b\ny = (a + 1) / -4 / 2 * c\n", formatted);
    var again: [256]u8 = undefined;
    try testing.expectEqualStrings(formatted, try format_text(formatted, &again));
}

// Locks the refusals: a comment with no place, and a buffer too small.
test "a comment between operands, or a small buffer, is refused" {
    var out: [1024]u8 = undefined;
    try testing.expectError(error.CommentPlacement, format_text("x = (a # here\n + b)\n", &out));
    var small: [4]u8 = undefined;
    try testing.expectError(error.NoSpace, format_text("x = wave(sine, 1hz)\n", &small));
}
