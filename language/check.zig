//! The checker: a parsed file to checked declarations, with every name resolved and every
//! argument typed against the table of primitives.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What a Back End Receives
//! A `Checked` is a flat list of declarations in text order, and the arrays they refer to:
//! - a call is an entry of the table and `params.len` values, one per parameter in the entry's
//!   order, with defaults filled in, and for each the item it came from, for errors;
//! - a value is a number, a time in flicks, a frequency, a word, a cue, a span of cues, a range,
//!   a path, regions, a seed, a mover (a call), or a signal (an expression);
//! - an expression is a call, a constant, a sum, a product, a binding, or a track.
//! A back end reads a call by its entry's `op` and never sees text or names, so a client's back
//! end (step 14) reads the same list.
//!
//! ## 2. Names
//! One namespace holds cues, series, tracks, and bindings, and a name is declared once. A name is
//! used only below its declaration, so the node order is the text order; a cycle goes through a
//! delay, whose feed `fb <- x` comes after both. Calls live apart: a name before `(` is looked up
//! in the table only, so `tween = tween(…)` is fine. `seed`, `start`, `cue`, and `track` are not
//! names. A declaration that is refused still binds its name, as `failed`, so its uses below fail
//! without a second message: one mistake reads as one error.
//!
//! ## 3. Arithmetic
//! `a + b` and `a * b` are the builder's add and multiply. `a - b` is `a + b * -1`, `-a` is
//! `a * -1`, and `a - 2` is `a + -2`: negation is exact, so each gives the bits of a subtraction.
//! Two constants fold here, in f64, which is the arithmetic their nodes would do.
//!
//! `a / c` is `a * (1 / c)` (step 30): a product with a constant, so there is no divide op, the
//! range rule is the product's, and it divides per component and per lane as a product does. The
//! divisor is a number known when the program is built: anything that folds to a constant here,
//! such as `4`, `-4`, or a module's parameter bound to one. A signal is refused, since its range
//! may hold 0, and so is a time; 0, or a number whose reciprocal is not finite, is out of range.
//! The product is the quotient exactly when `c` is a power of two, and otherwise within an ulp of
//! it, the same bits on every target. Two numbers fold to their quotient itself.
//!
//! `abs`, `min`, and `max` (step 26), and step 33's functions of a value, are calls, not
//! operators, and fold the same way: given only numbers, the call is the constant the back
//! end's own function gives (`Vocabulary.fold`), the bits its node would hold, so `max(1, 2)` builds one node, and a module such as `std`'s `clamp` given numbers
//! builds none of its own. The call's record stays in `calls`, which a back end never reaches
//! from an expression. A power that overflows folds to an infinity, which the back end refuses
//! as it refuses `1e300 * 1e300`. `pow`'s `n` is a whole number from 2 to 8, fixed when the
//! program is built (section 3b) and checked here, so a signal, 1, 9, 2.5, or -2 is refused at it.
//!
//! ## 3b. Numbers Where a Number Is Due
//! `pi` and `tau` (step 40) are names for `std.math.pi` and `std.math.tau` (`schema.zig`,
//! section 3f). Where a signal goes, each is a constant, as its digits are. Where a number fixed
//! when the program is built is due, `fixed_number` is the one function every such place calls:
//! a tween's ends, a path's goals, a motion's `from`, a range's ends, a track's initial value, a
//! lane count, `pow`'s `n`, a cubic ease's points, the components of a vector or a colour written
//! in numbers, and a number parameter that a signal may also set, `overshoot`, `speed`, which is
//! then fixed as a literal is. There an expression folds when it is made only of number
//! literals, `pi`, `tau`, parentheses, unary minus, and `+ - * /`, through a module's parameter
//! bound to one: `to: 2 * pi`, `x: -tau..tau`, `lanes(2 * 48, …)`. Anything else is refused with
//! the message a non-literal had before: a call, `max(1, 2)` or `sin(pi)`, a name of the file,
//! `lane`, or a time. Each operation is the f64 one of section 3, left to right as written,
//! through `arithmetic`, the function the signal's own folding calls, so a number folded here
//! has the bits a constant folded there has: `2 * pi` is `tau` exactly, and `tau / 3` is the
//! quotient, not a product with 1 / 3. A divisor of 0, or one whose reciprocal is not finite, is
//! refused with a divisor's message (`nonzero_divisor`), and a result that is not finite, such as
//! `1e300 * 1e300`, as a literal past f64 is. A seed, a time, and a frequency are not numbers and
//! take only their literals.
//!
//! A file's own declaration of `pi` or `tau`, of any kind and on any line, shadows the number in
//! the whole file, so the name is that declaration, used below it, as any name is; a module's
//! parameter of the name shadows it in the module's body. A module body never sees the file's
//! names, so there the number is the language's unless a parameter takes the name. A module's
//! default may fold too, from numbers and the two names, so long as neither is one of its
//! parameters, since a default that read a parameter would stand for itself (section 6).
//!
//! ## 3c. Where a Number Is Written
//! A client that writes a number back into the text (step 41), as a knob or a slider does,
//! needs its bytes, and needs to know they are a literal. `number_form` says how an item of the
//! file's own declarations is written: `plain`, a number literal of digits, an optional fraction,
//! and an optional minus, `-0.5`, the one kind whose digits are the number's; `exponent`,
//! `1e3`; `folded`, what section 3b folds, `2 * 0.25` or `tau`; and `other`, anything else.
//! Each comes with its bytes from its first token to its last, a minus included. It reads the
//! tree alone, through `folds_alone` with the file's shadowing, which at the file's frame is
//! `folds` itself, so it answers for a file that does not check, and a file that checks never
//! has `other` where a number is due: the checker asserts so at each track. `track_form` gives a
//! track's three, its value and its bounds.
//!
//! ## 4. Times
//! A time literal is a whole number of flicks, worked out in integers from its digits: seconds
//! are exact to 5 decimal places and milliseconds to 2, since 705,600,000 = 2^9 3^2 5^5 7^2.
//! Anything finer is refused with the nearest whole flick, so a bounce's hits stay exact.
//!
//! `read_time` is the one reader, public (step 41): a literal token's text, digits and `s` or
//! `ms`, to its flicks, or what it is instead (not whole, an exponent, too large, not a time).
//! The checker reads its own literals through it. `write_time` is its inverse: the shortest
//! literal in a unit that reads back to exactly a number of flicks, with the fewest decimal
//! places that hold it, read back before it is returned. A number of flicks has a literal, in
//! either unit, exactly when 441 = 3^2 7^2 divides it, since the rest of a second's and a
//! millisecond's factors are 2s and 5s, which decimal places hold; any other, and a negative
//! one, whose minus is the parser's, is refused.
//!
//! ## 4a. A Cue After a Cue
//! A cue's time is a time literal, or an earlier cue plus one: `cue hit = b2 + 500ms` (step 29).
//! So a beat's parts are written against the beat, and an edit of the beat's one literal moves
//! them all. The sum is worked out here, in whole flicks, and the cue table holds plain times as
//! before: `Cues.move` on the first cue does not move the second, since the program keeps no
//! link between them. Cues stay in time order however they are written, which is why there is
//! no minus: a cue before the cue it names would be above it in the file.
//!
//! What each cue is written as is kept beside its time, in `Checked.cue_forms` (step 41), for a
//! client that writes a cue's time back, such as a retime: a `CueForm`, the cue declared alone,
//! an item of a list with its place, or a cue of a series spaced `every` a step with its place
//! and the series' ends and step. A time is a `CueTime`: a literal, an earlier cue by its index
//! in the table, or both. A literal is a `TimeLiteral`: its token's bytes, its unit, its flicks,
//! and whether the parser's minus is before it. The form holds indexes and byte spans only, one
//! for each cue of the table, so `Limits.cues` bounds it. The program reads none of it.
//!
//! ## 5. Seeds
//! An explicit `seed:` wins. Otherwise a call's seed is the FNV-1a hash of its declaration's name,
//! and the second seeded call in one declaration hashes that with its ordinal, so adding a line
//! never reshuffles another.
//!
//! ## 6. Modules
//! A module is a macro with types (step 13). `register` puts every module of the file, and of
//! each library a `use` line names, in one table before any declaration is checked, so a module
//! may be used above its declaration. A call to a module pushes a `Frame` that binds each
//! parameter to the caller's argument item, then checks the body in that frame: a parameter
//! reference is checked as its argument, in the frame the argument came from. So the arrays a
//! module fills are the ones the same graph written by hand fills, and a back end never sees a
//! module.
//! - A body sees its parameters, the primitives, and the modules, never the file's names, so a
//!   library cannot pick up a client's cue by accident.
//! - A default is a literal, or a number that folds from numbers, `pi`, and `tau` (section 3b),
//!   checked in the module's own frame, so a parameter never stands for itself.
//! - A parameter used as a signal is one signal: its first use is checked and kept in the frame,
//!   and every later use is that expression, which the back end builds once. So `x + x` is
//!   twice one noise, not two noises with two seeds.
//! - A frame knows the frame it was called from. A module that is on that chain already is a
//!   cycle, refused with its path. Using a module inside its own argument, `a(a(1))`, is not one:
//!   the inner call is checked in the caller's frame.
//! - A library's items are in its own tree, so an error inside one, and the item a call or an
//!   expression reports at, is the file's call site (`site_of`).
//! - An instance's seed base hashes its caller's base, the module's name, and how many instances
//!   the caller has expanded in this declaration, so section 5 holds inside modules.
//!
//! A client's nouns (step 14) are entries beside the table of primitives. The checker is built
//! over a vocabulary and a client's entries known at compile time (step 56), and `lookup`, the
//! hint for a misspelt call, and the formatter all read the one list `schema.join` makes of
//! them, so a name that two entries share is a compile error and not a silent shadow.
//!
//! ## 6a. Nouns That Only Describe
//! A call to an entry whose op is `noun` (step 27, `schema.zig` section 3a) is not an expression:
//! it is checked only as the whole value of a declaration, which binds the name as a `noun` and
//! adds a `noun` declaration. Anywhere a signal is wanted, the call or its name is `wrong_type`.
//! Its arguments are checked like any call's, but nothing joins their lanes or shapes: each
//! signal is the client's to read. A `noun` parameter takes the name of a noun bound above, so a
//! plot can name its axes, and the order of the file is the order a client resolves them in.
//!
//! A word, or a noun of the wrong entry, is refused with a hint that names every word the
//! parameter takes, up to `words_hinted_max`, "it takes `point`, `tangent`, `secant`, or
//! `segment`", and only past that the first of them and an ellipsis (step 35). A misspelt word
//! close to one gets "did you mean" instead. Six holds every list of Weft's table, at most four,
//! and all of Tapestry's but its ten places of a slot, and six words of eight letters fit the
//! hint's 96 bytes where ten do not; a longer list is `describe`'s to give in full.
//!
//! ## 6b. A Tween After a Tween
//! A tween's `from` may be left out when its `after` names a tween (step 31): it is then that
//! tween's `to`, a number or a vector or colour whole, copied into the call's values. So the call
//! a back end reads is the call the longer text gives, and the program is the same. `after` must
//! be a name bound to a tween call, or to `lanes(n, tween(…))`, reached directly, through
//! parentheses, or through a module's parameter, since each of those is checked to the name's
//! binding expression; an expression, a call, or a name bound to anything else leaves `from`
//! required, `missing_argument`. The tween named was checked above with its `to` filled, so the
//! default reads one value, with no chain to follow. Its shape is the earlier tween's, and the
//! call's own `to` must agree with it as `from` and `to` always must. Both may still be written,
//! equal or not: a jump at a cue is the file's choice.
//!
//! ## 8. Shapes
//! Every expression has a shape (step 16): a number, a vec2, a vec3, or a colour, three
//! components in OKLab. `vec2`, `vec3`, and `oklab` pack scalar signals; `srgb` is a colour of
//! numbers, converted at compile time. Arithmetic takes two equal shapes or one scalar, which it
//! broadcasts, except that two colours do not multiply; a colour and a vector never mix. Two ends
//! that must agree, such as a tween's `from` and `to`, broadcast a number to a vector but never to
//! a colour, whose components are not alike. A parameter takes one value unless the table marks
//! it `shaped`: then `tween`'s ends, a path's goals and a motion's `from` may be a vector or a
//! colour written in numbers (`Vector`), and `chase`'s target, `map`'s input, `abs`'s input, and
//! a tween's `after` a shaped signal, and the call's shape is theirs. `min` and `max` take two
//! shaped signals and combine their shapes as `+` does. A vector path is one run a component.
//! `.x .y .z` and `.l .a .b` read a component of a name bound to a vector or a colour.
//!
//! ## 9. Lanes
//! `lanes(n, body)` checks its body in a region of n lanes (step 17), and every expression has a
//! lane count, 1 or the region's. In a region, `lane` is each lane's index; a noise, a follower, a
//! shift register, and a delay have the region's lanes, each with its own seed; and so do a wave,
//! a tween, a spring, a Newtonian move, and a bounce given a `stagger:`, a time each lane starts
//! after the one before. Anything else has the most lanes of the signals it reads, so a constant,
//! a knob, or a name bound outside the region is one lane, shared. Two counts above 1 meet only
//! when equal, a parameter a signal sets takes one lane, a region holds only its own count and
//! one, and regions do not nest; each is `wrong_lanes`, as are `lane` and `stagger:` outside a
//! region. A module called in a region expands in it, and a region of delays is fed as one delay.
//!
//! ## 9a. A Cue for Each Lane
//! `series[lane]` (step 28) is a cue for each lane: lane g of the region reads the series' cue g.
//! `cue_ref` allows it only where the parameter's `by_lane` says, the `at` of the table's `tween`
//! and `bounce`, and only inside a region whose lane count the series covers; the value is then
//! `cue_by_lane`, the series' first cue, and the call takes the region's lanes, as a stagger
//! gives. The `goals` of the table's `spring` and `newtonian` take it too (step 39), as the cue
//! of a path's only goal written in the call: the goal is then `cue_by_lane`, which a vector
//! path's every run copies, a path by lane never shares a run with one that is not, and the call
//! takes the region's lanes. `LanePlace` says where a cue is read. Everywhere else, `cues(…)`, a
//! cue's declaration, and a client's noun, it is refused with a hint that names where it
//! belongs, and a path of two goals or more and a declared path each with a hint of its own, as
//! are a name other than `lane` in brackets and `stagger:` beside it; an expression in brackets
//! is the parser's refusal. Through a module's parameter, a cue or a whole path, it is checked
//! where it is used, in the caller's frame, so a module of a tween or a spring works by lane
//! unchanged. A series written as a list, `cue title = [1s, 1080ms]`, adds each item as a cue in
//! time order, so a series need not be evenly spaced.
//!
//! ## 7. TigerStyle Invariants
//! - Every array is the caller's; a full one is an error naming its limit, and checking stops.
//! - Names are found by a linear search over at most `Limits.names`, at compile time only.
//! - The recursion is bounded: expressions nest at most `parse.depth_max` deep, and modules at
//!   most `module_depth_max`, each frame a counted entry of `Memory.frames`. A parameter's
//!   argument is always in an earlier frame, or is a literal of its own frame, so following
//!   arguments ends.

const std = @import("std");
const assert = std.debug.assert;
const parse_module = @import("parse.zig");
const Tree = parse_module.Tree;
const Item = parse_module.Item;
const token_module = @import("token.zig");
const schema = @import("schema.zig");
/// The most modules a "did you mean" looks through.
const modules_suggested_max = 256;
/// The most call names a hint is chosen from; the joined list's distinct names must fit.
const calls_suggested_max = 128;

/// The fields of `Limits`, so a hint can only name one that exists.
const LimitField = std.meta.FieldEnum(@import("limits.zig").Limits);
const Entry = schema.Entry;
const error_module = @import("error.zig");
const Diagnostics = error_module.List;
const Code = error_module.Code;
const limits_module = @import("limits.zig");

const flicks_per_second = limits_module.flicks_per_second;

pub const Span = struct { first: u32, count: u32 };

/// A value's shape (section 8): 1 to 4 components, and whether it is a colour.
pub const Shape = struct {
    components: u8 = 1,
    colour: bool = false,

    pub const scalar: Shape = .{};

    pub fn eql(a: Shape, b: Shape) bool {
        return a.components == b.components and a.colour == b.colour;
    }

    /// The shape in a message: "a number", "a vec2", "a vec3", "a vec4", or "a colour".
    pub fn noun(shape: Shape) []const u8 {
        if (shape.colour) return "a colour";
        return switch (shape.components) {
            1 => "a number",
            2 => "a vec2",
            3 => "a vec3",
            else => "a vec4",
        };
    }

    /// The names of the components, as a vector's or a colour's outputs read them.
    pub fn component_names(shape: Shape) []const []const u8 {
        if (shape.colour) return &.{ "l", "a", "b" };
        return (&[_][]const u8{ "x", "y", "z", "w" })[0..shape.components];
    }
};

/// A vector or colour written as numbers, known at compile time: `vec2(0, 1)`, `srgb(1, 0.5, 0)`.
pub const Vector = struct {
    values: [4]f64,
    shape: Shape,
};

pub const Value = union(enum) {
    absent,
    number: f64,
    integer: u64,
    /// In flicks.
    time: i64,
    frequency: f64,
    word: u8,
    /// A cubic Bezier's control points.
    cubic: [4]f64,
    cue: u32,
    /// The first cue of a series whose cue g starts lane g of the region, `series[lane]` in the
    /// `at` of a `tween` or a `bounce` (section 9a).
    cue_by_lane: u32,
    /// The cues of a `cues` call's first argument.
    span: Span,
    number_range: [2]f64,
    /// In flicks.
    time_range: [2]i64,
    /// An index into `Checked.paths`.
    path: u32,
    /// An index into `Checked.region_runs`.
    regions: u32,
    /// An index into `Checked.exprs`.
    signal: u32,
    /// An index into `Checked.calls`.
    mover: u32,
    seed: u64,
    /// A vector or a colour of numbers, where a shaped parameter takes one (section 8).
    vector: Vector,
    /// A string's text, a slice of the source it was written in (section 6a).
    string: []const u8,
    /// A noun's binding, an index into `Checked.bindings` (section 6a).
    noun: u32,

    /// The shape of a value: a vector's own, else one value.
    pub fn shape(value: Value) Shape {
        return if (value == .vector) value.vector.shape else Shape.scalar;
    }

    /// Component `k` of a value: a vector's, or a number broadcast.
    pub fn component(value: Value, k: usize) f64 {
        return switch (value) {
            .vector => |vector| vector.values[k],
            .number => |number| number,
            else => unreachable,
        };
    }
};

pub const Call = struct {
    entry: *const Entry,
    /// The first of `entry.params.len` values in `Checked.values`.
    values: u32,
    item: u32,
};

pub const Expr = struct {
    tag: Tag,
    a: u32 = 0,
    b: u32 = 0,
    number: f64 = 0,
    item: u32,
    /// What it evaluates to (section 8).
    shape: Shape = .{},
    /// How many lanes it has (section 9), 1 outside a region and for anything that does not vary
    /// by lane.
    lanes: u32 = 1,
    /// The count of the lane region it was checked in, or 0 outside one (section 9).
    region: u32 = 0,

    pub const Tag = enum {
        /// a: the call; b: the output.
        call,
        constant,
        /// a and b: the operands.
        add,
        multiply,
        /// a: the binding; b: the output.
        binding,
        /// a: the track.
        track,
        /// a: the expression; b: the component (section 8).
        pick,
        /// Each lane's index, in a region (section 9).
        lane,
    };
};

/// A path's goal: its cue, its value, and whether lane g of the region reads the cue g after it,
/// `[series[lane]: value]` as a spring's or a Newtonian move's only goal (section 9a).
pub const Goal = struct { cue: u32, value: f64, cue_by_lane: bool = false };

comptime {
    // A cue's form is kept for each cue of the table (section 4a), so it stays a few words:
    // 120 bytes on a 64-bit target, 512 cues at the default limits.
    assert(@sizeOf(TimeLiteral) <= 24);
    assert(@sizeOf(CueForm) <= 120);
}

/// A cue's time as `cue_time` reads it: its flicks, and how it is written (section 4a).
const Timed = struct { flicks: i64, written: CueTime };

/// A cue found by `cue_ref`: its index, or a series' first cue chosen by lane (section 9a).
const CueRef = struct { index: u32, by_lane: bool = false };

/// Where `cue_ref` reads a cue, which decides whether `series[lane]` is taken there and, if not,
/// what the refusal says (section 9a): a place that takes it, one that does not, a path of more
/// than one goal, and a declared path, which is outside any region.
const LanePlace = enum { taken, refused, path_of_goals, declared_path };
pub const Region = struct { low: f64, high: f64 };

/// A path's goals or a list of regions. A declared one is a run of its own, even when an equal
/// run is already there; an inline one shares an equal run, so a limit counts table entries.
pub const Run = struct {
    first: u32,
    count: u32,
    declared: bool,
    /// A path of vectors is one run a component, in order, and its first run holds the shape;
    /// the others are scalar (section 8).
    shape: Shape = .{},
};

pub const Track = struct {
    initial: f64,
    low: f64,
    high: f64,
    item: u32,
};

/// A time literal as a cue's declaration writes it (section 4a): the bytes of its token, the
/// digits and the unit `read_time` reads and `write_time` writes, and what they read as. A minus
/// before the token is the parser's, a token of its own, so it is `negative` and not in the
/// bytes: the cue's sum takes away `flicks` then.
pub const TimeLiteral = struct {
    flicks: i64,
    start: u32,
    len: u32,
    unit: TimeUnit,
    negative: bool,

    /// What the literal adds to the cue's sum: `flicks`, its minus applied.
    pub fn signed(literal: TimeLiteral) i64 {
        assert(literal.flicks >= 0);
        return if (literal.negative) -literal.flicks else literal.flicks;
    }

    /// The token's bytes in `source`, the file the cue is declared in.
    pub fn text(literal: TimeLiteral, source: []const u8) []const u8 {
        assert(literal.start + literal.len <= source.len);
        return source[literal.start..][0..literal.len];
    }
};

/// How one cue's time is written (section 4a): a time literal, `2s`; an earlier cue alone, `a`
/// or `bar[2]`, by its index in the cue table; or an earlier cue and a literal after it,
/// `a + 500ms`.
pub const CueTime = union(enum) {
    literal: TimeLiteral,
    cue: u32,
    after: After,

    pub const After = struct { base: u32, offset: TimeLiteral };
};

/// What a cue's declaration is made of (section 4a), for a client that writes a cue's time back
/// into the text: `Compiled.cue_form`. A cue declared alone, `cue a = …`, a cue of a series
/// written as a list, `cue s = [1s, a + 80ms]`, and a cue of a series spaced `every` a step,
/// `cue bar = 0s..600s every 2s`, whose cues are the series' ends and step, not a time of their
/// own.
pub const CueForm = union(enum) {
    alone: CueTime,
    listed: Listed,
    every: Every,

    /// Item `element` of the list, and how that item is written.
    pub const Listed = struct { element: u32, time: CueTime };
    /// Cue `element` of the series, `from + element * step`, and how the series is written.
    pub const Every = struct { element: u32, from: CueTime, to: CueTime, step: TimeLiteral };

    /// The time a cue's own text writes: the cue's declaration's, or its item's of a list. Null
    /// for a cue of a series spaced `every` a step, which has no text of its own.
    pub fn written(form: CueForm) ?CueTime {
        return switch (form) {
            .alone => |time| time,
            .listed => |listed| listed.time,
            .every => null,
        };
    }
};

pub const Binding = struct {
    name: []const u8,
    item: u32,
    kind: Kind,
    /// The cue, the series' first cue, the track, the expression, the path, the regions, or a
    /// noun's call.
    index: u32,
    /// A series' cue count.
    count: u32 = 0,
    /// The entry of a call bound directly, for its outputs and its goals.
    entry: ?*const Entry = null,
    delay: bool = false,
    fed: bool = false,

    /// `failed` is a name whose declaration was refused: its uses report nothing more (section 2).
    pub const Kind = enum { cue, series, track, signal, path, regions, noun, failed };
};

pub const Declaration = union(enum) {
    signal: struct { binding: u32, expr: u32 },
    feed: struct { binding: u32, expr: u32, item: u32 },
    /// A noun that only describes (section 6a): its binding and its call.
    noun: struct { binding: u32, call: u32 },
};

pub const Memory = struct {
    bindings: []Binding,
    declarations: []Declaration,
    calls: []Call,
    values: []Value,
    value_items: []u32,
    exprs: []Expr,
    cue_times: []i64,
    /// What each cue of the table is written as (section 4a), as long as `cue_times`.
    cue_forms: []CueForm,
    goals: []Goal,
    paths: []Run,
    regions: []Region,
    region_runs: []Run,
    tracks: []Track,
    modules: []Module,
    frames: []Frame,
    libraries: []const Library = &.{},
    instances: []Instance = &.{},
};

pub const Checked = struct {
    seed: u64,
    /// The cue simulated nodes start at.
    start: u32,
    cue_times: []const i64,
    /// What each cue's declaration is made of (section 4a), one for each of `cue_times`.
    cue_forms: []const CueForm,
    bindings: []const Binding,
    declarations: []const Declaration,
    calls: []const Call,
    values: []const Value,
    value_items: []const u32,
    exprs: []const Expr,
    goals: []const Goal,
    paths: []const Run,
    regions: []const Region,
    region_runs: []const Run,
    tracks: []const Track,
    instances: []const Instance,
    /// The modules of the file and the libraries it uses.
    module_count: u32 = 0,
    /// True when no error was found, so a back end may build.
    ok: bool,

    pub fn call_values(checked: *const Checked, call: u32) []const Value {
        const entry = checked.calls[call].entry;
        return checked.values[checked.calls[call].values..][0..entry.params.len];
    }

    pub fn call_value_items(checked: *const Checked, call: u32) []const u32 {
        const entry = checked.calls[call].entry;
        return checked.value_items[checked.calls[call].values..][0..entry.params.len];
    }
};

const Fail = error{Checked};

/// How deep modules may expand: the file's frame, then one frame an instance (section 6).
pub const module_depth_max = 16;
pub const frames_max = module_depth_max + 1;

/// A library: a name and the tree its modules are in. A library's items are in its own tree.
pub const Library = struct { name: []const u8, tree: *const Tree };

/// A module: its name, the tree its declaration is in, and the declaration.
pub const Module = struct { name: []const u8, tree: *const Tree, item: u32 };

/// What a parameter stands for: an item of frame `frame`, the caller's or the module's own.
pub const Arg = struct { item: u32, frame: u32 };

/// One expansion, or the file itself (frame 0). A module's body is checked in its frame, and a
/// parameter reference in it becomes its argument, checked in the frame the argument came from.
pub const Frame = struct {
    tree: *const Tree = undefined,
    /// The file's call that this expansion came from, for errors and calls; a file frame's own.
    site: u32 = 0,
    /// The module this frame expands, or null for the file.
    module: ?u32 = null,
    /// The frame the module was called from, for the cycle check (section 6).
    parent: u32 = 0,
    /// The body's item in `tree`.
    body: u32 = 0,
    /// The parameters' items in `tree`, and what each is bound to.
    param_items: [schema.params_max]u32 = undefined,
    args: [schema.params_max]Arg = undefined,
    /// A parameter's signal once checked, so every use of it is the one signal.
    arg_exprs: [schema.params_max]?u32 = @splat(null),
    params: u32 = 0,
    /// The seed the frame's seeded calls hash from (section 5), and how many it has had.
    seed_base: u64 = 0,
    seeded: u32 = 0,
    /// The instances expanded in this frame, for their seeds.
    instances: u32 = 0,
    /// The range the module declares for its output, if any, checked after the build.
    declared: ?[2]f64 = null,
};

/// A module instance bound to a name with a declared range, checked after the build.
pub const Instance = struct { binding: u32, low: f64, high: f64, item: u32 };

/// The most items one path or one list of regions holds, compared before it enters its table.
pub const run_max = 256;

const reserved = schema.reserved;

/// The most lanes a region has (section 9), the core's own limit.
pub const lanes_max = limits_module.lanes_max;

/// The checker over one vocabulary and one list of a client's entries, both known at compile
/// time (step 56): the calls it looks up are `entries`, the one list `schema.join` builds, so a
/// clash is a compile error and the formatter and the hint read the same list.
fn CheckerOf(comptime vocabulary: schema.Vocabulary, comptime clients: []const Entry) type {
    return struct {
        tree: *const Tree,
        memory: Memory,
        diagnostics: *Diagnostics,
        binding_count: u32 = 0,
        declaration_count: u32 = 0,
        call_count: u32 = 0,
        value_count: u32 = 0,
        expr_count: u32 = 0,
        cue_count: u32 = 0,
        goal_count: u32 = 0,
        path_count: u32 = 0,
        region_count: u32 = 0,
        run_count: u32 = 0,
        track_count: u32 = 0,
        seed: ?u64 = null,
        start_item: ?u32 = null,
        /// The file's tree, and the frame whose tree `tree` is.
        root: *const Tree = undefined,
        frame: u32 = 0,
        frame_count: u32 = 1,
        module_count: u32 = 0,
        instance_count: u32 = 0,
        /// The declared range of the outermost module instance last expanded.
        declared_last: ?[2]f64 = null,
        /// The count of the lane region being checked, or null outside one (section 9).
        region: ?u32 = null,
        /// Delay calls checked so far, so a delay that is not a declaration's whole value, which no
        /// feed could reach, is refused (section 2).
        delay_calls: u32 = 0,
        stopped: bool = false,

        const Checker = @This();
        const entries = schema.join(vocabulary, clients);

        comptime {
            // The hint for an unknown call keeps each name of the list once, so every one fits.
            assert(distinct_names(entries) <= calls_suggested_max);
        }

        fn source(checker: *const Checker) []const u8 {
            return checker.tree.source;
        }

        fn item(checker: *const Checker, index: u32) Item {
            return checker.tree.item(index);
        }

        fn text(checker: *const Checker, index: u32) []const u8 {
            return checker.tree.text(index);
        }

        /// The bytes an item covers.
        fn span_of(checker: *const Checker, index: u32) [2]u32 {
            const at = checker.located(index);
            const it = at.tree.item(at.index);
            const first = at.tree.tokens[it.first];
            const last = at.tree.tokens[it.last];
            return .{ first.start, last.start + last.len - first.start };
        }

        /// Where an item of the current frame is reported: a library's items at their call site.
        fn located(checker: *const Checker, index: u32) struct { tree: *const Tree, index: u32 } {
            if (checker.is_library(checker.frame)) return .{ .tree = checker.root, .index = checker.memory.frames[checker.frame].site };
            return .{ .tree = checker.tree, .index = index };
        }

        fn is_library(checker: *const Checker, frame: u32) bool {
            return checker.memory.frames[frame].tree != checker.root;
        }

        fn in_module(checker: *const Checker) bool {
            return checker.memory.frames[checker.frame].module != null;
        }

        /// The item an expression or a call reports at: the file's call site inside a library.
        fn site_of(checker: *const Checker, index: u32) u32 {
            if (checker.is_library(checker.frame)) return checker.memory.frames[checker.frame].site;
            return index;
        }

        /// Makes `frame` the one items are read from.
        fn focus(checker: *Checker, frame: u32) void {
            checker.frame = frame;
            checker.tree = checker.memory.frames[frame].tree;
        }

        fn fail(
            checker: *Checker,
            index: u32,
            code: Code,
            comptime format: []const u8,
            args: anytype,
        ) ?*error_module.Diagnostic {
            const span = checker.span_of(index);
            const diagnostic = checker.diagnostics.add(code, span[0], @max(span[1], 1), format, args);
            checker.note_library(diagnostic);
            return diagnostic;
        }

        /// Notes which library module an error inside one is in, since it is reported at the call.
        fn note_library(checker: *const Checker, diagnostic: ?*error_module.Diagnostic) void {
            if (!checker.is_library(checker.frame)) return;
            const frame = checker.memory.frames[checker.frame];
            const module = checker.memory.modules[frame.module.?];
            for (checker.memory.libraries) |library| {
                if (library.tree != frame.tree) continue;
                error_module.note(diagnostic, "in `{s}`, a module of the library `{s}`", .{ module.name, library.name });
                return;
            }
        }

        /// An error on an item's main token rather than all of it.
        fn fail_token(
            checker: *Checker,
            index: u32,
            code: Code,
            comptime format: []const u8,
            args: anytype,
        ) ?*error_module.Diagnostic {
            const at = checker.located(index);
            const token = at.tree.tokens[at.tree.item(at.index).token];
            const diagnostic = checker.diagnostics.add(code, token.start, @max(token.len, 1), format, args);
            checker.note_library(diagnostic);
            return diagnostic;
        }

        /// A table of `Limits.field` is full. The field is an enum, so a hint names one that
        /// exists.
        fn limit(checker: *Checker, index: u32, noun: []const u8, comptime field: LimitField, count: usize) Fail {
            const diagnostic = checker.fail(index, .limit, "the file needs more than {d} {s}", .{ count, noun });
            error_module.hint(diagnostic, "raise `Limits.{s}`", .{@tagName(field)});
            checker.stopped = true;
            return error.Checked;
        }

        /// A fixed bound that no `Limits` field raises was passed.
        fn fixed_limit(checker: *Checker, index: u32, noun: []const u8, count: usize) Fail {
            const diagnostic = checker.fail(index, .limit, "more than {d} {s}", .{ count, noun });
            error_module.hint(diagnostic, "that is fixed, not a `Limits` field; split it", .{});
            return error.Checked;
        }

        /// A module sees its parameters only, so the file's names are not found from its body.
        fn find(checker: *const Checker, name: []const u8) ?u32 {
            if (checker.in_module()) return null;
            for (checker.memory.bindings[0..checker.binding_count], 0..) |binding, index| {
                if (std.mem.eql(u8, binding.name, name)) return @intCast(index);
            }
            return null;
        }

        /// The names declared so far, for suggestions, at most `candidates_max`.
        fn names_so_far(checker: *const Checker, out: [][]const u8) [][]const u8 {
            const count = @min(out.len, checker.binding_count);
            for (out[0..count], checker.memory.bindings[0..count]) |*slot, binding| slot.* = binding.name;
            return out[0..count];
        }

        /// Whether `name` is declared on a later line, for the error of section 2.
        fn declared_later(checker: *const Checker, name: []const u8) ?u32 {
            for (checker.tree.declarations) |index| {
                const it = checker.item(index);
                switch (it.tag) {
                    .cue, .cue_series, .track, .bind => {},
                    else => continue,
                }
                if (!std.mem.eql(u8, checker.tree.token_text(it.token), name)) continue;
                if (checker.find(name) == null) return index;
            }
            return null;
        }

        fn declare(checker: *Checker, index: u32, binding: Binding) Fail!u32 {
            const name = binding.name;
            for (reserved) |word| {
                if (std.mem.eql(u8, word, name)) {
                    const diagnostic = checker.fail_token(index, .reserved_name, "`{s}` is a keyword, not a name", .{name});
                    error_module.hint(diagnostic, "choose another name, such as `{s}_1`", .{name});
                    return error.Checked;
                }
            }
            if (checker.find(name)) |previous| {
                const line = error_module.locate(checker.source(), checker.span_of(checker.memory.bindings[previous].item)[0]).line;
                const diagnostic = checker.fail_token(index, .duplicate_name, "`{s}` is already declared", .{name});
                error_module.hint(diagnostic, "it was declared on line {d}", .{line});
                return error.Checked;
            }
            if (checker.binding_count == checker.memory.bindings.len) {
                return checker.limit(index, "names", .names, checker.memory.bindings.len);
            }
            const at = checker.binding_count;
            checker.memory.bindings[at] = binding;
            checker.binding_count += 1;
            return at;
        }

        fn declaration(checker: *Checker, index: u32) Fail!void {
            const it = checker.item(index);
            const name = checker.tree.token_text(it.token);
            checker.focus(0);
            checker.memory.frames[0].seed_base = std.hash.Fnv1a_64.hash(name);
            checker.memory.frames[0].seeded = 0;
            checker.memory.frames[0].instances = 0;
            switch (it.tag) {
                .module, .use => {},
                .seed => {
                    if (checker.seed != null) {
                        _ = checker.fail(index, .duplicate_setting, "the file's seed is set twice", .{});
                        return error.Checked;
                    }
                    checker.seed = std.fmt.parseInt(u64, name, 10) catch {
                        const diagnostic = checker.fail_token(index, .out_of_range, "a seed is a whole number from 0 to 2^64 - 1", .{});
                        error_module.hint(diagnostic, "write digits only, such as `seed 7`", .{});
                        return error.Checked;
                    };
                },
                .start => {
                    if (checker.start_item != null) {
                        _ = checker.fail(index, .duplicate_setting, "the start cue is set twice", .{});
                        return error.Checked;
                    }
                    checker.start_item = index;
                },
                .cue => {
                    if (checker.item(it.a).tag == .list) return checker.cue_list(index);
                    const timed = try checker.cue_time(it.a);
                    const cue = try checker.add_cue(index, timed.flicks, .{ .alone = timed.written });
                    _ = try checker.declare(index, .{ .name = name, .item = index, .kind = .cue, .index = cue });
                },
                .cue_series => try checker.cue_series(index),
                .track => {
                    const initial = try checker.fixed_number(it.a, "a track's initial value");
                    const bounds = try checker.number_range(it.b);
                    if (!(bounds[0] <= initial and initial <= bounds[1])) {
                        const diagnostic = checker.fail(it.a, .out_of_range, "the initial value {d} is outside the bounds {d}..{d}", .{ initial, bounds[0], bounds[1] });
                        error_module.hint(diagnostic, "a track starts inside its bounds", .{});
                        return error.Checked;
                    }
                    if (checker.track_count == checker.memory.tracks.len) {
                        return checker.limit(index, "tracks", .tracks, checker.memory.tracks.len);
                    }
                    // What the checker folded, `number_form` reads as a number: the form a client
                    // is given (section 3c) agrees with the value, and is never `other`.
                    const form = track_form(checker.root, index).?;
                    assert(form.value.kind != .other);
                    assert(form.low.kind != .other);
                    assert(form.high.kind != .other);
                    const track = checker.track_count;
                    checker.memory.tracks[track] = .{ .initial = initial, .low = bounds[0], .high = bounds[1], .item = index };
                    checker.track_count += 1;
                    _ = try checker.declare(index, .{ .name = name, .item = index, .kind = .track, .index = track });
                },
                .bind => try checker.bind(index),
                .feed => try checker.feed(index),
                else => unreachable,
            }
        }

        fn add_cue(checker: *Checker, index: u32, time: i64, form: CueForm) Fail!u32 {
            assert(checker.frame == 0);
            assert(checker.cue_count <= checker.memory.cue_forms.len);
            if (checker.cue_count > 0) {
                const previous = checker.memory.cue_times[checker.cue_count - 1];
                if (time < previous) {
                    const diagnostic = checker.fail(index, .cue_out_of_order, "cues are in time order, and this one is before the cue above it", .{});
                    error_module.hint(diagnostic, "move it above the cues it comes before", .{});
                    return error.Checked;
                }
            }
            if (checker.cue_count == checker.memory.cue_times.len) {
                return checker.limit(index, "cues", .cues, checker.memory.cue_times.len);
            }
            const cue = checker.cue_count;
            checker.memory.cue_times[cue] = time;
            checker.memory.cue_forms[cue] = form;
            checker.cue_count += 1;
            return cue;
        }

        /// A cue's time (section 4a): a time literal, an earlier cue, or that cue plus a time
        /// literal, with how it is written.
        fn cue_time(checker: *Checker, index: u32) Fail!Timed {
            assert(checker.frame == 0);
            const it = checker.item(index);
            switch (it.tag) {
                .name, .element => {
                    const cue = try checker.cue_of(index);
                    return .{ .flicks = checker.memory.cue_times[cue], .written = .{ .cue = cue } };
                },
                .subtract => {
                    const diagnostic = checker.fail(index, .cue_out_of_order, "a cue comes at or after the cue it names, so there is no minus", .{});
                    error_module.hint(diagnostic, "declare this cue first, and write the other as this one plus a time", .{});
                    return error.Checked;
                },
                .add => {
                    const base_tag = checker.item(it.a).tag;
                    if (base_tag != .name and base_tag != .element) {
                        const diagnostic = checker.fail(it.a, .wrong_type, "a cue's time is a time, or a cue and a time after it", .{});
                        error_module.hint(diagnostic, "for example `cue hit = beat + 500ms`", .{});
                        return error.Checked;
                    }
                    const base = try checker.cue_of(it.a);
                    const offset = try checker.time_literal(it.b);
                    const base_flicks = checker.memory.cue_times[base];
                    const flicks = std.math.add(i64, base_flicks, offset.signed()) catch {
                        _ = checker.fail(index, .out_of_range, "this cue's time is past what a time holds", .{});
                        return error.Checked;
                    };
                    const after: CueTime.After = .{ .base = base, .offset = offset };
                    return .{ .flicks = flicks, .written = .{ .after = after } };
                },
                else => {
                    const literal = try checker.time_literal(index);
                    return .{ .flicks = literal.signed(), .written = .{ .literal = literal } };
                },
            }
        }

        /// A time literal of a cue's declaration (section 4a), with its token's bytes, so a client
        /// can find it again: `literal_time`'s flicks, split from the parser's minus.
        fn time_literal(checker: *Checker, index: u32) Fail!TimeLiteral {
            assert(checker.frame == 0);
            assert(checker.tree == checker.root);
            const flicks = try checker.literal_time(index);
            const it = checker.item(index);
            assert(it.tag == .literal);
            const token = checker.tree.tokens[it.token];
            assert(token.tag == .time);
            const in_ms = token_module.unit_of(token, checker.source()) == .ms;
            const unit: TimeUnit = if (in_ms) .ms else .s;
            const negative = it.a == 1;
            const literal: TimeLiteral = .{
                .flicks = if (negative) -flicks else flicks,
                .start = token.start,
                .len = token.len,
                .unit = unit,
                .negative = negative,
            };
            assert(literal.flicks >= 0);
            assert(literal.signed() == flicks);
            return literal;
        }

        /// A series written as a list (step 28): each item a cue's time as `cue_time` reads it, in
        /// time order, bound as a series of as many cues.
        fn cue_list(checker: *Checker, index: u32) Fail!void {
            const it = checker.item(index);
            const children = checker.tree.children(it.a);
            if (children.len == 0) {
                const diagnostic = checker.fail(it.a, .bad_series, "a series written as a list has at least one cue", .{});
                error_module.hint(diagnostic, "for example `cue title = [1s, 1080ms, 1560ms]`", .{});
                return error.Checked;
            }
            if (children.len > checker.memory.cue_times.len - checker.cue_count) {
                return checker.limit(index, "cues", .cues, checker.memory.cue_times.len);
            }
            const first = checker.cue_count;
            for (children, 0..) |child, at| {
                const timed = try checker.cue_time(child);
                const time = timed.flicks;
                if (at > 0 and time < checker.memory.cue_times[checker.cue_count - 1]) {
                    const diagnostic = checker.fail(child, .cue_out_of_order, "a series' cues are in time order, and this one is before the one before it", .{});
                    error_module.hint(diagnostic, "write the list in time order", .{});
                    return error.Checked;
                }
                const listed: CueForm.Listed = .{ .element = @intCast(at), .time = timed.written };
                _ = try checker.add_cue(child, time, .{ .listed = listed });
            }
            assert(checker.cue_count - first == children.len);
            _ = try checker.declare(index, .{
                .name = checker.tree.token_text(it.token),
                .item = index,
                .kind = .series,
                .index = first,
                .count = @intCast(children.len),
            });
        }

        fn cue_series(checker: *Checker, index: u32) Fail!void {
            const it = checker.item(index);
            const from_timed = try checker.cue_time(it.a);
            const to_timed = try checker.cue_time(checker.tree.extra[it.b]);
            const step = try checker.time_literal(checker.tree.extra[it.b + 1]);
            const from = from_timed.flicks;
            const to = to_timed.flicks;
            const every = step.signed();
            if (every <= 0 or to < from or @rem(to - from, every) != 0) {
                const diagnostic = checker.fail(index, .bad_series, "a series' step must be above 0s and divide its span exactly", .{});
                error_module.hint(diagnostic, "for example `0s..600s every 2s`, which is 301 cues", .{});
                return error.Checked;
            }
            const count_wide = @divExact(to - from, every) + 1;
            if (count_wide > checker.memory.cue_times.len - checker.cue_count) {
                return checker.limit(index, "cues", .cues, checker.memory.cue_times.len);
            }
            const count: u32 = @intCast(count_wide);
            var form: CueForm.Every = .{
                .element = 0,
                .from = from_timed.written,
                .to = to_timed.written,
                .step = step,
            };
            const first = try checker.add_cue(index, from, .{ .every = form });
            for (1..count) |element| {
                form.element = @intCast(element);
                const time = from + every * @as(i64, @intCast(element));
                _ = try checker.add_cue(index, time, .{ .every = form });
            }
            _ = try checker.declare(index, .{
                .name = checker.tree.token_text(it.token),
                .item = index,
                .kind = .series,
                .index = first,
                .count = count,
            });
        }

        fn bind(checker: *Checker, index: u32) Fail!void {
            const it = checker.item(index);
            const name = checker.tree.token_text(it.token);
            const value = checker.item(it.a);
            if (value.tag == .list) {
                const children = checker.tree.children(it.a);
                if (children.len > 0 and checker.item(children[0]).tag == .goal) {
                    const path = try checker.path_of(it.a, true, false);
                    _ = try checker.declare(index, .{ .name = name, .item = index, .kind = .path, .index = path });
                    return;
                }
                const run = try checker.region_list(it.a, true);
                _ = try checker.declare(index, .{ .name = name, .item = index, .kind = .regions, .index = run });
                return;
            }
            if (value.tag == .range or value.tag == .goal or value.tag == .named) {
                _ = checker.fail(it.a, .wrong_type, "a name holds a signal, a path, or regions", .{});
                return error.Checked;
            }
            if (value.tag == .call) if (checker.lookup(checker.text(it.a), .signal)) |entry| if (entry.kind() == .noun) {
                const delays_before = checker.delay_calls;
                const call = try checker.check_call(entry, it.a);
                if (checker.delay_calls != delays_before) return checker.unreachable_delay(it.a);
                const at = try checker.declare(index, .{ .name = name, .item = index, .kind = .noun, .index = call, .entry = entry });
                try checker.push_declaration(index, .{ .noun = .{ .binding = at, .call = call } });
                return;
            };
            checker.declared_last = null;
            const delays_before = checker.delay_calls;
            const expr = try checker.signal(it.a);
            const declared = checker.declared_last;
            var binding: Binding = .{ .name = name, .item = index, .kind = .signal, .index = expr };
            const node = checker.memory.exprs[expr];
            if (node.tag == .call and node.b == 0) {
                const entry = checker.memory.calls[node.a].entry;
                binding.entry = entry;
                binding.delay = entry.fed;
                // A region of delays is a delay, fed as one (section 9).
                if (entry.op == .lanes) {
                    const body = checker.memory.exprs[checker.memory.values[checker.memory.calls[node.a].values + 1].signal];
                    binding.delay = body.tag == .call and body.b == 0 and checker.memory.calls[body.a].entry.fed;
                    binding.entry = null;
                }
            }
            if (checker.delay_calls - delays_before > @intFromBool(binding.delay)) return checker.unreachable_delay(it.a);
            const at = try checker.declare(index, binding);
            if (declared) |range| if (value.tag == .call and checker.find_module(checker.text(it.a)) != null) {
                if (checker.instance_count == checker.memory.instances.len) {
                    return checker.limit(index, "names", .names, checker.memory.instances.len);
                }
                checker.memory.instances[checker.instance_count] = .{ .binding = at, .low = range[0], .high = range[1], .item = it.a };
                checker.instance_count += 1;
            };
            try checker.push_declaration(index, .{ .signal = .{ .binding = at, .expr = expr } });
        }

        fn feed(checker: *Checker, index: u32) Fail!void {
            const it = checker.item(index);
            const name = checker.tree.token_text(it.token);
            const target = checker.find(name) orelse {
                const diagnostic = checker.fail_token(index, .unknown_name, "`{s}` is not declared", .{name});
                if (checker.first_example(.fed)) |example| error_module.hint(diagnostic, "declare it above, such as `{s} = {s}`", .{ name, example });
                return error.Checked;
            };
            const binding = &checker.memory.bindings[target];
            if (binding.kind == .failed) return checker.reported();
            if (!binding.delay) {
                const diagnostic = checker.fail_token(index, .not_a_delay, "only a delay is fed with `<-`, and `{s}` is not one", .{name});
                if (checker.first_example(.fed)) |example| error_module.hint(diagnostic, "declare it as `{s} = {s}`", .{ name, example });
                return error.Checked;
            }
            if (binding.fed) {
                _ = checker.fail(index, .delay_fed_twice, "the delay `{s}` is already fed", .{name});
                return error.Checked;
            }
            binding.fed = true;
            const delays_before = checker.delay_calls;
            const expr = try checker.signal(it.a);
            if (checker.delay_calls != delays_before) return checker.unreachable_delay(it.a);
            try checker.expect_scalar(it.a, expr, name);
            const delay_lanes = checker.memory.exprs[binding.index].lanes;
            const lanes = checker.memory.exprs[expr].lanes;
            if (lanes != 1 and lanes != delay_lanes) {
                const diagnostic = if (delay_lanes == 1)
                    checker.fail(it.a, .wrong_lanes, "the delay `{s}` has one lane, and this {d}", .{ name, lanes })
                else
                    checker.fail(it.a, .wrong_lanes, "the delay `{s}` has {d} lanes, and this {d}", .{ name, delay_lanes, lanes });
                error_module.hint(diagnostic, "feed a delay one lane, or as many lanes as it has", .{});
                return error.Checked;
            }
            try checker.push_declaration(index, .{ .feed = .{ .binding = target, .expr = expr, .item = index } });
        }

        /// The example of the first entry that is `fed`, or the first mover, of the vocabulary and
        /// then the client's entries; null where none has one, so a hint that needs it is left out.
        fn first_example(checker: *const Checker, which: enum { fed, mover }) ?[]const u8 {
            _ = checker;
            for (entries) |entry| {
                if (entry.example.len > 0 and example_wanted(&entry, which == .fed)) return entry.example;
            }
            return null;
        }

        /// The example of every mover entry, in backquotes and joined by " or ", as far as `buffer`
        /// holds them.
        fn mover_examples(checker: *const Checker, buffer: *[hint_list_size]u8) []const u8 {
            var stream = std.Io.Writer.fixed(buffer);
            var count: u32 = 0;
            _ = checker;
            for (entries) |entry| {
                if (entry.role != .mover or entry.example.len == 0) continue;
                const joiner: []const u8 = if (count > 0) " or " else "";
                stream.print("{s}`{s}`", .{ joiner, entry.example }) catch return stream.buffered();
                count += 1;
            }
            return stream.buffered();
        }

        /// A delay inside an expression has no name, so no `<-` can feed it (section 2).
        fn unreachable_delay(checker: *Checker, index: u32) Fail {
            const diagnostic = checker.fail(index, .not_a_delay, "a delay is fed by its name, so it is a declaration's whole value", .{});
            if (checker.first_example(.fed)) |example| {
                error_module.hint(diagnostic, "declare it alone, such as `fb = {s}`, feed it with `fb <- …`, then use `fb`", .{example});
            }
            return error.Checked;
        }

        fn push_declaration(checker: *Checker, index: u32, declaration_value: Declaration) Fail!void {
            if (checker.declaration_count == checker.memory.declarations.len) {
                return checker.limit(index, "declarations", .names, checker.memory.declarations.len);
            }
            checker.memory.declarations[checker.declaration_count] = declaration_value;
            checker.declaration_count += 1;
        }

        fn push_expr(checker: *Checker, expr: Expr) Fail!u32 {
            if (checker.expr_count == checker.memory.exprs.len) {
                return checker.limit(expr.item, "expressions", .tree, checker.memory.exprs.len);
            }
            const at = checker.expr_count;
            var placed = expr;
            placed.item = checker.site_of(expr.item);
            placed.region = checker.region orelse 0;
            if (checker.region) |count| if (placed.lanes != 1 and placed.lanes != count) {
                const diagnostic = checker.fail(expr.item, .wrong_lanes, "this has {d} lanes, inside `lanes({d}, …)`", .{ placed.lanes, count });
                error_module.hint(diagnostic, "a region reads signals of one lane, or of its own count", .{});
                return error.Checked;
            };
            checker.memory.exprs[at] = placed;
            checker.expr_count += 1;
            return at;
        }

        fn constant(checker: *Checker, number: f64, index: u32) Fail!u32 {
            return checker.push_expr(.{ .tag = .constant, .number = number, .item = index });
        }

        fn is_constant(checker: *const Checker, expr: u32) ?f64 {
            const node = checker.memory.exprs[expr];
            return if (node.tag == .constant) node.number else null;
        }

        /// A signal expression (section 3).
        fn signal(checker: *Checker, index: u32) Fail!u32 {
            if (checker.bound_slot(index)) |slot| {
                const frame = checker.frame;
                if (checker.memory.frames[frame].arg_exprs[slot]) |expr| return expr;
                const expr = try checker.signal_in(checker.memory.frames[frame].args[slot]);
                checker.memory.frames[frame].arg_exprs[slot] = expr;
                return expr;
            }
            const it = checker.item(index);
            switch (it.tag) {
                .literal => {
                    const token = checker.tree.tokens[it.token];
                    if (token.tag != .number) {
                        const diagnostic = checker.fail(index, .wrong_type, "a {s} is not a signal", .{literal_kind(token.tag)});
                        error_module.hint(diagnostic, "a signal here is a name, a call, arithmetic, or a plain number", .{});
                        return error.Checked;
                    }
                    return checker.constant(try checker.fixed_number(index, "a number"), index);
                },
                .name => {
                    if (std.mem.eql(u8, checker.text(index), "lane")) return checker.lane_index(index);
                    if (checker.known_number(index)) |number| return checker.constant(number, index);
                    return checker.signal_name(index, 0);
                },
                .call => {
                    const name = checker.text(index);
                    if (checker.lookup(name, .signal)) |entry| {
                        if (entry.kind() == .noun) {
                            const diagnostic = checker.fail_token(index, .wrong_type, "`{s}` describes a thing, and is not a signal", .{name});
                            error_module.hint(diagnostic, "give it a line of its own, such as `name = {s}(…)`", .{name});
                            return error.Checked;
                        }
                        // `lanes` opens its region when its count is checked, and closes it here.
                        const region = checker.region;
                        defer checker.region = region;
                        const call = try checker.check_call(entry, index);
                        checker.region = region;
                        if (entry.fed) checker.delay_calls += 1;
                        const shape = try checker.call_shape(call, index);
                        const lanes = try checker.call_lanes(call, index);
                        if (checker.folded(call)) |number| return checker.constant(number, index);
                        return checker.push_expr(.{ .tag = .call, .a = call, .item = index, .shape = shape, .lanes = lanes });
                    }
                    if (checker.find_module(name)) |module| return checker.expand_signal(module, index);
                    return checker.unknown_call(index);
                },
                .paren => return checker.signal(it.a),
                .add, .multiply => {
                    const left = try checker.signal(it.a);
                    const right = try checker.signal(it.b);
                    if (checker.is_constant(left)) |a| if (checker.is_constant(right)) |b| {
                        return checker.constant(arithmetic(it.tag, a, b), index);
                    };
                    const tag: Expr.Tag = if (it.tag == .add) .add else .multiply;
                    const shape = try checker.combine(index, left, right, tag == .multiply);
                    const lanes = try checker.join_lanes(index, left, right);
                    return checker.push_expr(.{ .tag = tag, .a = left, .b = right, .item = index, .shape = shape, .lanes = lanes });
                },
                .subtract => {
                    const left = try checker.signal(it.a);
                    const right = try checker.signal(it.b);
                    if (checker.is_constant(right)) |b| {
                        if (checker.is_constant(left)) |a| {
                            return checker.constant(arithmetic(.subtract, a, b), index);
                        }
                        const negative = try checker.constant(-b, it.b);
                        return checker.push_expr(.{ .tag = .add, .a = left, .b = negative, .item = index, .shape = checker.shape_of(left), .lanes = checker.lanes_of(left) });
                    }
                    const shape = try checker.combine(index, left, right, false);
                    const lanes = try checker.join_lanes(index, left, right);
                    const minus_one = try checker.constant(-1, index);
                    const negated = try checker.push_expr(.{ .tag = .multiply, .a = right, .b = minus_one, .item = it.b, .shape = checker.shape_of(right), .lanes = checker.lanes_of(right) });
                    return checker.push_expr(.{ .tag = .add, .a = left, .b = negated, .item = index, .shape = shape, .lanes = lanes });
                },
                .divide => {
                    const left = try checker.signal(it.a);
                    const by = try checker.divisor(it.b);
                    if (checker.is_constant(left)) |a| {
                        return checker.constant(arithmetic(.divide, a, by), index);
                    }
                    const reciprocal = try checker.constant(1 / by, it.b);
                    return checker.push_expr(.{ .tag = .multiply, .a = left, .b = reciprocal, .item = index, .shape = checker.shape_of(left), .lanes = checker.lanes_of(left) });
                },
                .negate => {
                    const operand = try checker.signal(it.a);
                    if (checker.is_constant(operand)) |a| return checker.constant(-a, index);
                    const minus_one = try checker.constant(-1, index);
                    return checker.push_expr(.{ .tag = .multiply, .a = operand, .b = minus_one, .item = index, .shape = checker.shape_of(operand), .lanes = checker.lanes_of(operand) });
                },
                .output => return checker.output(index, it.a, checker.text(index)),
                .list, .range, .goal, .named, .element => {
                    _ = checker.fail(index, .wrong_type, "expected a signal, found {s}", .{item_kind(it.tag)});
                    return error.Checked;
                },
                else => unreachable,
            }
        }

        /// The constant a call of an entry that `folds` given only numbers folds to (section 3), or
        /// null for any other call. The operands go in parameter order, an integer as a number.
        fn folded(checker: *const Checker, call: u32) ?f64 {
            const entry = checker.memory.calls[call].entry;
            if (!entry.folds) return null;
            const first = checker.memory.calls[call].values;
            const values = checker.memory.values[first..][0..entry.params.len];
            assert(values.len <= 2);
            var operands: [2]f64 = .{ 0, 0 };
            for (values, 0..) |value, at| {
                operands[at] = switch (value) {
                    .signal => |expr| checker.is_constant(expr) orelse return null,
                    .integer => |whole| @floatFromInt(whole),
                    else => unreachable,
                };
            }
            return vocabulary.fold(entry, operands);
        }

        /// The number `index` divides by (section 3): a constant with a finite reciprocal.
        fn divisor(checker: *Checker, index: u32) Fail!f64 {
            assert(index < checker.tree.items.len);
            assert(checker.frame < checker.frame_count);
            if (checker.unit_literal(index)) |kind| {
                const diagnostic = checker.fail(index, .wrong_type, "a divisor is a number, and this is a {s}", .{kind});
                if (!std.mem.eql(u8, kind, "string")) error_module.hint(diagnostic, "drop the unit", .{});
                return error.Checked;
            }
            const expr = try checker.signal(index);
            const shape = checker.shape_of(expr);
            if (!shape.eql(Shape.scalar)) {
                const diagnostic = checker.fail(index, .wrong_shape, "a divisor is a number, and this is {s}", .{shape.noun()});
                error_module.hint(diagnostic, "divide by a number, or take a component, such as `.{s}`", .{shape.component_names()[0]});
                return error.Checked;
            }
            const number = checker.is_constant(expr) orelse {
                const diagnostic = checker.fail(index, .not_live, "a divisor is a number, fixed when the program is built", .{});
                error_module.hint(diagnostic, "to scale by a signal, multiply by one", .{});
                return error.Checked;
            };
            return checker.nonzero_divisor(index, number);
        }

        /// `number`, the divisor at `index`, when it is one (section 3): not 0, and with a finite
        /// reciprocal. A signal's quotient and a number folded where one is due both ask here.
        fn nonzero_divisor(checker: *Checker, index: u32, number: f64) Fail!f64 {
            assert(index < checker.tree.items.len);
            assert(!std.math.isNan(number));
            if (number == 0) {
                const diagnostic = checker.fail(index, .out_of_range, "there is no division by 0", .{});
                error_module.hint(diagnostic, "a divisor is a number other than 0", .{});
                return error.Checked;
            }
            if (!std.math.isFinite(1 / number)) {
                const diagnostic = checker.fail(index, .out_of_range, "1 / {e} is past what a number holds", .{number});
                error_module.hint(diagnostic, "divide by a number further from 0", .{});
                return error.Checked;
            }
            assert(std.math.isFinite(number));
            return number;
        }

        /// The kind of literal with a unit, or string, that `index` is, in parentheses or through a
        /// parameter bound to one, so a divisor's error names it rather than calling it a signal.
        fn unit_literal(checker: *Checker, index: u32) ?[]const u8 {
            assert(index < checker.tree.items.len);
            assert(checker.frame < checker.frame_count);
            if (checker.bound(index)) |arg| {
                const saved = checker.frame;
                checker.focus(arg.frame);
                defer checker.focus(saved);
                return checker.unit_literal(arg.item);
            }
            const it = checker.item(index);
            if (it.tag == .paren) return checker.unit_literal(it.a);
            if (it.tag != .literal) return null;
            const tag = checker.tree.tokens[it.token].tag;
            if (tag == .number) return null;
            return literal_kind(tag);
        }

        /// `base.name`: an output of a call, or of a name bound to one (section 3). `index` is the
        /// output's item, and `base_index` the item it is taken from.
        fn output(checker: *Checker, index: u32, base_index: u32, output_name: []const u8) Fail!u32 {
            if (checker.bound(base_index)) |arg| {
                const saved = checker.frame;
                checker.focus(arg.frame);
                defer checker.focus(saved);
                return checker.output(arg.item, arg.item, output_name);
            }
            const base = checker.item(base_index);
            const entry: *const Entry = switch (base.tag) {
                .name => entry: {
                    const base_name = checker.text(base_index);
                    const found = try checker.resolve(base_index, base_name);
                    const bound_to = checker.memory.bindings[found];
                    if (bound_to.kind == .signal and checker.shape_of(bound_to.index).components > 1) {
                        return checker.component_of(index, try checker.signal_name(base_index, 0), output_name);
                    }
                    if (bound_to.kind == .noun) {
                        _ = checker.fail_token(index, .unknown_output, "`{s}` is a noun, `{s}`, and a noun has no outputs", .{ base_name, bound_to.entry.?.name });
                        return error.Checked;
                    }
                    if (checker.memory.bindings[found].entry) |entry| break :entry entry;
                    const diagnostic = checker.fail_token(index, .unknown_output, "`{s}` has no output `{s}`", .{ base_name, output_name });
                    error_module.hint(diagnostic, "only a call such as `bounce` has outputs", .{});
                    return error.Checked;
                },
                .call => checker.lookup(checker.text(base_index), .signal) orelse {
                    const diagnostic = checker.fail(index, .unknown_output, "a module's call has no outputs until it has a name", .{});
                    error_module.hint(diagnostic, "bind it first, such as `x = {s}(…)`, then `x.{s}`", .{ checker.text(base_index), output_name });
                    return error.Checked;
                },
                else => {
                    _ = checker.fail(index, .unknown_output, "only a name or a call has outputs", .{});
                    return error.Checked;
                },
            };
            const output_slot = entry.output(output_name) orelse {
                if (base.tag == .call and entry.outputs.len == 0 and entry.first_output.len == 0) {
                    const vector = try checker.signal(base_index);
                    if (checker.shape_of(vector).components > 1) return checker.component_of(index, vector, output_name);
                }
                const diagnostic = checker.fail_token(index, .unknown_output, "{s} has no output `{s}`", .{ entry.name, output_name });
                if (entry.outputs.len > 0) {
                    var buffer: [outputs_hint_size]u8 = undefined;
                    error_module.hint(diagnostic, "its outputs are {s}", .{outputs_list(entry, &buffer)});
                } else if (entry.first_output.len > 0) {
                    error_module.hint(diagnostic, "its only output is `{s}`", .{entry.first_output});
                }
                return error.Checked;
            };
            if (base.tag == .name) return checker.signal_name(base_index, output_slot);
            const call = try checker.check_call(entry, base_index);
            const lanes = try checker.call_lanes(call, base_index);
            return checker.push_expr(.{ .tag = .call, .a = call, .b = output_slot, .item = index, .lanes = lanes });
        }

        fn signal_name(checker: *Checker, index: u32, output_index: u32) Fail!u32 {
            const name = checker.text(index);
            const found = try checker.resolve(index, name);
            const binding = checker.memory.bindings[found];
            switch (binding.kind) {
                .signal => {
                    const shape = if (output_index == 0) checker.shape_of(binding.index) else Shape.scalar;
                    const lanes = checker.lanes_of(binding.index);
                    return checker.push_expr(.{ .tag = .binding, .a = found, .b = output_index, .item = index, .shape = shape, .lanes = lanes });
                },
                .track => return checker.push_expr(.{ .tag = .track, .a = binding.index, .item = index }),
                .noun => {
                    const diagnostic = checker.fail(index, .wrong_type, "`{s}` is a noun, `{s}`, not a signal", .{ name, binding.entry.?.name });
                    error_module.hint(diagnostic, "a noun is named only where a parameter takes one", .{});
                    return error.Checked;
                },
                else => {
                    _ = checker.fail(index, .wrong_type, "`{s}` is a {s}, not a signal", .{ name, kind_name(binding.kind) });
                    return error.Checked;
                },
            }
        }

        /// The binding of `name`, or the error for a name not declared. A name whose declaration
        /// was refused fails with nothing more to say (section 2).
        fn resolve(checker: *Checker, index: u32, name: []const u8) Fail!u32 {
            const found = checker.find(name) orelse return checker.unknown_name(index, name);
            if (checker.memory.bindings[found].kind == .failed) return checker.reported();
            return found;
        }

        /// Whether `name` is a module declared in the file or a library it uses that `register`
        /// refused, so a call of it reports nothing more (section 2).
        fn module_refused(checker: *const Checker, name: []const u8) bool {
            if (checker.find_module(name) != null) return false;
            if (declares_module(checker.root, name)) return true;
            for (checker.root.declarations) |index| {
                const it = checker.root.item(index);
                if (it.tag != .use) continue;
                const used = checker.root.token_text(it.token);
                for (checker.memory.libraries) |library| {
                    if (!std.mem.eql(u8, library.name, used)) continue;
                    if (declares_module(library.tree, name)) return true;
                }
            }
            return false;
        }

        /// The failure of a use whose cause was already reported.
        fn reported(checker: *const Checker) Fail {
            assert(checker.diagnostics.total() > 0);
            return error.Checked;
        }

        /// After `declaration` refused the declaration `index`, binds its name as `failed`, when it
        /// has one that is free, so its uses are not reported again (section 2).
        fn bind_failed(checker: *Checker, index: u32) void {
            const it = checker.item(index);
            switch (it.tag) {
                .cue, .cue_series, .track, .bind => {},
                else => return,
            }
            const name = checker.tree.token_text(it.token);
            for (reserved) |word| if (std.mem.eql(u8, word, name)) return;
            if (checker.find(name) != null) return;
            if (checker.binding_count == checker.memory.bindings.len) return;
            checker.memory.bindings[checker.binding_count] = .{ .name = name, .item = index, .kind = .failed, .index = 0 };
            checker.binding_count += 1;
        }

        fn unknown_name(checker: *Checker, index: u32, name: []const u8) Fail {
            // `pi` and `tau` reach here only where a number is no answer: a cue, a noun, a path.
            if (checker.item(index).tag == .name) if (checker.known_number(index)) |_| {
                const diagnostic = checker.fail(index, .wrong_type, "`{s}` is a number, and not a name this file declares", .{name});
                error_module.hint(diagnostic, "a number goes where a number or a signal is due", .{});
                return error.Checked;
            };
            if (checker.in_module()) {
                const module = checker.memory.modules[checker.memory.frames[checker.frame].module.?];
                const diagnostic = checker.fail(index, .not_a_parameter, "`{s}` is not a parameter of {s}", .{ name, module.name });
                error_module.hint(diagnostic, "a module sees its parameters, the primitives, and the modules; pass `{s}` in", .{name});
                return error.Checked;
            }
            if (checker.declared_later(name)) |later| {
                const line = error_module.locate(checker.source(), checker.span_of(later)[0]).line;
                const diagnostic = checker.fail(index, .used_before_declared, "`{s}` is used before it is declared, on line {d}", .{ name, line });
                error_module.hint(diagnostic, "move it up, or go through a delay", .{});
                return error.Checked;
            }
            var buffer: [256][]const u8 = undefined;
            const diagnostic = checker.fail(index, .unknown_name, "`{s}` is not declared", .{name});
            if (error_module.nearest(name, checker.names_so_far(&buffer))) |near| {
                error_module.hint(diagnostic, "did you mean `{s}`?", .{near});
            }
            return error.Checked;
        }

        fn unknown_call(checker: *Checker, index: u32) Fail {
            const name = checker.text(index);
            if (checker.module_refused(name)) return checker.reported();
            const diagnostic = checker.fail_token(index, .unknown_call, "there is no call `{s}`", .{name});
            // Every call of the joined list, each name once, then the modules in the table, the
            // file's and its libraries'.
            var buffer: [calls_suggested_max + modules_suggested_max][]const u8 = undefined;
            var count: usize = 0;
            for (entries) |*entry| {
                var seen = false;
                for (buffer[0..count]) |known| seen = seen or std.mem.eql(u8, known, entry.name);
                if (seen) continue;
                buffer[count] = entry.name;
                count += 1;
            }
            const modules = @min(checker.module_count, modules_suggested_max);
            for (buffer[count..][0..modules], checker.memory.modules[0..modules]) |*slot, module| {
                slot.* = module.name;
            }
            if (error_module.nearest(name, buffer[0 .. count + modules])) |near| {
                error_module.hint(diagnostic, "did you mean `{s}`?", .{near});
            }
            return error.Checked;
        }

        /// Checks a call's arguments against its entry, and returns the call.
        fn check_call(checker: *Checker, entry: *const Entry, index: u32) Fail!u32 {
            const children = checker.tree.children(index);
            var given: [schema.params_max]?u32 = @splat(null);
            var positional: u32 = 0;
            var named = false;
            const positional_max = entry.positional_count();
            for (children) |child| {
                const it = checker.item(child);
                if (it.tag == .named) {
                    named = true;
                    const name = checker.text(child);
                    const param = entry.param(name) orelse {
                        var buffer: [schema.params_max][]const u8 = undefined;
                        for (entry.params, 0..) |candidate, at| buffer[at] = candidate.name;
                        const diagnostic = checker.fail_token(child, .unknown_parameter, "{s} has no parameter `{s}`", .{ entry.name, name });
                        if (error_module.nearest(name, buffer[0..entry.params.len])) |near| {
                            error_module.hint(diagnostic, "did you mean `{s}`?", .{near});
                        }
                        return error.Checked;
                    };
                    if (given[param] != null) {
                        _ = checker.fail_token(child, .duplicate_argument, "`{s}` is given twice", .{name});
                        return error.Checked;
                    }
                    given[param] = it.a;
                    continue;
                }
                if (named) {
                    const diagnostic = checker.fail(child, .positional_after_named, "an argument without a name comes after a named one", .{});
                    error_module.hint(diagnostic, "write it first, or give it its name", .{});
                    return error.Checked;
                }
                if (positional == positional_max) {
                    const diagnostic = checker.fail(child, .too_many_positional, "{s} takes {d} arguments without a name", .{ entry.name, positional_max });
                    error_module.hint(diagnostic, "name the others, such as `{s}: …`", .{entry.params[@min(positional_max, entry.params.len - 1)].name});
                    return error.Checked;
                }
                given[positional] = child;
                positional += 1;
            }
            if (checker.value_count + entry.params.len > checker.memory.values.len) {
                return checker.limit(index, "values", .tree, checker.memory.values.len);
            }
            if (checker.call_count == checker.memory.calls.len) {
                return checker.limit(index, "calls", .tree, checker.memory.calls.len);
            }
            const first = checker.value_count;
            checker.value_count += @intCast(entry.params.len);
            // A `from` left out is the `to` of the tween `after` names, read once `after` is
            // checked.
            var from_after: ?u32 = null;
            for (entry.params, 0..) |*param, at| {
                const slot = first + at;
                checker.memory.value_items[slot] = checker.site_of(given[at] orelse index);
                if (given[at] == null and param.default == .after) {
                    checker.memory.values[slot] = .absent;
                    from_after = @intCast(at);
                    continue;
                }
                checker.memory.values[slot] = if (given[at]) |child|
                    try checker.argument(entry, param, child)
                else
                    try checker.default_of(entry, param, index);
            }
            if (from_after) |at| {
                checker.memory.values[first + at] = try checker.after_to(entry, index, &given, first, at);
            }
            const at = checker.call_count;
            checker.memory.calls[at] = .{ .entry = entry, .values = first, .item = checker.site_of(index) };
            checker.call_count += 1;
            return at;
        }

        fn default_of(checker: *Checker, entry: *const Entry, param: *const schema.Param, index: u32) Fail!Value {
            return switch (param.default) {
                .required => {
                    const diagnostic = checker.fail_token(index, .missing_argument, "{s} needs `{s}`", .{ entry.name, param.name });
                    error_module.hint(diagnostic, "add `{s}: {s}`", .{ param.name, example_of(checker, param) });
                    return error.Checked;
                },
                .absent => .absent,
                .number => |number| if (param.kind == .integer) .{ .integer = @intFromFloat(number) } else .{ .number = number },
                .time => |flicks| .{ .time = flicks },
                .word => |word| .{ .word = word },
                .time_range => |range| .{ .time_range = range },
                .unbounded => .{ .number_range = .{ -std.math.inf(f64), std.math.inf(f64) } },
                .seed => .{ .seed = checker.derived_seed() },
                .whole => .absent,
                .text => |string| .{ .string = string },
                // `check_call` fills it in from `after`, once `after` is checked (section 6b).
                .after => unreachable,
            };
        }

        /// The `to` of the tween a call's `after` names, for the `from` it leaves out (section 6b).
        fn after_to(checker: *Checker, entry: *const Entry, index: u32, given: *const [schema.params_max]?u32, first: u32, from_at: u32) Fail!Value {
            assert(checker.value_count >= first + entry.params.len);
            const rule = entry.after.?;
            const from = entry.params[from_at].name;
            const after_at = entry.param(rule.by).?;
            const after_item = given[after_at] orelse {
                const diagnostic = checker.fail_token(index, .missing_argument, "{s} needs `{s}`", .{ entry.name, from });
                error_module.hint(diagnostic, "`{s}` may be left out only when `{s}` names a {s}", .{ from, rule.by, entry.name });
                return error.Checked;
            };
            // A client's entry may give `.after` to a parameter whose `by` is not a signal.
            const after = checker.memory.values[first + after_at];
            const named = if (after == .signal) checker.tween_named(entry, after.signal) else null;
            const call = named orelse {
                const diagnostic = checker.fail(after_item, .missing_argument, "{s} needs `{s}`, since `{s}` is not a name bound to a {s}", .{ entry.name, from, rule.by, entry.name });
                error_module.hint(diagnostic, "`{s}` may be left out only when `{s}` names a {s}", .{ from, rule.by, entry.name });
                return error.Checked;
            };
            const before = checker.memory.calls[call];
            const to = checker.memory.values[before.values + before.entry.param(rule.takes).?];
            assert(to == .number or to == .vector);
            return to;
        }

        /// The tween call that `expr` names (section 6b): a name bound to a tween, or to a region
        /// of one tween, or null. It reads two expressions and no more, so a chain costs nothing
        /// per link.
        fn tween_named(checker: *const Checker, entry: *const Entry, expr: u32) ?u32 {
            const name = checker.memory.exprs[expr];
            if (name.tag != .binding or name.b != 0) return null;
            const binding = checker.memory.bindings[name.a];
            if (binding.kind != .signal) return null;
            const node = checker.memory.exprs[binding.index];
            if (node.tag != .call or node.b != 0) return null;
            const call = checker.memory.calls[node.a];
            if (same_call(call.entry, entry)) return node.a;
            if (call.entry.op != .lanes) return null;
            const body = checker.memory.exprs[checker.memory.values[call.values + 1].signal];
            if (body.tag != .call or body.b != 0) return null;
            if (!same_call(checker.memory.calls[body.a].entry, entry)) return null;
            return body.a;
        }

        /// Whether `found` is a call of the entry `wanted` names: the same name and role.
        fn same_call(found: *const Entry, wanted: *const Entry) bool {
            return found.role == wanted.role and std.mem.eql(u8, found.name, wanted.name);
        }

        /// The parameter `index` names in the current frame, bound to its argument (section 6).
        fn bound(checker: *const Checker, index: u32) ?Arg {
            const slot = checker.bound_slot(index) orelse return null;
            return checker.memory.frames[checker.frame].args[slot];
        }

        /// Which parameter of the current frame `index` names, if it is a parameter's name.
        fn bound_slot(checker: *const Checker, index: u32) ?u32 {
            const frame = &checker.memory.frames[checker.frame];
            assert(checker.frame < checker.frame_count);
            assert(frame.tree == checker.tree);
            if (frame.module == null) return null;
            const it = checker.tree.item(index);
            if (it.tag != .name) return null;
            const name = checker.tree.text(index);
            for (0..frame.params) |at| {
                if (std.mem.eql(u8, frame.tree.text(frame.param_items[at]), name)) return @intCast(at);
            }
            return null;
        }

        /// Checks a bound argument's signal in the frame it came from.
        fn signal_in(checker: *Checker, arg: Arg) Fail!u32 {
            const saved = checker.frame;
            checker.focus(arg.frame);
            defer checker.focus(saved);
            return checker.signal(arg.item);
        }

        /// The entry called `name` in `role`, which `join` has made sure is one: a primitive, a
        /// language entry, or one of the client's nouns. It is found in the list it came from, not
        /// in the joined copy, so a client that tells its entries apart by address (Tapestry's
        /// `kind_of`) finds the entry it gave.
        fn lookup(checker: *const Checker, name: []const u8, role: schema.Role) ?*const Entry {
            _ = checker;
            const lists = [3][]const Entry{ vocabulary.entries, &schema.language_entries, clients };
            for (lists) |list| {
                for (list) |*entry| {
                    if (entry.role == role and std.mem.eql(u8, entry.name, name)) return entry;
                }
            }
            return null;
        }

        fn find_module(checker: *const Checker, name: []const u8) ?u32 {
            for (checker.memory.modules[0..checker.module_count], 0..) |module, at| {
                if (std.mem.eql(u8, module.name, name)) return @intCast(at);
            }
            return null;
        }

        /// Records a module of `tree`, declared at `index`. Errors are reported at `report`, the
        /// file's `use` line for a library's module, so they point into the file.
        fn add_module(checker: *Checker, tree: *const Tree, index: u32, report: u32) Fail!void {
            const name = tree.token_text(tree.item(index).token);
            for (reserved) |word| {
                if (std.mem.eql(u8, word, name)) {
                    const diagnostic = checker.fail(report, .reserved_name, "`{s}` is a keyword, not a module's name", .{name});
                    error_module.hint(diagnostic, "choose another name, such as `{s}_1`", .{name});
                    return error.Checked;
                }
            }
            if (checker.lookup(name, .signal) != null or checker.lookup(name, .mover) != null) {
                const diagnostic = checker.fail(report, .reserved_name, "`{s}` is a primitive, not a module's name", .{name});
                error_module.hint(diagnostic, "choose another name, such as `{s}_1`", .{name});
                return error.Checked;
            }
            if (checker.find_module(name) != null) {
                const diagnostic = checker.fail(report, .duplicate_name, "the module `{s}` is declared twice", .{name});
                error_module.hint(diagnostic, "rename one of them, or remove the `use` that brings it in", .{});
                return error.Checked;
            }
            const params = tree.children(tree.item(index).a);
            for (params, 0..) |param, at| {
                const param_name = tree.token_text(tree.item(param).token);
                for (params[0..at]) |earlier| {
                    if (!std.mem.eql(u8, tree.token_text(tree.item(earlier).token), param_name)) continue;
                    // At the second one in the file; at the `use` for a library's module.
                    const at_item = if (tree == checker.root) param else report;
                    const diagnostic = checker.fail_token(at_item, .duplicate_name, "`{s}` is a parameter of `{s}` twice", .{ param_name, name });
                    error_module.hint(diagnostic, "rename one of them", .{});
                    return error.Checked;
                }
            }
            for (params) |param| {
                const default = tree.item(param).a;
                if (default == 0 or tree.item(default - 1).tag == .literal) continue;
                if (folds_alone(tree, default - 1, params, false, 0)) continue;
                const diagnostic = checker.fail(report, .wrong_type, "the default of `{s}` in {s} is not a literal", .{ tree.text(param), name });
                error_module.hint(diagnostic, "a default is a number, a time, or a frequency, such as `0.25s`", .{});
                return error.Checked;
            }
            if (tree.children(tree.item(index).a).len > schema.params_max) {
                const diagnostic = checker.fail(report, .limit, "`{s}` has more than {d} parameters", .{ name, schema.params_max });
                error_module.hint(diagnostic, "a module takes at most {d}; split it", .{schema.params_max});
                return error.Checked;
            }
            if (checker.module_count == checker.memory.modules.len) {
                return checker.limit(report, "modules", .modules, checker.memory.modules.len);
            }
            checker.memory.modules[checker.module_count] = .{ .name = name, .tree = tree, .item = index };
            checker.module_count += 1;
        }

        /// `use name`: every module of the library `name` joins the file's table.
        fn use_library(checker: *Checker, index: u32) Fail!void {
            const name = checker.tree.token_text(checker.item(index).token);
            for (checker.memory.libraries) |library| {
                if (!std.mem.eql(u8, library.name, name)) continue;
                for (library.tree.declarations) |declaration_index| {
                    if (library.tree.item(declaration_index).tag != .module) continue;
                    try checker.add_module(library.tree, declaration_index, index);
                }
                return;
            }
            const diagnostic = checker.fail_token(index, .unknown_library, "there is no library `{s}`", .{name});
            error_module.hint(diagnostic, "pass it to `compile_with` under its name", .{});
            return error.Checked;
        }

        /// Records the file's modules and its `use` lines, before any declaration is checked, so a
        /// module can be used above or below its declaration.
        fn register(checker: *Checker, tree: *const Tree) void {
            for (tree.declarations) |index| {
                switch (tree.item(index).tag) {
                    .module => checker.add_module(tree, index, index) catch {},
                    .use => checker.use_library(index) catch {},
                    else => {},
                }
            }
        }

        /// Expands the module `module` for `call` (an item of the current frame): binds each
        /// parameter, and returns the new frame. The caller checks the body there, then frees the
        /// frame by resetting `frame_count`.
        fn enter_module(checker: *Checker, module: u32, call: u32) Fail!u32 {
            const found = checker.memory.modules[module];
            assert(module < checker.module_count);
            assert(checker.frame < checker.frame_count);
            var chain = checker.frame;
            for (0..checker.frame_count) |_| {
                if (checker.memory.frames[chain].module == module) return checker.module_cycle(module, call);
                if (chain == 0) break;
                chain = checker.memory.frames[chain].parent;
            }
            if (checker.frame_count == checker.memory.frames.len) {
                const diagnostic = checker.fail(call, .limit, "the modules nest deeper than {d}", .{module_depth_max});
                error_module.hint(diagnostic, "a module that calls a module nests one deeper; flatten the patch", .{});
                return error.Checked;
            }
            const caller = checker.frame;
            const module_tree = found.tree;
            const module_item = module_tree.item(found.item);
            const params = module_tree.children(module_item.a);
            var given: [schema.params_max]?u32 = @splat(null);
            try checker.match_module(module_tree, found.name, params, call, &given);
            const frame_index = checker.frame_count;
            const caller_frame = &checker.memory.frames[caller];
            const ordinal = caller_frame.instances;
            caller_frame.instances += 1;
            var frame: Frame = .{
                .tree = module_tree,
                .site = if (checker.is_library(caller)) caller_frame.site else call,
                .module = module,
                .parent = caller,
                .body = module_item.b,
                .seed_base = vocabulary.seed_hash(caller_frame.seed_base, std.hash.Fnv1a_64.hash(found.name) +% ordinal),
                .params = @intCast(params.len),
            };
            for (params, 0..) |param, at| {
                const param_item = module_tree.item(param);
                frame.param_items[at] = param;
                if (given[at]) |child| {
                    frame.args[at] = .{ .item = child, .frame = caller };
                } else if (param_item.a != 0) {
                    frame.args[at] = .{ .item = param_item.a - 1, .frame = frame_index };
                } else {
                    const diagnostic = checker.fail(call, .missing_argument, "{s} needs `{s}`", .{ found.name, module_tree.text(param) });
                    error_module.hint(diagnostic, "add `{s}: …`", .{module_tree.text(param)});
                    return error.Checked;
                }
            }
            checker.memory.frames[frame_index] = frame;
            checker.frame_count += 1;
            if (module_item.c != 0) {
                const saved = checker.frame;
                checker.focus(frame_index);
                defer checker.focus(saved);
                checker.memory.frames[frame_index].declared = checker.number_range(module_item.c - 1) catch |err| {
                    checker.frame_count = frame_index;
                    return err;
                };
            }
            return frame_index;
        }

        /// Matches a module call's arguments to its parameters, as a primitive's are matched.
        fn match_module(
            checker: *Checker,
            module_tree: *const Tree,
            name: []const u8,
            params: []const u32,
            call: u32,
            given: *[schema.params_max]?u32,
        ) Fail!void {
            var positional: u32 = 0;
            var named = false;
            for (checker.tree.children(call)) |child| {
                const it = checker.item(child);
                if (it.tag == .named) {
                    named = true;
                    const argument_name = checker.text(child);
                    var slot: ?usize = null;
                    for (params, 0..) |param, at| {
                        if (std.mem.eql(u8, module_tree.text(param), argument_name)) {
                            slot = at;
                            break;
                        }
                    }
                    const at = slot orelse {
                        var names: [schema.params_max][]const u8 = undefined;
                        for (params, 0..) |param, k| names[k] = module_tree.text(param);
                        const diagnostic = checker.fail_token(child, .unknown_parameter, "{s} has no parameter `{s}`", .{ name, argument_name });
                        if (error_module.nearest(argument_name, names[0..params.len])) |near| {
                            error_module.hint(diagnostic, "did you mean `{s}`?", .{near});
                        }
                        return error.Checked;
                    };
                    if (given[at] != null) {
                        _ = checker.fail_token(child, .duplicate_argument, "`{s}` is given twice", .{argument_name});
                        return error.Checked;
                    }
                    given[at] = it.a;
                    continue;
                }
                if (named) {
                    const diagnostic = checker.fail(child, .positional_after_named, "an argument without a name comes after a named one", .{});
                    error_module.hint(diagnostic, "write it first, or give it its name", .{});
                    return error.Checked;
                }
                if (positional == params.len) {
                    const diagnostic = checker.fail(child, .too_many_positional, "{s} takes {d} arguments", .{ name, params.len });
                    if (params.len == 0) {
                        error_module.hint(diagnostic, "call it with none, `{s}()`", .{name});
                    } else {
                        error_module.hint(diagnostic, "remove the extra ones", .{});
                    }
                    return error.Checked;
                }
                given[positional] = child;
                positional += 1;
            }
        }

        /// The error for a module that reaches itself: the modules on the chain of callers, from
        /// the first time it was called, then itself again.
        fn module_cycle(checker: *Checker, module: u32, call: u32) Fail!u32 {
            var chain_modules: [frames_max]u32 = undefined;
            var count: usize = 0;
            var chain = checker.frame;
            for (0..checker.frame_count) |_| {
                const frame = checker.memory.frames[chain];
                const of = frame.module orelse break;
                chain_modules[count] = of;
                count += 1;
                if (of == module) break;
                chain = frame.parent;
            }
            assert(count > 0);
            assert(chain_modules[count - 1] == module);
            var path: [error_module.hint_len_max]u8 = undefined;
            var length: usize = 0;
            var at = count;
            while (at > 0) {
                at -= 1;
                length = append_name(&path, length, checker.memory.modules[chain_modules[at]].name);
                length = append_name(&path, length, " -> ");
            }
            length = append_name(&path, length, checker.memory.modules[module].name);
            const diagnostic = checker.fail(call, .module_cycle, "the module `{s}` uses itself", .{checker.memory.modules[module].name});
            error_module.hint(diagnostic, "the cycle is {s}; break it with a parameter or a primitive", .{path[0..length]});
            return error.Checked;
        }

        fn append_name(buffer: []u8, length: usize, chunk: []const u8) usize {
            const room = buffer.len - length;
            const count = @min(room, chunk.len);
            @memcpy(buffer[length..][0..count], chunk[0..count]);
            return length + count;
        }

        /// `module(args)` as a signal: its body, checked in its frame.
        fn expand_signal(checker: *Checker, module: u32, call: u32) Fail!u32 {
            const frame = try checker.enter_module(module, call);
            defer checker.frame_count = frame;
            const saved = checker.frame;
            checker.focus(frame);
            defer checker.focus(saved);
            const expr = try checker.signal(checker.memory.frames[frame].body);
            checker.declared_last = checker.memory.frames[frame].declared;
            return expr;
        }

        /// A mover: a primitive mover, or a module whose body is one (section 6).
        fn mover_of(checker: *Checker, index: u32, param: []const u8) Fail!u32 {
            if (checker.bound(index)) |arg| {
                const saved = checker.frame;
                checker.focus(arg.frame);
                defer checker.focus(saved);
                return checker.mover_of(arg.item, param);
            }
            const it = checker.item(index);
            if (it.tag == .call) {
                const name = checker.text(index);
                if (checker.lookup(name, .mover)) |entry| return checker.check_call(entry, index);
                if (checker.find_module(name)) |module| {
                    const frame = try checker.enter_module(module, index);
                    defer checker.frame_count = frame;
                    const saved = checker.frame;
                    checker.focus(frame);
                    defer checker.focus(saved);
                    return checker.mover_of(checker.memory.frames[frame].body, param);
                }
            }
            const diagnostic = checker.fail(index, .wrong_type, "`{s}` takes a mover", .{param});
            var buffer: [hint_list_size]u8 = undefined;
            const examples = checker.mover_examples(&buffer);
            if (examples.len > 0) error_module.hint(diagnostic, "{s}", .{examples});
            return error.Checked;
        }

        fn shape_of(checker: *const Checker, expr: u32) Shape {
            return checker.memory.exprs[expr].shape;
        }

        fn lanes_of(checker: *const Checker, expr: u32) u32 {
            return checker.memory.exprs[expr].lanes;
        }

        /// Refuses a signal whose shape or lanes the parameter's `need` does not take (step 55b).
        fn expect_need(checker: *Checker, index: u32, entry: *const Entry, param: *const schema.Param, expr: u32) Fail!void {
            const need = param.need;
            const shape = checker.shape_of(expr);
            const lanes = checker.lanes_of(expr);
            const shape_fits = if (need.colour) shape.colour else if (need.components == 0) true else (!shape.colour and shape.components == need.components);
            const lanes_fit = switch (need.lanes) {
                .any => true,
                .one => lanes == 1,
                .many => lanes >= 2,
            };
            if (shape_fits and lanes_fit) return;
            var need_buffer: [need_text_size]u8 = undefined;
            var found_buffer: [need_text_size]u8 = undefined;
            _ = checker.fail(index, .wrong_shape, "`{s}` of {s} takes {s}, and this is {s}", .{
                param.name,
                entry.name,
                need_text(need, &need_buffer),
                found_text(shape, lanes, &found_buffer),
            });
            return error.Checked;
        }

        /// Refuses a number outside its parameter's `range`, at the number's own item: a whole
        /// number where the parameter is an `integer` (section 3).
        fn in_range(checker: *Checker, index: u32, param: *const schema.Param, number: f64) Fail!void {
            const range = param.range orelse return;
            const whole = param.kind != .integer or @floor(number) == number;
            if (number >= range[0] and number <= range[1] and whole) return;
            const diagnostic = if (param.kind == .integer)
                checker.fail(index, .out_of_range, "`{s}` is a whole number from {d} to {d}", .{ param.name, range[0], range[1] })
            else
                checker.fail(index, .out_of_range, "`{s}` is from {d} to {d}", .{ param.name, range[0], range[1] });
            if (param.hint.len > 0) error_module.hint(diagnostic, "{s}", .{param.hint});
            return error.Checked;
        }

        /// `lanes(n, …)`'s count: opens a region of n lanes for its body (section 9).
        fn open_region(checker: *Checker, index: u32, number: f64) Fail!void {
            if (checker.region) |count| {
                const diagnostic = checker.fail(index, .wrong_lanes, "a region of lanes is inside `lanes({d}, …)`", .{count});
                error_module.hint(diagnostic, "regions do not nest; give the outer region the lanes of both", .{});
                return error.Checked;
            }
            if (!(number >= 1 and number <= lanes_max)) {
                const diagnostic = checker.fail(index, .out_of_range, "a region has from 1 to {d} lanes", .{lanes_max});
                error_module.hint(diagnostic, "for example `lanes(1000, …)`", .{});
                return error.Checked;
            }
            checker.region = @intFromFloat(number);
        }

        /// `lane`: each lane's index, inside a region (section 9).
        fn lane_index(checker: *Checker, index: u32) Fail!u32 {
            const count = checker.region orelse {
                const diagnostic = checker.fail(index, .wrong_lanes, "`lane` is a lane's index, so it is used inside `lanes(n, …)`", .{});
                error_module.hint(diagnostic, "wrap the expression in a region, such as `lanes(1000, lane * 0.001)`", .{});
                return error.Checked;
            };
            return checker.push_expr(.{ .tag = .lane, .item = index, .lanes = count });
        }

        /// The lanes of `left` and `right` together (section 9): one lane is broadcast, and two
        /// counts above 1 must be equal.
        fn join_lanes(checker: *Checker, index: u32, left: u32, right: u32) Fail!u32 {
            return checker.joined(index, checker.lanes_of(left), checker.lanes_of(right));
        }

        fn joined(checker: *Checker, index: u32, a: u32, b: u32) Fail!u32 {
            if (a == b or b == 1) return a;
            if (a == 1) return b;
            const diagnostic = checker.fail(index, .wrong_lanes, "{d} lanes and {d} lanes do not go together", .{ a, b });
            error_module.hint(diagnostic, "lanes meet where their counts are equal, or where one side has one lane", .{});
            return error.Checked;
        }

        /// Refuses a signal of many lanes where `name` takes one value for every lane (section 9).
        fn expect_one_lane(checker: *Checker, index: u32, expr: u32, name: []const u8) Fail!void {
            const lanes = checker.lanes_of(expr);
            if (lanes == 1) return;
            const diagnostic = checker.fail(index, .wrong_lanes, "`{s}` takes one value for every lane, found {d} lanes", .{ name, lanes });
            error_module.hint(diagnostic, "a node has one law; let the lanes differ in what it reads instead", .{});
            return error.Checked;
        }

        /// Holds every signal a mover reads to one lane: its law is one node (section 9).
        fn expect_mover_one_lane(checker: *Checker, mover: u32) Fail!void {
            const mover_entry = checker.memory.calls[mover].entry;
            const mover_first = checker.memory.calls[mover].values;
            const mover_values = checker.memory.values[mover_first..][0..mover_entry.params.len];
            const mover_items = checker.memory.value_items[mover_first..][0..mover_entry.params.len];
            assert(mover_entry.role == .mover);
            for (mover_entry.params, mover_values, mover_items) |param, value, value_item| {
                if (value == .signal) try checker.expect_one_lane(value_item, value.signal, param.name);
            }
        }

        /// The lanes of a call (section 9): a per-lane source's region, else the most of its
        /// signals'.
        fn call_lanes(checker: *Checker, call: u32, index: u32) Fail!u32 {
            const entry = checker.memory.calls[call].entry;
            const first = checker.memory.calls[call].values;
            const values = checker.memory.values[first..][0..entry.params.len];
            const items = checker.memory.value_items[first..][0..entry.params.len];
            for (entry.params, values, items) |param, value, value_item| {
                if (param.live and value == .signal) try checker.expect_one_lane(value_item, value.signal, param.name);
            }
            for (entry.params, values) |param, value| {
                if (param.kind != .mover or value != .mover) continue;
                try checker.expect_mover_one_lane(value.mover);
            }
            var lanes: u32 = 1;
            // The rule `describe` prints for the call, so the two cannot differ.
            switch (entry.lane_rule()) {
                .makes => return @intCast(values[0].integer),
                .region => return checker.region orelse 1,
                .stagger => {
                    const at = entry.param("stagger").?;
                    if (checker.call_by_lane(entry, values)) {
                        if (values[at].time != 0) {
                            const diagnostic = checker.fail(items[at], .wrong_lanes, "`stagger:` and a cue chosen by lane both set when each lane starts", .{});
                            error_module.hint(diagnostic, "each lane already starts at its own cue; drop `stagger:`", .{});
                            return error.Checked;
                        }
                        // `cue_ref` found the region.
                        lanes = checker.region.?;
                    } else if (values[at].time != 0) lanes = checker.region orelse {
                        const diagnostic = checker.fail(items[at], .wrong_lanes, "`stagger:` spreads lanes in time, so it is used inside `lanes(n, …)`", .{});
                        error_module.hint(diagnostic, "wrap the call in a region, or drop `stagger:`", .{});
                        return error.Checked;
                    };
                },
                .inputs, .one => {},
                .apart => return 1,
            }
            for (entry.params, values) |param, value| {
                if (value != .signal or param.live) continue;
                lanes = try checker.joined(index, lanes, checker.lanes_of(value.signal));
            }
            return lanes;
        }

        /// Whether a call's lanes each start at their own cue (section 9a): the parameter its entry
        /// declares `by_lane` has a cue by lane, or a path whose one goal, one a run, has the flag.
        fn call_by_lane(checker: *const Checker, entry: *const Entry, values: []const Value) bool {
            assert(values.len == entry.params.len);
            for (entry.params, values) |param, value| {
                if (!param.by_lane) continue;
                if (param.kind == .cue) return value == .cue_by_lane;
                assert(param.kind == .path);
                if (value != .path) return false;
                const run = checker.memory.paths[value.path];
                assert(run.count > 0);
                const by_lane = checker.memory.goals[run.first].cue_by_lane;
                if (by_lane) assert(run.count == 1);
                return by_lane;
            }
            return false;
        }

        /// The shape of `left` and `right` together (section 8): theirs when equal, the other's
        /// when one is a number; a colour and a vector, two vectors of different sizes, and a
        /// product of two colours are refused.
        fn combine(checker: *Checker, index: u32, left: u32, right: u32, product: bool) Fail!Shape {
            const a = checker.shape_of(left);
            const b = checker.shape_of(right);
            if (product and a.colour and b.colour) {
                const diagnostic = checker.fail(index, .wrong_shape, "two colours do not multiply", .{});
                error_module.hint(diagnostic, "scale a colour by a number, or multiply components, such as `a.l * b.l`", .{});
                return error.Checked;
            }
            if (a.eql(b) or b.eql(Shape.scalar)) return a;
            if (a.eql(Shape.scalar)) return b;
            const diagnostic = checker.fail(index, .wrong_shape, "{s} and {s} do not go together", .{ a.noun(), b.noun() });
            if (a.colour or b.colour) {
                error_module.hint(diagnostic, "a colour's components are `.l .a .b`; take one to mix it with a vector", .{});
            } else {
                error_module.hint(diagnostic, "make them one size, or take a component such as `.x`", .{});
            }
            return error.Checked;
        }

        /// Refuses a vector or a colour where `name` takes one value (section 8).
        fn expect_scalar(checker: *Checker, index: u32, expr: u32, name: []const u8) Fail!void {
            const shape = checker.shape_of(expr);
            if (shape.eql(Shape.scalar)) return;
            const diagnostic = checker.fail(index, .wrong_shape, "`{s}` takes one value, found {s}", .{ name, shape.noun() });
            error_module.hint(diagnostic, "take a component, such as `.{s}`", .{shape.component_names()[0]});
            return error.Checked;
        }

        /// The shape of a call (section 8): what its entry says its value is, from its parameters.
        fn call_shape(checker: *Checker, call: u32, index: u32) Fail!Shape {
            const entry = checker.memory.calls[call].entry;
            const values = checker.memory.values[checker.memory.calls[call].values..][0..entry.params.len];
            assert(values.len == entry.params.len);
            switch (entry.shape) {
                .one => return Shape.scalar,
                .of => |name| return checker.value_shape(values[entry.param(name).?]),
                .agree => |names| {
                    const shape = try checker.call_agree(entry, values, index, names);
                    try checker.after_shape(entry, values, index, shape);
                    return shape;
                },
                .combine => |names| {
                    const left = values[entry.param(names[0]).?].signal;
                    return checker.combine(index, left, values[entry.param(names[1]).?].signal, false);
                },
                .constructor => |constructor| return .{
                    .components = @intCast(entry.params.len),
                    .colour = constructor.colour,
                },
            }
        }

        /// The shape of one value a rule reads: a vector's own, a path's goals', a signal's.
        fn value_shape(checker: *const Checker, value: Value) Shape {
            return switch (value) {
                .path => |path| checker.memory.paths[path].shape,
                .signal => |expr| checker.shape_of(expr),
                else => value.shape(),
            };
        }

        /// The shape of two parameters that agree. A path of numbers is one run, so a second with
        /// components has nowhere to go (section 8).
        fn call_agree(checker: *Checker, entry: *const Entry, values: []const Value, index: u32, names: [2][]const u8) Fail!Shape {
            const first = values[entry.param(names[0]).?];
            const second = values[entry.param(names[1]).?];
            const a = checker.value_shape(first);
            const b = checker.value_shape(second);
            if (first != .path) return checker.agree(index, a, b, names, false);
            if (a.eql(Shape.scalar) and !b.eql(Shape.scalar)) {
                const diagnostic = checker.fail(index, .wrong_shape, "the {s} are numbers, and `{s}` {s}", .{ names[0], names[1], b.noun() });
                error_module.hint(diagnostic, "write the {s} as {s}s too, or `{s}` as a number", .{ names[0], b.noun()[2..], names[1] });
                return error.Checked;
            }
            return checker.agree(index, a, b, names, true);
        }

        /// A call that continues another (section 6b) has the shape of the value it continues from:
        /// its `by` parameter, when a signal, is held to the call's own shape.
        fn after_shape(checker: *Checker, entry: *const Entry, values: []const Value, index: u32, shape: Shape) Fail!void {
            const after = entry.after orelse return;
            const value = values[entry.param(after.by).?];
            if (value != .signal) return;
            const found = checker.shape_of(value.signal);
            if (found.eql(shape)) return;
            _ = checker.fail(index, .wrong_shape, "`{s}` is {s}, and this {s} {s}", .{ after.by, found.noun(), entry.name, shape.noun() });
            return error.Checked;
        }

        /// Two shapes that must agree, a number broadcast to a vector. A number is never broadcast
        /// to a colour, whose three components are not alike (section 8). `names` are the two
        /// parameters, and `path_first` says the first is a path of goals.
        fn agree(checker: *Checker, index: u32, a: Shape, b: Shape, names: [2][]const u8, path_first: bool) Fail!Shape {
            if (a.eql(b)) return a;
            if (!a.colour and !b.colour) {
                if (b.eql(Shape.scalar)) return a;
                if (a.eql(Shape.scalar)) return b;
            }
            const diagnostic = if (path_first)
                checker.fail(index, .wrong_shape, "the {s} and `{s}` differ: {s} and {s}", .{ names[0], names[1], a.noun(), b.noun() })
            else
                checker.fail(index, .wrong_shape, "`{s}` and `{s}` differ: {s} and {s}", .{ names[0], names[1], a.noun(), b.noun() });
            if ((a.colour and b.eql(Shape.scalar)) or (b.colour and a.eql(Shape.scalar))) {
                error_module.hint(diagnostic, "write the number as a colour, such as `oklab(0.5, 0, 0)`", .{});
            }
            return error.Checked;
        }

        /// A vector or a colour written as numbers (section 8), or null for anything else: a call
        /// of `vec2`, `vec3`, `oklab`, or `srgb` whose arguments are all numbers that fold (section
        /// 3b).
        fn constant_vector(checker: *Checker, index: u32) Fail!?Vector {
            if (checker.bound(index)) |arg| {
                const saved = checker.frame;
                checker.focus(arg.frame);
                defer checker.focus(saved);
                return checker.constant_vector(arg.item);
            }
            const it = checker.item(index);
            if (it.tag != .call) return null;
            const entry = checker.lookup(checker.text(index), .signal) orelse return null;
            const constructor = switch (entry.shape) {
                .constructor => |found| found,
                else => return null,
            };
            const children = checker.tree.children(index);
            if (children.len != entry.params.len) return null;
            for (children) |child| {
                // A literal of another kind stays in, so it is refused as a component, as before.
                if (checker.item(child).tag != .literal and !checker.folds(child)) return null;
            }
            var vector: Vector = .{ .values = @splat(0), .shape = .{
                .components = @intCast(entry.params.len),
                .colour = constructor.colour,
            } };
            for (children, entry.params, 0..) |child, param, at| {
                vector.values[at] = try checker.fixed_number(child, "a component");
                try checker.in_range(child, &param, vector.values[at]);
            }
            if (constructor.converts) vector.values = vocabulary.convert(entry, vector.values);
            return vector;
        }

        /// A path of vectors (section 8): one run a component, in order, never shared.
        fn vector_path(checker: *Checker, index: u32, goals: []const Goal, values: []const [4]f64, shape: Shape, declared: bool) Fail!u32 {
            const count = shape.components;
            if (goals.len * count > checker.memory.goals.len - checker.goal_count) {
                return checker.limit(index, "goals", .goals, checker.memory.goals.len);
            }
            if (checker.path_count + count > checker.memory.paths.len) return checker.limit(index, "paths", .goals, checker.memory.paths.len);
            const first_path = checker.path_count;
            for (0..count) |k| {
                const first = checker.goal_count;
                for (goals, values, 0..) |goal, value, at| {
                    checker.memory.goals[first + at] = .{ .cue = goal.cue, .value = value[k], .cue_by_lane = goal.cue_by_lane };
                }
                checker.goal_count += @intCast(goals.len);
                checker.memory.paths[checker.path_count] = .{
                    .first = first,
                    .count = @intCast(goals.len),
                    .declared = declared,
                    .shape = if (k == 0) shape else Shape.scalar,
                };
                checker.path_count += 1;
            }
            return first_path;
        }

        /// `base.x`: a component of `vector`, a name or a call of a vector or a colour (section 8).
        fn component_of(checker: *Checker, index: u32, vector: u32, output_name: []const u8) Fail!u32 {
            const shape = checker.shape_of(vector);
            for (shape.component_names(), 0..) |name, component| {
                if (!std.mem.eql(u8, name, output_name)) continue;
                return checker.push_expr(.{ .tag = .pick, .a = vector, .b = @intCast(component), .item = index, .lanes = checker.lanes_of(vector) });
            }
            const diagnostic = checker.fail_token(index, .unknown_output, "{s} has no component `{s}`", .{ shape.noun(), output_name });
            const names = shape.component_names();
            if (names.len == 2) {
                error_module.hint(diagnostic, "its components are `.{s}` and `.{s}`", .{ names[0], names[1] });
            } else {
                error_module.hint(diagnostic, "its components are `.{s}`, `.{s}`, and `.{s}`", .{ names[0], names[1], names[2] });
            }
            return error.Checked;
        }

        /// The seed of section 5, for the next seeded call of this declaration.
        fn derived_seed(checker: *Checker) u64 {
            const frame = &checker.memory.frames[checker.frame];
            const base = frame.seed_base;
            const ordinal = frame.seeded;
            frame.seeded += 1;
            return if (ordinal == 0) base else vocabulary.seed_hash(base, ordinal);
        }

        fn argument(checker: *Checker, entry: *const Entry, param: *const schema.Param, index: u32) Fail!Value {
            if (checker.bound(index)) |arg| {
                const saved = checker.frame;
                checker.focus(arg.frame);
                defer checker.focus(saved);
                return checker.argument(entry, param, arg.item);
            }
            const it = checker.item(index);
            switch (param.kind) {
                .number => {
                    // A number that folds is fixed as its literal is, even where a signal may set
                    // it (section 3b), so `2 * pi` builds what `6.283185307179586` builds.
                    if (it.tag == .literal or checker.folds(index)) {
                        const number = try checker.fixed_number(index, "a number");
                        try checker.in_range(index, param, number);
                        return .{ .number = number };
                    }
                    if (param.shaped) if (try checker.constant_vector(index)) |vector| return .{ .vector = vector };
                    if (!param.live) return checker.not_live(entry, param, index);
                    const expr = try checker.signal(index);
                    try checker.expect_scalar(index, expr, param.name);
                    try checker.expect_need(index, entry, param, expr);
                    return .{ .signal = expr };
                },
                .integer => {
                    const number = try checker.fixed_number(index, "a whole number");
                    try checker.in_range(index, param, number);
                    if (!(number >= 0 and number <= 0x1p32 and @floor(number) == number)) {
                        _ = checker.fail(index, .out_of_range, "`{s}` is a whole number from 0 to 2^32", .{param.name});
                        return error.Checked;
                    }
                    if (entry.op == .lanes) try checker.open_region(index, number);
                    return .{ .integer = @intFromFloat(number) };
                },
                .time => {
                    if (it.tag == .literal) return .{ .time = try checker.literal_time(index) };
                    if (!param.live) return checker.not_live(entry, param, index);
                    const expr = try checker.signal(index);
                    try checker.expect_scalar(index, expr, param.name);
                    return .{ .signal = expr };
                },
                .frequency => {
                    if (it.tag != .literal or checker.tree.tokens[it.token].tag != .frequency) {
                        // A live frequency takes a signal, which the client's own back end builds;
                        // a bare number keeps the hint that says to write the unit.
                        if (param.live and it.tag != .literal) {
                            const expr = try checker.signal(index);
                            try checker.expect_scalar(index, expr, param.name);
                            return .{ .signal = expr };
                        }
                        const diagnostic = checker.fail(index, .wrong_type, "`{s}` takes a frequency", .{param.name});
                        if (it.tag == .literal) error_module.hint(diagnostic, "write `{s}hz`", .{checker.text(index)}) else error_module.hint(diagnostic, "for example `1hz`", .{});
                        return error.Checked;
                    }
                    const digits = token_module.digits_of(checker.tree.tokens[it.token], checker.source());
                    const number = parse_float(digits) orelse return checker.bad_number(index);
                    return .{ .frequency = if (it.a == 1) -number else number };
                },
                .signal => {
                    const expr = try checker.signal(index);
                    if (!param.shaped) try checker.expect_scalar(index, expr, param.name);
                    try checker.expect_need(index, entry, param, expr);
                    return .{ .signal = expr };
                },
                .cue => {
                    const found = try checker.cue_ref(index, if (param.by_lane) .taken else .refused);
                    if (found.by_lane) return .{ .cue_by_lane = found.index };
                    return .{ .cue = found.index };
                },
                .cues => {
                    if (it.tag == .name) {
                        if (checker.find(checker.text(index))) |found| {
                            const binding = checker.memory.bindings[found];
                            if (binding.kind == .series) return .{ .span = .{ .first = binding.index, .count = binding.count } };
                        }
                    }
                    return .{ .span = .{ .first = try checker.cue_of(index), .count = 1 } };
                },
                .path => {
                    const path = if (it.tag == .list) try checker.path_of(index, false, param.by_lane) else try checker.named_of(index, .path);
                    if (!param.shaped and !checker.memory.paths[path].shape.eql(Shape.scalar)) {
                        _ = checker.fail(index, .wrong_shape, "`{s}` takes a path of numbers, found one of {s}s", .{ param.name, checker.memory.paths[path].shape.noun()[2..] });
                        return error.Checked;
                    }
                    return .{ .path = path };
                },
                .regions => {
                    if (it.tag == .list) return .{ .regions = try checker.region_list(index, false) };
                    return .{ .regions = try checker.named_of(index, .regions) };
                },
                .number_range => return .{ .number_range = try checker.number_range(index) },
                .time_range => {
                    if (it.tag != .range) {
                        const diagnostic = checker.fail(index, .wrong_type, "`{s}` takes a range of times", .{param.name});
                        error_module.hint(diagnostic, "for example `0s..500ms`", .{});
                        return error.Checked;
                    }
                    const low = try checker.literal_time(it.a);
                    const high = try checker.literal_time(it.b);
                    return .{ .time_range = .{ low, high } };
                },
                .ease => {
                    if (it.tag != .list) return checker.argument(entry, &.{ .name = param.name, .kind = .word, .words = param.words }, index);
                    const children = checker.tree.children(index);
                    if (children.len != 4) {
                        const diagnostic = checker.fail(index, .wrong_type, "a cubic ease is four numbers, `[x1, y1, x2, y2]`", .{});
                        error_module.hint(diagnostic, "for example `[0.34, 1.56, 0.64, 1]`, or a word such as `in_out`", .{});
                        return error.Checked;
                    }
                    var points: [4]f64 = undefined;
                    for (&points, children) |*point, child| point.* = try checker.fixed_number(child, "a control point");
                    return .{ .cubic = points };
                },
                .word => {
                    const word = if (it.tag == .name) checker.text(index) else "";
                    for (param.words, 0..) |candidate, at| {
                        if (std.mem.eql(u8, candidate, word)) return .{ .word = @intCast(at) };
                    }
                    const diagnostic = checker.fail(index, .unknown_word, "`{s}` takes one of its words", .{param.name});
                    if (error_module.nearest(word, param.words)) |near| {
                        error_module.hint(diagnostic, "did you mean `{s}`?", .{near});
                    } else {
                        hint_words(diagnostic, param.words);
                    }
                    return error.Checked;
                },
                .mover => return .{ .mover = try checker.mover_of(index, param.name) },
                .string => {
                    if (it.tag != .literal or checker.tree.tokens[it.token].tag != .string) {
                        const diagnostic = checker.fail(index, .wrong_type, "`{s}` takes a string", .{param.name});
                        error_module.hint(diagnostic, "write it in double quotes, such as `\"text\"`", .{});
                        return error.Checked;
                    }
                    return .{ .string = token_module.string_of(checker.tree.tokens[it.token], checker.source()) };
                },
                .noun => {
                    if (it.tag != .name) {
                        const diagnostic = checker.fail(index, .wrong_type, "`{s}` takes the name of a noun", .{param.name});
                        error_module.hint(diagnostic, "declare it on a line above, then name it here", .{});
                        return error.Checked;
                    }
                    const name = checker.text(index);
                    const found = try checker.resolve(index, name);
                    const binding = checker.memory.bindings[found];
                    if (binding.kind != .noun) {
                        _ = checker.fail(index, .wrong_type, "`{s}` is a {s}, and `{s}` takes a noun", .{ name, kind_name(binding.kind), param.name });
                        return error.Checked;
                    }
                    if (param.words.len == 0) return .{ .noun = found };
                    for (param.words) |word| {
                        if (std.mem.eql(u8, word, binding.entry.?.name)) return .{ .noun = found };
                    }
                    const diagnostic = checker.fail(index, .wrong_type, "`{s}` is `{s}`, which `{s}` does not take", .{ name, binding.entry.?.name, param.name });
                    hint_words(diagnostic, param.words);
                    return error.Checked;
                },
                .seed => {
                    const token = checker.tree.tokens[it.token];
                    if (it.tag != .literal or token.tag != .number or it.a == 1) {
                        _ = checker.fail(index, .out_of_range, "a seed is a whole number from 0 to 2^64 - 1", .{});
                        return error.Checked;
                    }
                    const seed = std.fmt.parseInt(u64, checker.text(index), 10) catch {
                        _ = checker.fail(index, .out_of_range, "a seed is a whole number from 0 to 2^64 - 1", .{});
                        return error.Checked;
                    };
                    checker.memory.frames[checker.frame].seeded += 1;
                    return .{ .seed = seed };
                },
            }
        }

        fn not_live(checker: *Checker, entry: *const Entry, param: *const schema.Param, index: u32) Fail {
            if (checker.item(index).tag == .name) {
                if (checker.find(checker.text(index))) |found| {
                    if (checker.memory.bindings[found].kind == .failed) return checker.reported();
                }
            }
            const diagnostic = checker.fail(index, .not_live, "{s}'s `{s}` is fixed when it is built, so a signal cannot set it", .{ entry.name, param.name });
            if (entry.fixed_hint.len > 0) {
                error_module.hint(diagnostic, "{s}", .{entry.fixed_hint});
            } else {
                error_module.hint(diagnostic, "write {s}", .{example_of(checker, param)});
            }
            return error.Checked;
        }

        fn named_of(checker: *Checker, index: u32, kind: Binding.Kind) Fail!u32 {
            const it = checker.item(index);
            if (it.tag != .name) {
                _ = checker.fail(index, .wrong_type, "expected {s}, found {s}", .{ kind_name(kind), item_kind(it.tag) });
                return error.Checked;
            }
            const name = checker.text(index);
            const found = try checker.resolve(index, name);
            const binding = checker.memory.bindings[found];
            if (binding.kind != kind) {
                _ = checker.fail(index, .wrong_type, "`{s}` is a {s}, not {s}", .{ name, kind_name(binding.kind), kind_name(kind) });
                return error.Checked;
            }
            return binding.index;
        }

        /// A cue: a cue's name, or an element of a series.
        fn cue_of(checker: *Checker, index: u32) Fail!u32 {
            const found = try checker.cue_ref(index, .refused);
            assert(!found.by_lane);
            return found.index;
        }

        /// A cue as `cue_of` reads it, or, where `place` takes it, `series[lane]` inside a region:
        /// the series' first cue, which lane g of the region reads g cues after (section 9a).
        fn cue_ref(checker: *Checker, index: u32, place: LanePlace) Fail!CueRef {
            if (checker.bound(index)) |arg| {
                const saved = checker.frame;
                checker.focus(arg.frame);
                defer checker.focus(saved);
                return checker.cue_ref(arg.item, place);
            }
            const it = checker.item(index);
            if (it.tag == .element) {
                const base = checker.item(it.a);
                const name = checker.text(it.a);
                const found = if (base.tag == .name) checker.find(name) else null;
                const binding = if (found) |at| checker.memory.bindings[at] else {
                    if (base.tag == .name) return checker.unknown_name(it.a, name);
                    _ = checker.fail(index, .wrong_type, "only a series has elements", .{});
                    return error.Checked;
                };
                if (binding.kind == .failed) return checker.reported();
                if (binding.kind != .series) {
                    _ = checker.fail(index, .wrong_type, "`{s}` is a {s}, not a series", .{ name, kind_name(binding.kind) });
                    return error.Checked;
                }
                if (checker.tree.tokens[it.token].tag == .name) return checker.lane_element(index, name, binding, place);
                const element = std.fmt.parseInt(u32, checker.text(index), 10) catch binding.count;
                if (element >= binding.count) {
                    _ = checker.fail(index, .out_of_range, "`{s}` has {d} cues, from [0] to [{d}]", .{ name, binding.count, binding.count - 1 });
                    return error.Checked;
                }
                return .{ .index = binding.index + element };
            }
            if (it.tag != .name) {
                const diagnostic = checker.fail(index, .wrong_type, "expected a cue, found {s}", .{item_kind(it.tag)});
                error_module.hint(diagnostic, "a cue is a name declared with `cue`", .{});
                return error.Checked;
            }
            const name = checker.text(index);
            const found = try checker.resolve(index, name);
            const binding = checker.memory.bindings[found];
            if (binding.kind != .cue) {
                const diagnostic = checker.fail(index, .wrong_type, "`{s}` is a {s}, not a cue", .{ name, kind_name(binding.kind) });
                if (binding.kind == .series) error_module.hint(diagnostic, "name one of its cues, such as `{s}[0]`", .{name});
                return error.Checked;
            }
            return .{ .index = binding.index };
        }

        /// The hint for a cue by lane where none is taken: every `by_lane` parameter of the
        /// vocabulary's entries and then the client's, in order, as far as `buffer` holds them.
        fn by_lane_list(checker: *const Checker, buffer: *[hint_list_size]u8) []const u8 {
            var total: u32 = 0;
            _ = checker;
            for (entries) |entry| {
                for (entry.params) |param| total += @intFromBool(param.by_lane);
            }
            var stream = std.Io.Writer.fixed(buffer);
            stream.writeAll("a cue by lane is taken by ") catch return stream.buffered();
            var count: u32 = 0;
            for (entries) |entry| {
                for (entry.params) |param| {
                    if (!param.by_lane) continue;
                    count += 1;
                    const joiner: []const u8 = if (count == 1) "" else if (count == total) ", or " else ", ";
                    stream.print("{s}`{s}`'s `{s}:`", .{ joiner, entry.name, param.name }) catch return stream.buffered();
                }
            }
            return stream.buffered();
        }

        /// `series[NAME]` (step 28): only `lane`, only where the parameter takes a cue by lane,
        /// only inside a region, and only of a series with a cue for every lane.
        fn lane_element(checker: *Checker, index: u32, name: []const u8, binding: Binding, place: LanePlace) Fail!CueRef {
            const it = checker.item(index);
            const lane_name = checker.tree.token_text(it.token);
            if (!std.mem.eql(u8, lane_name, "lane")) {
                const diagnostic = checker.fail(index, .wrong_type, "`{s}` is not an index", .{lane_name});
                error_module.hint(diagnostic, "an index is a whole number, or `lane` inside a region", .{});
                return error.Checked;
            }
            switch (place) {
                .taken => {},
                .refused => {
                    const diagnostic = checker.fail(index, .wrong_lanes, "`{s}[lane]` is a cue for each lane, which this place does not take", .{name});
                    var buffer: [hint_list_size]u8 = undefined;
                    error_module.hint(diagnostic, "{s}", .{checker.by_lane_list(&buffer)});
                    return error.Checked;
                },
                .path_of_goals => {
                    const diagnostic = checker.fail(index, .wrong_lanes, "`{s}[lane]` is a cue for each lane, and a path by lane has one goal", .{name});
                    error_module.hint(diagnostic, "write one goal, `[{s}[lane]: 1]`, or give every lane the same path, moved by `stagger:`", .{name});
                    return error.Checked;
                },
                .declared_path => {
                    const diagnostic = checker.fail(index, .wrong_lanes, "`{s}[lane]` is a cue for each lane, and a declared path is outside any region", .{name});
                    error_module.hint(diagnostic, "write the path in the call, as `[{s}[lane]: 1]`, inside `lanes(n, …)`", .{name});
                    return error.Checked;
                },
            }
            const count = checker.region orelse {
                const diagnostic = checker.fail(index, .wrong_lanes, "`{s}[lane]` is a cue for each lane, so it is used inside `lanes(n, …)`", .{name});
                error_module.hint(diagnostic, "wrap the call in a region, such as `lanes({d}, …)`", .{binding.count});
                return error.Checked;
            };
            if (binding.count < count) {
                const diagnostic = checker.fail(index, .wrong_lanes, "`{s}` has {d} cues and the region {d} lanes", .{ name, binding.count, count });
                error_module.hint(diagnostic, "give the series a cue for every lane, or the region fewer lanes", .{});
                return error.Checked;
            }
            return .{ .index = binding.index, .by_lane = true };
        }

        /// A path written as a list, declared or inline. Where `by_lane` allows it, its goal's cue
        /// may be `series[lane]`, when it is the path's only goal (section 9a).
        fn path_of(checker: *Checker, index: u32, declared: bool, by_lane: bool) Fail!u32 {
            if (declared) assert(!by_lane);
            const children = checker.tree.children(index);
            if (children.len == 0) {
                _ = checker.fail(index, .wrong_type, "a path has at least one goal", .{});
                return error.Checked;
            }
            if (children.len > run_max) return checker.fixed_limit(index, "goals in one path", run_max);
            var buffer: [run_max]Goal = undefined;
            var values: [run_max][4]f64 = undefined;
            const fresh = buffer[0..children.len];
            var shape: ?Shape = null;
            const place: LanePlace = if (declared) .declared_path else if (!by_lane) .refused else if (children.len > 1) .path_of_goals else .taken;
            for (children, fresh, 0..) |child, *goal, at| {
                const it = checker.item(child);
                if (it.tag != .goal) {
                    const diagnostic = checker.fail(child, .wrong_type, "a path's items are goals", .{});
                    error_module.hint(diagnostic, "a goal is a cue and a value, such as `c1: 1`", .{});
                    return error.Checked;
                }
                const cue = try checker.cue_ref(it.a, place);
                if (cue.by_lane) assert(place == .taken);
                const cue_index = cue.index;
                var goal_shape = Shape.scalar;
                if (try checker.constant_vector(it.b)) |vector| {
                    values[at] = vector.values;
                    goal_shape = vector.shape;
                } else {
                    values[at][0] = try checker.fixed_number(it.b, "a goal's value");
                }
                if (shape) |first| if (!first.eql(goal_shape)) {
                    _ = checker.fail(it.b, .wrong_shape, "this goal is {s}, and the path's first goal {s}", .{ goal_shape.noun(), first.noun() });
                    return error.Checked;
                };
                shape = goal_shape;
                if (at > 0 and cue_index <= fresh[at - 1].cue) {
                    const diagnostic = checker.fail(child, .cue_out_of_order, "a path's goals are in cue order, each at a later cue", .{});
                    error_module.hint(diagnostic, "move this goal before the goals at later cues", .{});
                    return error.Checked;
                }
                goal.* = .{ .cue = cue_index, .value = values[at][0], .cue_by_lane = cue.by_lane };
            }
            const path_shape = shape.?;
            if (path_shape.components > 1) return checker.vector_path(index, fresh, values[0..fresh.len], path_shape, declared);
            if (!declared) {
                for (checker.memory.paths[0..checker.path_count], 0..) |run, at| {
                    // A vector path's first run holds its shape, so it is never a path of numbers.
                    if (!run.shape.eql(Shape.scalar)) continue;
                    if (same_goals(checker.memory.goals[run.first..][0..run.count], fresh)) return @intCast(at);
                }
            }
            if (fresh.len > checker.memory.goals.len - checker.goal_count) {
                return checker.limit(index, "goals", .goals, checker.memory.goals.len);
            }
            if (checker.path_count == checker.memory.paths.len) return checker.limit(index, "paths", .goals, checker.memory.paths.len);
            const first = checker.goal_count;
            @memcpy(checker.memory.goals[first..][0..fresh.len], fresh);
            checker.goal_count += @intCast(fresh.len);
            const at = checker.path_count;
            checker.memory.paths[at] = .{ .first = first, .count = @intCast(fresh.len), .declared = declared };
            checker.path_count += 1;
            return at;
        }

        fn region_list(checker: *Checker, index: u32, declared: bool) Fail!u32 {
            const children = checker.tree.children(index);
            if (children.len == 0) {
                _ = checker.fail(index, .wrong_type, "regions are at least one range", .{});
                return error.Checked;
            }
            if (children.len > run_max) return checker.fixed_limit(index, "regions in one list", run_max);
            var buffer: [run_max]Region = undefined;
            const fresh = buffer[0..children.len];
            for (children, fresh) |child, *region| {
                const range = try checker.number_range(child);
                region.* = .{ .low = range[0], .high = range[1] };
            }
            if (!declared) {
                for (checker.memory.region_runs[0..checker.run_count], 0..) |run, at| {
                    if (same_regions(checker.memory.regions[run.first..][0..run.count], fresh)) return @intCast(at);
                }
            }
            if (fresh.len > checker.memory.regions.len - checker.region_count) {
                return checker.limit(index, "regions", .regions, checker.memory.regions.len);
            }
            if (checker.run_count == checker.memory.region_runs.len) {
                return checker.limit(index, "region runs", .regions, checker.memory.region_runs.len);
            }
            const first = checker.region_count;
            @memcpy(checker.memory.regions[first..][0..fresh.len], fresh);
            checker.region_count += @intCast(fresh.len);
            const at = checker.run_count;
            checker.memory.region_runs[at] = .{ .first = first, .count = @intCast(fresh.len), .declared = declared };
            checker.run_count += 1;
            return at;
        }

        fn number_range(checker: *Checker, index: u32) Fail![2]f64 {
            if (checker.bound(index)) |arg| {
                const saved = checker.frame;
                checker.focus(arg.frame);
                defer checker.focus(saved);
                return checker.number_range(arg.item);
            }
            const it = checker.item(index);
            if (it.tag != .range) {
                const diagnostic = checker.fail(index, .wrong_type, "expected a range, found {s}", .{item_kind(it.tag)});
                error_module.hint(diagnostic, "for example `0..1`", .{});
                return error.Checked;
            }
            const low = try checker.fixed_number(it.a, "a range's end");
            const high = try checker.fixed_number(it.b, "a range's end");
            return .{ low, high };
        }

        /// The number at `index` where one fixed when the program is built is due (section 3b): a
        /// literal, `pi`, `tau`, or their arithmetic, folded; anything else is refused as `what`.
        fn fixed_number(checker: *Checker, index: u32, what: []const u8) Fail!f64 {
            assert(index < checker.tree.items.len);
            assert(what.len > 0);
            if (checker.bound(index)) |arg| {
                const saved = checker.frame;
                checker.focus(arg.frame);
                defer checker.focus(saved);
                return checker.fixed_number(arg.item, what);
            }
            if (checker.folds(index)) return checker.fold(index);
            const it = checker.item(index);
            const token = checker.tree.tokens[it.token];
            if (it.tag == .name) {
                // A track or a signal changes after the build, and this number cannot, as
                // `not_live` says.
                if (checker.find(checker.text(index))) |found| switch (checker.memory.bindings[found].kind) {
                    .track, .signal => {
                        const diagnostic = checker.fail(index, .not_live, "{s} is fixed when it is built, so `{s}` cannot set it", .{ what, checker.text(index) });
                        error_module.hint(diagnostic, "write a number; to move it, map the output instead", .{});
                        return error.Checked;
                    },
                    .failed => return checker.reported(),
                    else => {},
                };
            }
            assert(!(it.tag == .literal and token.tag == .number));
            const diagnostic = checker.fail(index, .wrong_type, "expected {s}, found {s}", .{ what, if (it.tag == .literal) literal_kind(token.tag) else item_kind(it.tag) });
            if (it.tag == .literal and token.tag != .string) error_module.hint(diagnostic, "drop the unit", .{});
            return error.Checked;
        }

        /// Whether `index` folds to a number (section 3b): number literals, `pi` and `tau` where no
        /// name shadows them, parentheses, unary minus, and `+ - * /`, through bound parameters. It
        /// reports nothing, so a caller that finds no fold gives the message it always gave.
        fn folds(checker: *Checker, index: u32) bool {
            assert(index < checker.tree.items.len);
            assert(checker.frame < checker.frame_count);
            if (checker.bound(index)) |arg| {
                const saved = checker.frame;
                checker.focus(arg.frame);
                defer checker.focus(saved);
                return checker.folds(arg.item);
            }
            const it = checker.item(index);
            return switch (it.tag) {
                .literal => checker.tree.tokens[it.token].tag == .number,
                .name => checker.known_number(index) != null,
                .paren, .negate => checker.folds(it.a),
                .add, .subtract, .multiply, .divide => checker.folds(it.a) and checker.folds(it.b),
                else => false,
            };
        }

        /// The number `index` folds to, which `folds` has said it does (section 3b). A divisor of 0
        /// and a result that is not finite are refused here.
        fn fold(checker: *Checker, index: u32) Fail!f64 {
            assert(index < checker.tree.items.len);
            assert(checker.frame < checker.frame_count);
            if (checker.bound(index)) |arg| {
                const saved = checker.frame;
                checker.focus(arg.frame);
                defer checker.focus(saved);
                return checker.fold(arg.item);
            }
            const it = checker.item(index);
            const number: f64 = switch (it.tag) {
                .literal => literal: {
                    assert(checker.tree.tokens[it.token].tag == .number);
                    const digits_text = checker.text(index);
                    const digits = parse_float(digits_text) orelse return checker.bad_number(index);
                    break :literal if (it.a == 1) -digits else digits;
                },
                .name => checker.known_number(index).?,
                .paren => try checker.fold(it.a),
                .negate => -(try checker.fold(it.a)),
                .add, .subtract, .multiply => operands: {
                    const a = try checker.fold(it.a);
                    const b = try checker.fold(it.b);
                    break :operands arithmetic(it.tag, a, b);
                },
                .divide => divide: {
                    const a = try checker.fold(it.a);
                    const by = try checker.nonzero_divisor(it.b, try checker.fold(it.b));
                    break :divide arithmetic(.divide, a, by);
                },
                else => unreachable,
            };
            if (!std.math.isFinite(number)) {
                const span = checker.span_of(index);
                const written = checker.located(index).tree.source[span[0]..][0..span[1]];
                const diagnostic = checker.fail(index, .out_of_range, "`{s}` is past what a number holds", .{written});
                error_module.hint(diagnostic, "a number is finite; keep it within about 1.8e308", .{});
                return error.Checked;
            }
            return number;
        }

        /// The value of `pi` or `tau` at `index`, a name, unless a parameter or a declaration of
        /// the file takes the name there (section 3b).
        fn known_number(checker: *const Checker, index: u32) ?f64 {
            const it = checker.item(index);
            assert(it.tag == .name);
            const name = checker.text(index);
            const number = schema.number_named(name) orelse return null;
            if (checker.bound_slot(index) != null) return null;
            // A module's body never sees the file's names (section 6), so only a parameter shadows.
            if (checker.in_module()) return number;
            if (checker.find(name) != null) return null;
            if (declares_name(checker.root, name)) return null;
            assert(std.math.isFinite(number));
            return number;
        }

        fn bad_number(checker: *Checker, index: u32) Fail {
            _ = checker.fail(index, .out_of_range, "the number `{s}` is not finite", .{checker.text(index)});
            return error.Checked;
        }

        /// A time literal in whole flicks (section 4).
        fn literal_time(checker: *Checker, index: u32) Fail!i64 {
            if (checker.bound(index)) |arg| {
                const saved = checker.frame;
                checker.focus(arg.frame);
                defer checker.focus(saved);
                return checker.literal_time(arg.item);
            }
            const it = checker.item(index);
            const token = if (it.tag == .literal) checker.tree.tokens[it.token] else null;
            if (token == null or token.?.tag != .time) {
                const diagnostic = checker.fail(index, .wrong_type, "expected a time, found {s}", .{if (token) |t| literal_kind(t.tag) else item_kind(it.tag)});
                if (token != null and token.?.tag == .number) {
                    error_module.hint(diagnostic, "a time needs a unit: `{s}s`?", .{checker.text(index)});
                } else {
                    error_module.hint(diagnostic, "for example `0.5s` or `500ms`", .{});
                }
                return error.Checked;
            }
            // The one reader of a time literal, the public one (section 4). A time token is digits,
            // a fraction, an exponent, and `s` or `ms`, so it is never `not_time`.
            const result = read_time(token.?.text(checker.source()));
            switch (result) {
                .flicks => |flicks| return if (it.a == 1) -flicks else flicks,
                .not_time => unreachable,
                .exponent => {
                    const diagnostic = checker.fail(index, .wrong_type, "a time is written without an exponent", .{});
                    error_module.hint(diagnostic, "write its digits, such as `0.001s` or `1ms`", .{});
                },
                .too_large => _ = checker.fail(index, .out_of_range, "the time `{s}` does not fit in flicks", .{checker.text(index)}),
                .not_whole => |nearest_flicks| {
                    const diagnostic = checker.fail(index, .not_whole_flicks, "`{s}` is not a whole number of flicks", .{checker.text(index)});
                    error_module.hint(diagnostic, "the nearest is {d} flicks; seconds are exact to 5 places, ms to 2", .{nearest_flicks});
                },
            }
            return error.Checked;
        }
    };
}

/// How many different names a list of entries has: a name in two roles counts once.
fn distinct_names(comptime list: []const Entry) u32 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var count: u32 = 0;
        for (list, 0..) |entry, at| {
            var seen = false;
            for (list[0..at]) |earlier| seen = seen or std.mem.eql(u8, earlier.name, entry.name);
            count += @intFromBool(!seen);
        }
        return count;
    }
}

fn bits(value: f64) u64 {
    return @bitCast(value);
}

/// Whether two paths hold the same goals, bit for bit, so `-0` never shares with `0`, and
/// `[s[lane]: 1]` never shares with `[s[0]: 1]`.
fn same_goals(a: []const Goal, b: []const Goal) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.cue != y.cue) return false;
        if (bits(x.value) != bits(y.value)) return false;
        if (x.cue_by_lane != y.cue_by_lane) return false;
    }
    return true;
}

/// The most words a hint lists before it ends in an ellipsis (section 6a).
pub const words_hinted_max = 6;

/// The hint "it takes `a`, `b`, or `c`": every one of `words` up to `words_hinted_max`, then the
/// first `words_hinted_max` and an ellipsis (section 6a).
fn hint_words(diagnostic: ?*error_module.Diagnostic, words: []const []const u8) void {
    assert(words.len > 0);
    var text: [2 * error_module.hint_len_max]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&text);
    // Twice the hint, so a list too long for it is cut by `hint` itself, with its `...`.
    write_words(&writer, words) catch {};
    error_module.hint(diagnostic, "{s}", .{writer.buffered()});
}

fn write_words(writer: *std.Io.Writer, words: []const []const u8) std.Io.Writer.Error!void {
    assert(words.len > 0);
    const shown = @min(words.len, words_hinted_max);
    const cut = words.len > words_hinted_max;
    try writer.writeAll("it takes ");
    for (words[0..shown], 0..) |word, at| {
        if (at > 0 and shown > 2) try writer.writeAll(",");
        if (at > 0) try writer.writeAll(" ");
        if (at > 0 and at == shown - 1 and !cut) try writer.writeAll("or ");
        try writer.print("`{s}`", .{word});
    }
    if (cut) try writer.writeAll(", …");
}

/// Whether two lists of regions are the same, bit for bit.
fn same_regions(a: []const Region, b: []const Region) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (bits(x.low) != bits(y.low) or bits(x.high) != bits(y.high)) return false;
    return true;
}

/// A time literal's unit (section 4).
pub const TimeUnit = enum {
    s,
    ms,

    /// The flicks in one of the unit.
    pub fn flicks(unit: TimeUnit) u128 {
        return switch (unit) {
            .s => flicks_per_second,
            .ms => @divExact(flicks_per_second, 1000),
        };
    }
};

/// What `read_time` makes of a time literal's text (section 4).
pub const TimeRead = union(enum) {
    /// The literal's flicks, exactly.
    flicks: i64,
    /// Not a whole number of flicks: the nearest whole flick.
    not_whole: i64,
    /// Written with an exponent, such as `1e3ms`, which a time never is.
    exponent,
    /// Past what an `i64` of flicks holds, or more places than `time_places_max`.
    too_large,
    /// Not a time literal's text: no unit, a sign, a space, or any other byte.
    not_time,
};

/// The most decimal places a time literal is read with, and written with (section 4).
pub const time_places_max = 18;
/// The longest text `write_time` writes: 14 whole digits of milliseconds, a point, 6 places,
/// and `ms`, for the largest `i64` of flicks; 22 in seconds.
pub const time_text_max = 24;

/// The flicks of a time literal's text, `6500ms` or `2.08ms`, as the checker reads it (section
/// 4): the token's text, digits and unit, with no sign, since a minus before a literal is the
/// parser's. The checker's own literals are read by this function.
pub fn read_time(text: []const u8) TimeRead {
    assert(text.len <= std.math.maxInt(u32));
    const unit: TimeUnit = if (std.mem.endsWith(u8, text, "ms"))
        .ms
    else if (std.mem.endsWith(u8, text, "s"))
        .s
    else
        return .not_time;
    const digits = text[0 .. text.len - @tagName(unit).len];
    switch (number_shape(digits)) {
        .plain => {},
        .exponent => return .exponent,
        .none => return .not_time,
    }
    const result = time_flicks(digits, unit.flicks());
    if (result == .flicks) assert(result.flicks >= 0);
    return result;
}

/// The shortest time literal in `unit` that `read_time` reads back as exactly `flicks`, into
/// `out` (section 4): the fewest decimal places that hold it, so no zero ends a fraction. Null
/// for a negative time, whose minus is the parser's, and for one no literal in `unit` holds
/// exactly, such as 1 flick.
pub fn write_time(out: *[time_text_max]u8, flicks: i64, unit: TimeUnit) ?[]const u8 {
    if (flicks < 0) return null;
    const unit_flicks = unit.flicks();
    const value: u128 = @intCast(flicks);
    var places: u32 = 0;
    var scale: u128 = 1;
    // Bounded by `time_places_max`: 10^18 times the largest i64 still fits a u128.
    while (value * scale % unit_flicks != 0) {
        if (places == time_places_max) return null;
        places += 1;
        scale *= 10;
    }
    const mantissa = value * scale / unit_flicks;
    const fraction = mantissa % scale;
    if (places > 0) assert(fraction % 10 != 0);
    var writer: std.Io.Writer = .fixed(out);
    writer.print("{d}", .{mantissa / scale}) catch return null;
    if (places > 0) writer.print(".{d:0>[1]}", .{ fraction, places }) catch return null;
    writer.writeAll(@tagName(unit)) catch return null;
    const text = writer.buffered();
    // The inverse, checked: a literal the reader would refuse is not written.
    const back = read_time(text);
    if (back != .flicks) return null;
    if (back.flicks != flicks) return null;
    return text;
}

/// Digits such as `2.5` in units of `unit_flicks`, exactly (section 4). `read_time` has checked
/// the digits' shape.
fn time_flicks(digits: []const u8, unit_flicks: u128) TimeRead {
    assert(number_shape(digits) == .plain);
    assert(unit_flicks > 0);
    var mantissa: u128 = 0;
    var places: u32 = 0;
    var fraction = false;
    for (digits) |byte| {
        if (byte == '.') {
            fraction = true;
            continue;
        }
        assert(std.ascii.isDigit(byte));
        if (mantissa > std.math.maxInt(u64)) return .too_large;
        mantissa = mantissa * 10 + (byte - '0');
        if (fraction) places += 1;
        if (places > time_places_max) return .too_large;
    }
    const scale = std.math.powi(u128, 10, places) catch return .too_large;
    const numerator = mantissa * unit_flicks;
    const whole = numerator / scale;
    if (whole > std.math.maxInt(i64)) return .too_large;
    if (numerator % scale == 0) return .{ .flicks = @intCast(whole) };
    const rounded = (numerator + scale / 2) / scale;
    return .{ .not_whole = @intCast(@min(rounded, std.math.maxInt(i64))) };
}

/// The shape of a literal's digits, its unit cut off: `plain` for digits with an optional point
/// and fraction, `2.5`; `exponent` for those followed by an exponent, `1e3`, `2.5E-2`; `none`
/// for anything else. A number token's text is always `plain` or `exponent` (`token.zig`).
const DigitShape = enum { plain, exponent, none };

fn number_shape(digits: []const u8) DigitShape {
    var at: usize = digit_run(digits, 0);
    if (at == 0) return .none;
    if (at < digits.len and digits[at] == '.') {
        const end = digit_run(digits, at + 1);
        if (end == at + 1) return .none;
        at = end;
    }
    if (at == digits.len) return .plain;
    if (digits[at] != 'e' and digits[at] != 'E') return .none;
    at += 1;
    if (at < digits.len and (digits[at] == '+' or digits[at] == '-')) at += 1;
    const end = digit_run(digits, at);
    if (end == at or end != digits.len) return .none;
    return .exponent;
}

/// The index after the run of digits from `from`.
fn digit_run(bytes: []const u8, from: usize) usize {
    assert(from <= bytes.len);
    var at = from;
    while (at < bytes.len and std.ascii.isDigit(bytes[at])) at += 1;
    return at;
}

fn parse_float(digits: []const u8) ?f64 {
    const number = std.fmt.parseFloat(f64, digits) catch return null;
    if (!std.math.isFinite(number)) return null;
    return number;
}

fn literal_kind(tag: token_module.Tag) []const u8 {
    return switch (tag) {
        .time => "time",
        .frequency => "frequency",
        .string => "string",
        else => "number",
    };
}

fn item_kind(tag: parse_module.Tag) []const u8 {
    return switch (tag) {
        .literal => "a literal",
        .name => "a name",
        .call => "a call",
        .named => "a named argument",
        .list => "a list",
        .goal => "a goal",
        .range => "a range",
        .add, .subtract, .multiply, .divide, .negate, .paren => "arithmetic",
        .output => "an output",
        .element => "a cue of a series",
        else => "a declaration",
    };
}

/// Two numbers folded by `tag`, an operator, in f64 (sections 3 and 3b): the one place both a
/// signal's constants and a number where one is due are combined, so they have the same bits.
/// A divisor has been checked already (`nonzero_divisor`).
fn arithmetic(tag: parse_module.Tag, a: f64, b: f64) f64 {
    if (tag == .divide) assert(b != 0);
    return switch (tag) {
        .add => a + b,
        .subtract => a - b,
        .multiply => a * b,
        .divide => a / b,
        else => unreachable,
    };
}

/// Whether the file `tree` declares `name`, a cue, a series, a track, or a binding, on any line,
/// so the name is its own in the whole file (section 3b).
fn declares_name(tree: *const Tree, name: []const u8) bool {
    assert(name.len > 0);
    for (tree.declarations) |index| {
        const it = tree.item(index);
        switch (it.tag) {
            .cue, .cue_series, .track, .bind => {},
            else => continue,
        }
        if (std.mem.eql(u8, tree.token_text(it.token), name)) return true;
    }
    return false;
}

/// Whether `index` in `tree` folds to a number on its own (section 3b): numbers, `pi`, and
/// `tau` with arithmetic, where neither name is one of `params` nor, when `file` is set, a
/// name the file declares. A module's default passes its parameters, since a default that read
/// a parameter would stand for itself, and no `file`, since a body never sees the file's names;
/// an item of the file's own declarations passes no parameters and `file`, which is `folds` at
/// the file's frame. `depth` bounds the walk as the parser bounds the nesting.
fn folds_alone(tree: *const Tree, index: u32, params: []const u32, file: bool, depth: u32) bool {
    assert(index < tree.items.len);
    assert(depth <= parse_module.depth_max * 2);
    if (depth == parse_module.depth_max * 2) return false;
    const it = tree.item(index);
    switch (it.tag) {
        .literal => return tree.tokens[it.token].tag == .number,
        .name => {
            const name = tree.text(index);
            if (schema.number_named(name) == null) return false;
            for (params) |param| {
                if (std.mem.eql(u8, tree.token_text(tree.item(param).token), name)) return false;
            }
            if (file and declares_name(tree, name)) return false;
            return true;
        },
        .paren, .negate => return folds_alone(tree, it.a, params, file, depth + 1),
        .add, .subtract, .multiply, .divide => {
            if (!folds_alone(tree, it.a, params, file, depth + 1)) return false;
            return folds_alone(tree, it.b, params, file, depth + 1);
        },
        else => return false,
    }
}

/// Bytes of a file's text: `source[start..][0..len]`.
pub const Bytes = struct {
    start: u32,
    len: u32,

    pub fn end(bytes: Bytes) u32 {
        return bytes.start + bytes.len;
    }

    pub fn of(bytes: Bytes, source: []const u8) []const u8 {
        assert(bytes.end() <= source.len);
        return source[bytes.start..][0..bytes.len];
    }
};

/// How a number of a file is written where one fixed when the program is built is due (section
/// 3c), and its bytes, a minus included, from its first token to its last.
pub const NumberForm = struct {
    kind: Kind,
    bytes: Bytes,

    pub const Kind = enum {
        /// A number literal of digits, with an optional point and fraction, and an optional
        /// minus: `1`, `1.00`, `-0.5`. The only kind whose digits are the number's.
        plain,
        /// A number literal with an exponent, `1e3` or `-2.5e-1`.
        exponent,
        /// Arithmetic of numbers, `pi`, or `tau`, which the checker folds: `2 * 0.25`, `tau`,
        /// `(1)`, `-pi`.
        folded,
        /// Anything else, which the checker refuses, so only a file that does not check has it.
        other,
    };

    /// The bytes of a plain literal, the one kind a client may rewrite digit for digit; null
    /// for any other kind.
    pub fn plain(form: NumberForm) ?Bytes {
        return if (form.kind == .plain) form.bytes else null;
    }
};

/// A track's three numbers, `track a = 1 in 0.25..2`, as `number_form` reads them.
pub const TrackForm = struct { value: NumberForm, low: NumberForm, high: NumberForm };

/// How the number at `index` is written (section 3c). `index` is an item of the file's own
/// declarations, outside a module, so `pi` and `tau` are the language's unless the file
/// declares the name. It reads the tree alone, so it answers for a file that does not check.
pub fn number_form(tree: *const Tree, index: u32) NumberForm {
    assert(index < tree.items.len);
    const it = tree.item(index);
    const first = tree.tokens[it.first];
    const last = tree.tokens[it.last];
    assert(last.start + last.len >= first.start);
    const bytes: Bytes = .{ .start = first.start, .len = last.start + last.len - first.start };
    const token = tree.tokens[it.token];
    if (it.tag == .literal and token.tag == .number) {
        const kind: NumberForm.Kind = switch (number_shape(token.text(tree.source))) {
            .plain => .plain,
            .exponent => .exponent,
            // A number token is digits, a fraction, and an exponent (`token.zig`, section 2).
            .none => unreachable,
        };
        return .{ .kind = kind, .bytes = bytes };
    }
    const kind: NumberForm.Kind = if (folds_alone(tree, index, &.{}, true, 0)) .folded else .other;
    return .{ .kind = kind, .bytes = bytes };
}

/// The three numbers of the track declared at `index`, an item of kind `track` (section 3c).
/// Null when its bounds are not a range, `track a = 1 in 2`, which parses and the checker
/// refuses, so only for a file that does not check.
pub fn track_form(tree: *const Tree, index: u32) ?TrackForm {
    const it = tree.item(index);
    assert(it.tag == .track);
    const bounds = tree.item(it.b);
    if (bounds.tag != .range) return null;
    return .{
        .value = number_form(tree, it.a),
        .low = number_form(tree, bounds.a),
        .high = number_form(tree, bounds.b),
    };
}

/// Whether `tree` declares a module called `name`.
fn declares_module(tree: *const Tree, name: []const u8) bool {
    for (tree.declarations) |index| {
        const it = tree.item(index);
        if (it.tag == .module and std.mem.eql(u8, tree.token_text(it.token), name)) return true;
    }
    return false;
}

fn kind_name(kind: Binding.Kind) []const u8 {
    return switch (kind) {
        .cue => "cue",
        .series => "cue series",
        .track => "track",
        .signal => "signal",
        .path => "path",
        .regions => "list of regions",
        .noun => "noun",
        .failed => unreachable,
    };
}

/// Room for a list of `schema.outputs_max` backquoted names and the joining words; a longer one is
/// cut, since a client names its outputs.
const outputs_hint_size = 256;

/// The outputs of `entry` as a hint reads them, for an entry with at least one output beyond the
/// first (so two to `schema.outputs_max` in all; one named output has a hint of its own), in order: `a` and `b`, or `a`, `b`, and `c`, and
/// "the call itself" where the first has no name.
fn outputs_list(entry: *const Entry, buffer: *[outputs_hint_size]u8) []const u8 {
    const named: u32 = @intFromBool(entry.first_output.len > 0);
    const count: u32 = 1 + @as(u32, @intCast(entry.outputs.len));
    assert(count >= 2);
    assert(count <= schema.outputs_max);
    var stream = std.Io.Writer.fixed(buffer);
    for (0..count) |index| {
        const last = index + 1 == count;
        if (index > 0) {
            const joiner: []const u8 = if (count == 2) " and " else if (last) ", and " else ", ";
            stream.writeAll(joiner) catch return stream.buffered();
        }
        if (index == 0 and named == 0) {
            stream.writeAll("the call itself") catch return stream.buffered();
        } else {
            const name = if (index == 0) entry.first_output else entry.outputs[index - 1];
            stream.print("`{s}`", .{name}) catch return stream.buffered();
        }
    }
    return stream.buffered();
}

fn example_of(checker: anytype, param: *const schema.Param) []const u8 {
    return switch (param.kind) {
        .number, .integer => "a number",
        .time => "a time, such as 0.5s",
        .frequency => "a frequency, such as 1hz",
        .signal => "a signal",
        .cue, .cues => "a cue",
        .path => "goals, such as [c1: 1]",
        .regions => "regions, such as [0..1]",
        .number_range => "a range, such as 0..1",
        .time_range => "a range of times, such as 0s..1s",
        .word, .ease => param.words[0],
        .mover => checker.first_example(.mover) orelse "a mover",
        .seed => "a whole number",
        .string => "\"text\"",
        .noun => "the name of a noun",
    };
}

/// Room for what a parameter takes, or what was found, in words.
const need_text_size = 64;

/// The noun of a shape needed: a number, a vec2, a colour, or "a value" where any is taken.
fn need_noun(need: schema.Need) []const u8 {
    if (need.colour) return "a colour";
    return switch (need.components) {
        0 => "a value",
        1 => "a number",
        2 => "a vec2",
        3 => "a vec3",
        else => "a vec4",
    };
}

/// What a parameter takes: "one number", "a vec2", "a colour", "a number in each of many lanes".
fn need_text(need: schema.Need, buffer: *[need_text_size]u8) []const u8 {
    const noun = need_noun(need);
    if (need.lanes == .many) return std.fmt.bufPrint(buffer, "{s} in each of many lanes", .{noun}) catch noun;
    if (need.components == 1 and !need.colour) return "one number";
    return noun;
}

/// What was found: "one number", "a vec2", "a colour", "3 lanes of a vec2".
fn found_text(shape: Shape, lanes: u32, buffer: *[need_text_size]u8) []const u8 {
    if (lanes > 1) return std.fmt.bufPrint(buffer, "{d} lanes of {s}", .{ lanes, shape.noun() }) catch shape.noun();
    if (shape.eql(Shape.scalar)) return "one number";
    return shape.noun();
}

/// Whether `entry` is the kind of entry a hint example is taken from: a fed signal, or a mover.
fn example_wanted(entry: *const Entry, fed: bool) bool {
    return if (fed) entry.fed and entry.role == .signal else entry.role == .mover;
}

/// Room for a hint built from a list of entries' examples or parameters; a longer list is cut
/// where it fits.
const hint_list_size = 256;

/// Checks `tree`, which parsed with no error, into `memory`.
pub fn check(
    comptime vocabulary: schema.Vocabulary,
    comptime clients: []const Entry,
    tree: *const Tree,
    memory: Memory,
    diagnostics: *Diagnostics,
) Checked {
    const Checker = CheckerOf(vocabulary, clients);
    assert(memory.values.len == memory.value_items.len);
    assert(memory.cue_forms.len == memory.cue_times.len);
    var checker: Checker = .{ .tree = tree, .root = tree, .memory = memory, .diagnostics = diagnostics };
    const before = diagnostics.total();
    assert(memory.frames.len >= frames_max);
    memory.frames[0] = .{ .tree = tree };
    checker.register(tree);
    for (tree.declarations) |index| {
        if (checker.stopped) break;
        checker.declaration(index) catch checker.bind_failed(index);
    }
    var start: u32 = 0;
    if (!checker.stopped) {
        if (checker.start_item) |index| {
            const name = tree.text(index);
            const found = checker.find(name);
            if (found != null and memory.bindings[found.?].kind == .cue) {
                start = memory.bindings[found.?].index;
            } else if (found != null and memory.bindings[found.?].kind == .failed) {
                assert(diagnostics.total() > before);
            } else {
                const diagnostic = checker.fail_token(index, .unknown_name, "`{s}` is not a cue", .{name});
                error_module.hint(diagnostic, "the start is a cue declared with `cue`", .{});
            }
        }
        for (memory.bindings[0..checker.binding_count]) |binding| {
            if (!binding.delay or binding.fed) continue;
            const diagnostic = checker.fail_token(binding.item, .delay_not_fed, "the delay `{s}` is never fed", .{binding.name});
            error_module.hint(diagnostic, "add `{s} <- …` below the signal it delays", .{binding.name});
        }
    }
    return .{
        .seed = checker.seed orelse 0,
        .start = start,
        .cue_times = memory.cue_times[0..checker.cue_count],
        .cue_forms = memory.cue_forms[0..checker.cue_count],
        .bindings = memory.bindings[0..checker.binding_count],
        .declarations = memory.declarations[0..checker.declaration_count],
        .calls = memory.calls[0..checker.call_count],
        .values = memory.values[0..checker.value_count],
        .value_items = memory.value_items[0..checker.value_count],
        .exprs = memory.exprs[0..checker.expr_count],
        .goals = memory.goals[0..checker.goal_count],
        .paths = memory.paths[0..checker.path_count],
        .regions = memory.regions[0..checker.region_count],
        .region_runs = memory.region_runs[0..checker.run_count],
        .tracks = memory.tracks[0..checker.track_count],
        .instances = memory.instances[0..checker.instance_count],
        .module_count = checker.module_count,
        .ok = diagnostics.total() == before,
    };
}

const testing = std.testing;

// Locks section 4: exact times to 5 places of seconds and 2 of ms, the nearest otherwise, and
// the reader's refusals: an exponent, no unit, a sign, a bare point.
test "a time literal is a whole number of flicks or refused" {
    try testing.expectEqual(TimeRead{ .flicks = 352_800_000 }, read_time("0.5s"));
    try testing.expectEqual(TimeRead{ .flicks = 7_056 }, read_time("0.00001s"));
    try testing.expectEqual(TimeRead{ .flicks = 7_056 }, read_time("0.01ms"));
    try testing.expectEqual(TimeRead{ .not_whole = 706 }, read_time("0.000001s"));
    try testing.expectEqual(TimeRead{ .flicks = 423_360_000_000 }, read_time("600s"));
    try testing.expectEqual(TimeRead.exponent, read_time("1e3s"));
    try testing.expectEqual(TimeRead.exponent, read_time("2.5E-2ms"));
    const refused = [_][]const u8{
        "1", "-1s", "+1s", "1 s", ".5s", "5.s", "ms", "s", "1hz", "1e3", "1.2.3s",
    };
    for (refused) |text| {
        try testing.expectEqual(TimeRead.not_time, read_time(text));
    }
    try testing.expectEqual(TimeRead.too_large, read_time("99999999999999999999s"));
}
