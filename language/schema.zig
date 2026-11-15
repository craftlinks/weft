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
//! its inputs aside: Weft's `table.zig` gives each entry a `core_op`, the core op its call
//! builds, and the core's own `Op.class` of that op is its class, so the two cannot disagree. A test in `test/lang.zig`
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
    /// `tween` and a `bounce`, which start lane g at the series' cue g, and the `goals` of a
    /// `spring` and a `newtonian` (step 39), whose path's only goal may be at such a cue.
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

/// The class of the nodes a call builds itself, as its back end says: the four of `Class`
/// without `inputs`, which `Entry.class` works out.
pub const NodeClass = enum { pure, exact, simulated, live };

/// A function of one value (section 3c). Its tags are the back end's, which gives the bits.
pub const Function = union(enum) { abs, sin, cos, exp, ln, sqrt, floor, round, pow: u8 };

/// What a back end gives the language: the calls it knows, and the functions whose
/// bits must be its own, so a constant folds to what its node would give.
pub const Vocabulary = struct {
    entries: []const Entry,
    /// A function of one value at a number. A function pointer for now (step 56 makes it comptime).
    fold: *const fn (Function, f64) f64,
    /// `minimum` or `maximum` of two numbers. A function pointer for now (step 56).
    fold_pair: *const fn (Op, f64, f64) f64,
    /// An sRGB colour as the colour the language keeps. A function pointer for now (step 56).
    from_srgb: *const fn ([3]f64) [3]f64,
    /// A seed and a number as a new seed. A function pointer for now (step 56).
    seed_hash: *const fn (u64, u64) u64,

    /// The entry called `name` in `role`.
    pub fn find(vocabulary: *const Vocabulary, name: []const u8, role: Role) ?*const Entry {
        for (vocabulary.entries) |*entry| {
            if (entry.role == role and std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

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
    function: ?Function = null,
    /// The class of the nodes its call builds itself, which its back end fills; null for one
    /// that builds none.
    node_class: ?NodeClass = null,

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
        const own = entry.node_class orelse return null;
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
    pub fn function_of(entry: *const Entry, n: u64) ?Function {
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
/// The value of word `index` of an enum whose words were taken from its fields.
pub fn word_value(comptime E: type, index: u8) E {
    assert(index < @typeInfo(E).@"enum".field_names.len);
    return @fromBackingInt(@intCast(index));
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

const testing = std.testing;

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
