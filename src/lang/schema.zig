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
//! its documentation say the same thing. Shorter names come from modules (step 13). `abs`, `min`,
//! and `max` are the exception, the names a formula writes, for `apply(.abs, …)`, `minimum`, and
//! `maximum` (section 3c).
//!
//! ## 3a. Nouns That Only Describe
//! A client has two ways to add a call (steps 14 and 27). `Op.client` is a signal the client
//! builds: the checker accepts it and Weft's back end refuses the file, so the client reads
//! `Checked.calls` and builds its own program. `Op.noun` is not a signal at all: it describes
//! something the client owns, an axis, a caption, a typeface, and stands only as a whole
//! declaration, `ax = axes(x: -3..3)`. The back end builds the signals among its arguments and
//! nothing for the noun, so the file compiles to a program and the client reads each noun's
//! values beside it. Two kinds exist for nouns: `string`, a literal's text, and `noun`, the name
//! of a noun declared above, of one of the entries the parameter's `words` lists, or of any when
//! `words` is empty. A noun's signals each keep their own lanes and shape.
//!
//! ## 3b. A Default From the Tween Before
//! A tween's `from` defaults to `after` (step 31): when `after` names a tween, `from` is that
//! tween's `to`, so a chain of tweens says each value once. The checker fills it in, so the call
//! a back end reads is the one the longer text gives, and with no tween to read it from, `from`
//! is required as before. `describe` prints the default as `"after"`.
//!
//! ## 3c. Functions of a Value
//! `abs`, `min`, and `max` (step 26) are pure calls whose every parameter is a shaped signal, so
//! a vector or a colour goes in whole and the call works per component, as `+` does: `min` and
//! `max` take `+`'s shapes, a number broadcast and a colour never mixed with a vector, and `abs`
//! keeps its input's. Their lanes are their inputs'. An entry whose `op` is `function` names its
//! core function in `function`, so a function of one value is one entry and one value of
//! `graph.Function`, and the checker and the back end have one arm for all of them. Step 33's
//! `sin`, `cos`, `exp`, `ln`, `sqrt`, `floor`, and `round` are such entries, and so is
//! `pow(input, n)`, whose `function` is `.{ .pow = 0 }` and whose power is its `n` argument, a
//! whole number from 2 to 8, fixed when the program is built, that the checker requires
//! (`Entry.function_of`).
//!
//! ## 3d. A Sentence a Parameter
//! Each parameter's `doc` says what it means in one plain sentence, which `describe` prints
//! (step 35): that a spring's `time` is the period of its undamped swing is in `motion.zig`, and
//! now in the table an agent reads too. The table is already the one source the checker, the
//! formatter, and `describe` read, so the sentence is no second document. A test refuses an entry
//! of this table with a parameter that has none (`missing_doc`), so a new call cannot land
//! without them; a client's entries keep the empty default and are not held to it.
//!
//! ## 3e. A Call's Class
//! `describe` gives each call its class (step 35), the class of the nodes the call builds itself,
//! its inputs aside: `core_op` names the core op an entry's call builds, and the core's own
//! `Op.class` of that op is its class, so the two cannot disagree. A test in `test/lang.zig`
//! compiles a call of every entry and finds that op among its nodes, so `core_op` cannot drift
//! from the back end either. A value's class is the highest of its call's and its inputs', as
//! `range.zig` says, so a call whose own nodes are pure and which always reads a signal, `map`,
//! a function of a value, `min`, `max`, `vec2`, `vec3`, `oklab`, and `lanes`, is `inputs`: it has
//! the class of the signals it reads, which no word of the four could say. A tween is `pure`
//! though its `after` is a signal, as a tween with none is. A mover builds no node of its own,
//! since it is its follower's law, nor do a client's signal and a noun, so theirs is null.
//!
//! ## 3f. Numbers the Language Knows
//! `pi` and `tau` (step 40) are names for two numbers, `std.math.pi` and `std.math.tau`, in a
//! table of their own, `numbers`, beside the calls: the checker reads a value from it, and
//! `describe` prints it with its sentence, held to section 3d's rule. A name is a number wherever
//! a number literal is, and folds with the arithmetic around it (`check.zig`, section 3b), so
//! the nodes are the ones the number written out builds. A file's own binding, or a module's
//! parameter, of the same name shadows it. The table is these two and stays small: a constant
//! a file needs is a literal, or a binding where a signal goes.
//!
//! ## 4. TigerStyle Invariants
//! - The table is comptime and checked: positional parameters come first, names are unique in an
//!   entry, a default suits its kind, and an entry has at most `params_max` parameters.
//! - Every parameter of the table has its sentence, which a test checks (section 3d), and so
//!   does every number of `numbers`.
//! - A number's name is no call's name, so a suggestion never offers both, and its value is finite.

const std = @import("std");
const assert = std.debug.assert;
const wave = @import("../core/wave.zig");
const noise = @import("../core/noise.zig");
const simulation = @import("../core/simulation.zig");
const graph = @import("../core/graph.zig");
const range = @import("../core/range.zig");

pub const params_max = 24;

pub const Kind = enum {
    /// A number fixed when the program is built: a literal, `pi`, `tau`, or their arithmetic
    /// (`check.zig`, section 3b).
    number,
    /// A whole number fixed when the program is built, at least zero, as `number` is written.
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
    /// A string literal, for a client's nouns (section 3a).
    string,
    /// The name of a noun declared above, one of the entries in `words` when it lists any.
    noun,
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
    /// A string's text.
    text: []const u8,
    /// The `to` of the tween the call's `after` names (section 3b): a tween's `from`, which may be
    /// left out only then.
    after,
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
    /// A cue that may be chosen by lane, `series[lane]` inside a region (step 28): the `at` of a
    /// `tween` and a `bounce` only, which start lane g at the series' cue g.
    by_lane: bool = false,
    /// What the parameter means, one sentence, which `describe` prints (section 3d). Every
    /// parameter of `entries` has one; a client's entry may leave it empty.
    doc: []const u8 = "",
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
    /// `lanes(n, body)`: its body over a region of n lanes (step 17).
    lanes,
    /// A client's signal: checked like the rest, refused by Weft's back end, and built by the
    /// client from `Checked.calls`.
    client,
    /// A client's noun that only describes (section 3a): a declaration of its own, whose signal
    /// arguments the back end builds and whose call it skips.
    noun,
    /// A function of one value, the entry's `function` (section 3c).
    function,
    /// `min` and `max`: the smaller and the larger of two values (section 3c).
    minimum,
    maximum,
};

/// How a call takes lanes (step 17), which `describe` prints and the checker follows.
pub const LaneRule = enum {
    /// The lanes of the region it is in, one inside none.
    region,
    /// The region's lanes when given a `stagger:`, otherwise as `inputs`.
    stagger,
    /// The most lanes of the signals it reads.
    inputs,
    /// One: it reads no signal.
    one,
    /// The count it is given: `lanes(n, …)`.
    makes,
    /// None of its own: a noun, each of whose signals keeps its lanes.
    apart,
};

/// How a reader reaches a call's value at a time (section 3e): the core's four classes
/// (`range.Class`), and `inputs` for a call whose own nodes are pure and which reads a signal, so
/// its value has the class of the signals it reads.
pub const Class = enum { pure, exact, simulated, live, inputs };

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
fn core_class(tag: OpTag) range.Class {
    switch (tag) {
        inline else => |known| {
            const op = @unionInit(graph.Op, @tagName(known), undefined);
            return op.class();
        },
    }
}

pub const Entry = struct {
    name: []const u8,
    op: Op,
    role: Role,
    params: []const Param,
    /// Its outputs beyond the first, by name; the first is the call itself.
    outputs: []const []const u8 = &.{},
    summary: []const u8,
    /// The core function of an entry whose `op` is `function`, and null for every other. A
    /// client's entry with that `op` sets it too, as the table's are checked to. A power's n is
    /// its call's `n` (section 3c).
    function: ?graph.Function = null,

    /// The index of the parameter `name`, if the entry has one.
    pub fn param(entry: *const Entry, name: []const u8) ?u32 {
        for (entry.params, 0..) |candidate, index| {
            if (std.mem.eql(u8, candidate.name, name)) return @intCast(index);
        }
        return null;
    }

    pub fn lane_rule(entry: *const Entry) LaneRule {
        return switch (entry.op) {
            .noise, .follow, .shift, .delay => .region,
            .wave, .tween, .spring, .newtonian, .bounce => .stagger,
            .chase, .crossing, .map, .oscillator, .pack, .srgb, .client => .inputs,
            .function, .minimum, .maximum => .inputs,
            .cues, .input, .spring_mover, .newtonian_mover => .one,
            .lanes => .makes,
            .noun => .apart,
        };
    }

    /// The class of the nodes a call of this entry builds itself (section 3e), from the core's
    /// `Op.class`, or null for one that builds none.
    pub fn class(entry: *const Entry) ?Class {
        const tag = core_op(entry.op) orelse return null;
        const own = core_class(tag);
        return switch (own) {
            .pure => if (entry.reads_signal()) .inputs else .pure,
            .exact => .exact,
            .simulated => .simulated,
            .live => .live,
        };
    }

    /// Whether every call of it reads a signal: a parameter of kind `signal` with no default.
    pub fn reads_signal(entry: *const Entry) bool {
        for (entry.params) |candidate| {
            if (candidate.kind == .signal and candidate.default == .required) return true;
        }
        return false;
    }

    /// What an event of this call carries in its `value`, as `event.zig` says, or null for a call
    /// with no events.
    pub fn event_value(entry: *const Entry) ?[]const u8 {
        return switch (entry.op) {
            .bounce => "the velocity just before the hit: +speed at the top, -speed at the bottom",
            .crossing => "the slope over the step of the crossing, in units a second",
            .cues => "the index of the cue in its table",
            .spring, .newtonian, .follow => "the goal reached",
            .shift => "the value of the bucket entered",
            else => null,
        };
    }

    /// The core function a call of this entry applies, given its `n` where it is a power (section
    /// 3c). Null for an entry whose `op` is not `function`.
    pub fn function_of(entry: *const Entry, n: u64) ?graph.Function {
        const function = entry.function orelse return null;
        assert(entry.op == .function);
        return switch (function) {
            .pow => .{ .pow = @intCast(@min(n, std.math.maxInt(u8))) },
            else => function,
        };
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

const stagger_doc = "how much later each lane starts, inside `lanes(n, …)`";
const seed_doc = "a whole number that picks the draw, hashed with the file's `seed`; by default from the declaration's name";
const shape_doc = "the shape of one cycle, each in [-1, 1]";
const goals_doc = "the values it heads for, each from its cue, as `[cue: value, …]` or a path's name";
const goal_from_doc = "the value before the first goal, at rest";
const start_from_doc = "the value at the start cue, at rest";
const spring_time_doc = "the period of the spring's undamped swing, so omega is 2 pi over it";
const overshoot_doc = "how far a move from rest passes its goal, as a fraction of the move, in [0, 1)";
const speed_doc = "the top speed, in units a second";
const accel_doc = "the acceleration while speeding up, in units a second squared";
const decel_doc = "the deceleration while slowing to stop on the goal, in units a second squared";
const function_input_doc = "the signal it applies to, per component of a vector or a colour";
const radians_doc = "the signal, in radians, per component of a vector or a colour";

pub const entries = [_]Entry{
    .{ .name = "wave", .op = .wave, .role = .signal, .summary = "a wave of a shape at a frequency", .params = &.{
        .{ .name = "shape", .kind = .word, .positional = true, .words = wave_words, .doc = shape_doc },
        .{ .name = "hz", .kind = .frequency, .positional = true, .doc = "cycles a second" },
        .{ .name = "stagger", .kind = .time, .default = .{ .time = 0 }, .doc = "how much later each lane reads the wave, inside `lanes(n, …)`" },
    } },
    .{ .name = "noise", .op = .noise, .role = .signal, .summary = "seeded noise, smooth or in steps", .params = &.{
        .{ .name = "shape", .kind = .word, .positional = true, .words = noise_words, .doc = "`smooth` is a curve over the drawn values with no kinks, and `steps` holds each for its cycle" },
        .{ .name = "hz", .kind = .frequency, .positional = true, .doc = "drawn values a second" },
        .{ .name = "seed", .kind = .seed, .default = .seed, .doc = seed_doc },
    } },
    .{ .name = "tween", .op = .tween, .role = .signal, .summary = "a move from one value to another, from a cue", .params = &.{
        .{ .name = "from", .kind = .number, .shaped = true, .default = .after, .doc = "the value it starts from at its cue; left out, the `to` of the tween `after` names" },
        .{ .name = "to", .kind = .number, .shaped = true, .doc = "the value it lands on, exactly, at the end of `over`" },
        .{ .name = "at", .kind = .cue, .by_lane = true, .doc = "the cue it starts at, or `series[lane]` for a cue a lane" },
        .{ .name = "over", .kind = .time, .doc = "how long the move takes from its cue" },
        .{ .name = "ease", .kind = .ease, .default = .{ .word = 0 }, .words = ease_words, .doc = "the curve of the move: a word, or a cubic Bezier's `[x1, y1, x2, y2]`" },
        .{ .name = "after", .kind = .signal, .shaped = true, .default = .absent, .doc = "the signal it gives before its cue; without one it holds `from` there" },
        .{ .name = "stagger", .kind = .time, .default = .{ .time = 0 }, .doc = stagger_doc },
    } },
    .{ .name = "spring", .op = .spring, .role = .signal, .summary = "a spring toward goals at cues", .params = &.{
        .{ .name = "goals", .kind = .path, .positional = true, .shaped = true, .doc = goals_doc },
        .{ .name = "from", .kind = .number, .shaped = true, .default = .{ .number = 0 }, .doc = goal_from_doc },
        .{ .name = "time", .kind = .time, .doc = spring_time_doc },
        .{ .name = "overshoot", .kind = .number, .default = .{ .number = 0 }, .doc = overshoot_doc },
        .{ .name = "stagger", .kind = .time, .default = .{ .time = 0 }, .doc = "how much later each lane heads for its goals, inside `lanes(n, …)`" },
    } },
    .{ .name = "newtonian", .op = .newtonian, .role = .signal, .summary = "a Newtonian move toward goals at cues", .params = &.{
        .{ .name = "goals", .kind = .path, .positional = true, .shaped = true, .doc = goals_doc },
        .{ .name = "from", .kind = .number, .shaped = true, .default = .{ .number = 0 }, .doc = goal_from_doc },
        .{ .name = "speed", .kind = .number, .doc = speed_doc },
        .{ .name = "accel", .kind = .number, .doc = accel_doc },
        .{ .name = "decel", .kind = .number, .doc = decel_doc },
        .{ .name = "stagger", .kind = .time, .default = .{ .time = 0 }, .doc = "how much later each lane heads for its goals, inside `lanes(n, …)`" },
    } },
    .{ .name = "chase", .op = .chase, .role = .signal, .summary = "a spring chasing a signal", .params = &.{
        .{ .name = "target", .kind = .signal, .positional = true, .shaped = true, .doc = "the signal it heads for, read at each step of 1/480 s" },
        .{ .name = "from", .kind = .number, .default = .{ .number = 0 }, .doc = start_from_doc },
        .{ .name = "time", .kind = .time, .live = true, .doc = spring_time_doc },
        .{ .name = "overshoot", .kind = .number, .live = true, .default = .{ .number = 0 }, .doc = overshoot_doc },
    } },
    .{ .name = "oscillator", .op = .oscillator, .role = .signal, .summary = "a wave whose rate is a signal", .params = &.{
        .{ .name = "shape", .kind = .word, .positional = true, .words = wave_words, .doc = shape_doc },
        .{ .name = "rate", .kind = .signal, .doc = "the signal of its cycles a second, read at each step of 1/480 s, which may be negative" },
        .{ .name = "phase", .kind = .number, .default = .{ .number = 0 }, .doc = "where in its cycle it is at the start cue, in turns, in [0, 1)" },
    } },
    .{ .name = "follow", .op = .follow, .role = .signal, .summary = "a follower of goals drawn from regions", .params = &.{
        .{ .name = "regions", .kind = .regions, .positional = true, .doc = "the ranges it draws its goals from, as `[low..high, …]` or their name" },
        .{ .name = "from", .kind = .number, .default = .{ .number = 0 }, .doc = start_from_doc },
        .{ .name = "by", .kind = .mover, .doc = "how it moves to each goal: `spring(time: …)` or `newtonian(speed: …, accel: …, decel: …)`" },
        .{ .name = "pick", .kind = .word, .default = .{ .word = 1 }, .words = pick_words, .doc = "how it picks the next range: `cycle` takes them in turn, `random` draws one" },
        .{ .name = "tolerance", .kind = .number, .default = .{ .number = 0.01 }, .doc = "within this of its goal, and at most this fast in units a second, it has arrived" },
        .{ .name = "pause", .kind = .time_range, .default = zero_pause, .doc = "the shortest and longest rest after it arrives, drawn each time" },
        .{ .name = "seed", .kind = .seed, .default = .seed, .doc = seed_doc },
    } },
    .{ .name = "shift", .op = .shift, .role = .signal, .summary = "a shift register of drawn buckets", .params = &.{
        .{ .name = "range", .kind = .number_range, .positional = true, .doc = "the range its buckets' values are drawn from" },
        .{ .name = "buckets", .kind = .integer, .doc = "how many values it holds and visits in turn, from 1 to 64" },
        .{ .name = "period", .kind = .time, .doc = "how long one pass over every bucket takes" },
        .{ .name = "odds", .kind = .number, .doc = "the chance in [0, 1] that a bucket is drawn again each pass: 0 repeats, 1 never does" },
        .{ .name = "shape", .kind = .word, .words = shift_words, .doc = "`steps` holds each bucket, `linear` runs to the next, `smooth` curves through the midpoints" },
        .{ .name = "seed", .kind = .seed, .default = .seed, .doc = seed_doc },
    } },
    .{ .name = "delay", .op = .delay, .role = .signal, .summary = "its input from one step before, fed by `<-`", .params = &.{
        .{ .name = "initial", .kind = .number, .positional = true, .doc = "its value at the start cue, before a step of 1/480 s has passed" },
    } },
    .{ .name = "bounce", .op = .bounce, .role = .signal, .outputs = &.{"velocity"}, .summary = "a value bouncing between two walls", .params = &.{
        .{ .name = "range", .kind = .number_range, .positional = true, .doc = "the two walls, `low..high`" },
        .{ .name = "speed", .kind = .number, .doc = "how fast it moves between the walls, in units a second" },
        .{ .name = "at", .kind = .cue, .by_lane = true, .doc = "the cue it leaves the low wall at, going up, or `series[lane]` for a cue a lane" },
        .{ .name = "stagger", .kind = .time, .default = .{ .time = 0 }, .doc = stagger_doc },
    } },
    .{ .name = "crossing", .op = .crossing, .role = .signal, .summary = "a gate on a level, firing at each crossing", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .doc = "the signal it watches, compared at each step of 1/480 s for its events" },
        .{ .name = "level", .kind = .number, .doc = "the gate is 1 while the input is at or above it, and 0 below" },
        .{ .name = "direction", .kind = .word, .default = .{ .word = 0 }, .words = direction_words, .doc = "which crossings fire an event" },
    } },
    .{ .name = "cues", .op = .cues, .role = .signal, .summary = "the count of cues passed, firing at each", .params = &.{
        .{ .name = "first", .kind = .cues, .positional = true, .doc = "the series it counts, by name, or the one cue it starts at" },
        .{ .name = "count", .kind = .integer, .default = .whole, .doc = "how many cues it counts from `first`, in time order; by default the whole series, or the one cue" },
    } },
    .{ .name = "input", .op = .input, .role = .signal, .summary = "a live value the client sets", .params = &.{
        .{ .name = "range", .kind = .number_range, .positional = true, .default = .unbounded, .doc = "the range a value the client sets is clamped into" },
        .{ .name = "initial", .kind = .number, .default = .{ .number = 0 }, .doc = "its value until the client first sets one" },
    } },
    .{ .name = "map", .op = .map, .role = .signal, .summary = "a signal moved from one range to another", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = "the signal it moves, per component of a vector" },
        .{ .name = "from", .kind = .number_range, .positional = true, .doc = "the input's range that lands on `to`, with no clamp outside it" },
        .{ .name = "to", .kind = .number_range, .doc = "where `from` lands, low end on low end, so `1..0` flips it" },
    } },
    .{ .name = "abs", .op = .function, .function = .abs, .role = .signal, .summary = "the absolute value of a signal, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = function_input_doc },
    } },
    .{ .name = "sin", .op = .function, .function = .sin, .role = .signal, .summary = "the sine of a signal in radians, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = radians_doc },
    } },
    .{ .name = "cos", .op = .function, .function = .cos, .role = .signal, .summary = "the cosine of a signal in radians, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = radians_doc },
    } },
    .{ .name = "exp", .op = .function, .function = .exp, .role = .signal, .summary = "e to the power of a signal, held at e^709, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = function_input_doc },
    } },
    .{ .name = "ln", .op = .function, .function = .ln, .role = .signal, .summary = "the natural log of a signal, held at the log of 2^-1074 at and below 0, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = function_input_doc },
    } },
    .{ .name = "sqrt", .op = .function, .function = .sqrt, .role = .signal, .summary = "the square root of a signal, 0 at and below 0, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = function_input_doc },
    } },
    .{ .name = "floor", .op = .function, .function = .floor, .role = .signal, .summary = "the largest whole number at or below a signal, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = function_input_doc },
    } },
    .{ .name = "round", .op = .function, .function = .round, .role = .signal, .summary = "the nearest whole number to a signal, a half away from zero, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = function_input_doc },
    } },
    .{ .name = "pow", .op = .function, .function = .{ .pow = 0 }, .role = .signal, .summary = "a signal to a whole power from 2 to 8, per component", .params = &.{
        .{ .name = "input", .kind = .signal, .positional = true, .shaped = true, .doc = function_input_doc },
        .{ .name = "n", .kind = .integer, .positional = true, .doc = "the power, a whole number literal from 2 to 8" },
    } },
    .{ .name = "min", .op = .minimum, .role = .signal, .summary = "the smaller of two signals, per component", .params = &.{
        .{ .name = "a", .kind = .signal, .positional = true, .shaped = true, .doc = "one of the two, a number meeting each component of a vector or a colour" },
        .{ .name = "b", .kind = .signal, .positional = true, .shaped = true, .doc = "the other, as `a`" },
    } },
    .{ .name = "max", .op = .maximum, .role = .signal, .summary = "the larger of two signals, per component", .params = &.{
        .{ .name = "a", .kind = .signal, .positional = true, .shaped = true, .doc = "one of the two, a number meeting each component of a vector or a colour" },
        .{ .name = "b", .kind = .signal, .positional = true, .shaped = true, .doc = "the other, as `a`" },
    } },
    .{ .name = "vec2", .op = .pack, .role = .signal, .summary = "a 2D vector of two signals", .params = &.{
        .{ .name = "x", .kind = .signal, .positional = true, .doc = "the first component, `.x`" },
        .{ .name = "y", .kind = .signal, .positional = true, .doc = "the second component, `.y`" },
    } },
    .{ .name = "vec3", .op = .pack, .role = .signal, .summary = "a 3D vector of three signals", .params = &.{
        .{ .name = "x", .kind = .signal, .positional = true, .doc = "the first component, `.x`" },
        .{ .name = "y", .kind = .signal, .positional = true, .doc = "the second component, `.y`" },
        .{ .name = "z", .kind = .signal, .positional = true, .doc = "the third component, `.z`" },
    } },
    .{ .name = "oklab", .op = .pack, .role = .signal, .summary = "a colour of three signals: lightness and the a and b axes of OKLab", .params = &.{
        .{ .name = "l", .kind = .signal, .positional = true, .doc = "the lightness, from 0 for black to 1 for white" },
        .{ .name = "a", .kind = .signal, .positional = true, .doc = "the green to red axis, green below 0 and red above" },
        .{ .name = "b", .kind = .signal, .positional = true, .doc = "the blue to yellow axis, blue below 0 and yellow above" },
    } },
    .{ .name = "srgb", .op = .srgb, .role = .signal, .summary = "a colour of three sRGB numbers in [0, 1], kept as OKLab", .params = &.{
        .{ .name = "r", .kind = .number, .positional = true, .doc = "red, from 0 to 1" },
        .{ .name = "g", .kind = .number, .positional = true, .doc = "green, from 0 to 1" },
        .{ .name = "b", .kind = .number, .positional = true, .doc = "blue, from 0 to 1" },
    } },
    .{ .name = "lanes", .op = .lanes, .role = .signal, .summary = "its body over n lanes, each with its own `lane`, seeds, and stagger", .params = &.{
        .{ .name = "count", .kind = .integer, .positional = true, .doc = "how many lanes, numbered from 0 by `lane`" },
        .{ .name = "body", .kind = .signal, .positional = true, .shaped = true, .doc = "what each lane computes, a name bound outside shared by them all" },
    } },
    .{ .name = "spring", .op = .spring_mover, .role = .mover, .summary = "a follower's spring", .params = &.{
        .{ .name = "time", .kind = .time, .live = true, .doc = spring_time_doc },
        .{ .name = "overshoot", .kind = .number, .live = true, .default = .{ .number = 0 }, .doc = overshoot_doc },
    } },
    .{ .name = "newtonian", .op = .newtonian_mover, .role = .mover, .summary = "a follower's Newtonian move", .params = &.{
        .{ .name = "speed", .kind = .number, .live = true, .doc = speed_doc },
        .{ .name = "accel", .kind = .number, .live = true, .doc = accel_doc },
        .{ .name = "decel", .kind = .number, .live = true, .doc = decel_doc },
    } },
};

comptime {
    @setEvalBranchQuota(20_000);
    for (entries) |entry| {
        assert(entry.params.len <= params_max);
        assert((entry.op == .function) == (entry.function != null));
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
                .text => assert(param_a.kind == .string),
                .after => assert(param_a.kind == .number and param_a.shaped and entry.op == .tween),
                .required => {},
            }
            if (param_a.by_lane) assert(param_a.kind == .cue and (entry.op == .tween or entry.op == .bounce));
            for (entry.params[index_a + 1 ..]) |param_b| assert(!std.mem.eql(u8, param_a.name, param_b.name));
        }
    }
    assert(std.mem.eql(u8, ease_words[3], "in_out"));
    assert(std.mem.eql(u8, pick_words[1], "random"));
}

/// A number the language knows by name (section 3f).
pub const Number = struct {
    name: []const u8,
    value: f64,
    /// One sentence, as a parameter's (section 3d).
    doc: []const u8,
};

/// Every number the language knows by name, in the order `describe` prints them (section 3f).
pub const numbers = [_]Number{
    .{ .name = "pi", .value = std.math.pi, .doc = "half a turn in radians, a circle's circumference over its diameter" },
    .{ .name = "tau", .value = std.math.tau, .doc = "a whole turn in radians, 2 pi, one period of `sin` and `cos`" },
};

comptime {
    assert(numbers.len == 2);
    assert(numbers[1].value == 2 * numbers[0].value);
    for (numbers) |known| {
        assert(std.math.isFinite(known.value));
        for (entries) |entry| assert(!std.mem.eql(u8, entry.name, known.name));
    }
}

/// The value of the number the language knows as `name`, or null for any other name.
pub fn number_named(name: []const u8) ?f64 {
    assert(name.len > 0);
    for (numbers) |known| {
        if (std.mem.eql(u8, known.name, name)) return known.value;
    }
    return null;
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
    @setEvalBranchQuota(10_000);
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

/// The longest sentence a parameter's `doc` may be, in bytes (section 3d).
pub const doc_len_max = 128;

/// Whether `doc` is one sentence as section 3d asks: not empty, at most `doc_len_max` bytes, in
/// lower case first as a summary is, and with no full stop inside or at its end.
pub fn doc_valid(doc: []const u8) bool {
    if (doc.len == 0) return false;
    if (doc.len > doc_len_max) return false;
    if (std.ascii.isUpper(doc[0])) return false;
    if (doc[doc.len - 1] == '.') return false;
    return std.mem.indexOf(u8, doc, ". ") == null;
}

/// The first parameter of `list` whose `doc` is not a sentence, as its entry's and its own name,
/// or null when every one has its sentence.
pub fn missing_doc(list: []const Entry) ?[2][]const u8 {
    for (list) |entry| {
        for (entry.params) |candidate| {
            if (!doc_valid(candidate.doc)) return .{ entry.name, candidate.name };
        }
    }
    return null;
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

// Locks section 3f: `pi` and `tau` are the two f64 of `std.math`, bit for bit, `tau` is twice
// `pi` exactly, each has its sentence, and no other name is a number.
test "the language knows pi and tau as numbers" {
    try testing.expectEqual(@as(?f64, 3.141592653589793), number_named("pi"));
    try testing.expectEqual(@as(?f64, 6.283185307179586), number_named("tau"));
    try testing.expectEqual(@as(?f64, std.math.tau), number_named("tau"));
    try testing.expectEqual(null, number_named("e"));
    try testing.expectEqual(null, number_named("lane"));
    try testing.expectEqual(null, number_named("Pi"));
    for (numbers) |known| try testing.expect(doc_valid(known.doc));
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
