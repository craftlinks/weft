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
//! names.
//!
//! ## 3. Arithmetic
//! `a + b` and `a * b` are the builder's add and multiply. `a - b` is `a + b * -1`, `-a` is
//! `a * -1`, and `a - 2` is `a + -2`: negation is exact, so each gives the bits of a subtraction.
//! Two constants fold here, in f64, which is the arithmetic their nodes would do.
//!
//! ## 4. Times
//! A time literal is a whole number of flicks, worked out in integers from its digits: seconds
//! are exact to 5 decimal places and milliseconds to 2, since 705,600,000 = 2^9 3^2 5^5 7^2.
//! Anything finer is refused with the nearest whole flick, so a bounce's hits stay exact.
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
//! - A default is a literal, checked in the module's own frame, so a parameter never stands for
//!   itself.
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
//! A client's nouns (step 14) are entries looked up after the table of primitives (`lookup`).
//!
//! ## 8. Shapes
//! Every expression has a shape (step 16): a number, a vec2, a vec3, or a colour, three
//! components in OKLab. `vec2`, `vec3`, and `oklab` pack scalar signals; `srgb` is a colour of
//! numbers, converted at compile time. Arithmetic takes two equal shapes or one scalar, which it
//! broadcasts; a colour and a vector never mix. A parameter takes one value unless the table marks
//! it `shaped`: then `tween`'s ends, a path's goals and a motion's `from` may be a vector or a
//! colour written in numbers (`Vector`), and `chase`'s target, `map`'s input, and a tween's
//! `after` a shaped signal, and the call's shape is theirs. A vector path is one run a component.
//! `.x .y .z` and `.l .a .b` read a component of a name bound to a vector or a colour.
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
const Entry = schema.Entry;
const error_module = @import("error.zig");
const Diagnostics = error_module.List;
const Code = error_module.Code;
const time_module = @import("../core/time.zig");
const noise_module = @import("../core/noise.zig");
const colour_module = @import("../core/colour.zig");

const flicks_per_second = time_module.flicks_per_second;

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
    };
};

pub const Goal = struct { cue: u32, value: f64 };
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

pub const Binding = struct {
    name: []const u8,
    item: u32,
    kind: Kind,
    /// The cue, the series' first cue, the track, the expression, the path, or the regions.
    index: u32,
    /// A series' cue count.
    count: u32 = 0,
    /// The entry of a call bound directly, for its outputs and its goals.
    entry: ?*const Entry = null,
    delay: bool = false,
    fed: bool = false,

    pub const Kind = enum { cue, series, track, signal, path, regions };
};

pub const Declaration = union(enum) {
    signal: struct { binding: u32, expr: u32 },
    feed: struct { binding: u32, expr: u32, item: u32 },
};

pub const Memory = struct {
    bindings: []Binding,
    declarations: []Declaration,
    calls: []Call,
    values: []Value,
    value_items: []u32,
    exprs: []Expr,
    cue_times: []i64,
    goals: []Goal,
    paths: []Run,
    regions: []Region,
    region_runs: []Run,
    tracks: []Track,
    modules: []Module,
    frames: []Frame,
    libraries: []const Library = &.{},
    instances: []Instance = &.{},
    /// A client's nouns, checked after the table of primitives (step 14).
    clients: []const schema.Entry = &.{},
};

pub const Checked = struct {
    seed: u64,
    /// The cue simulated nodes start at.
    start: u32,
    cue_times: []const i64,
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

const reserved = [_][]const u8{ "seed", "start", "cue", "track", "module", "use" };

const Checker = struct {
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
    stopped: bool = false,

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
        return checker.diagnostics.add(code, span[0], @max(span[1], 1), format, args);
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
        return checker.diagnostics.add(code, token.start, @max(token.len, 1), format, args);
    }

    fn limit(checker: *Checker, index: u32, name: []const u8, count: usize) Fail {
        const diagnostic = checker.fail(index, .limit, "the file needs more than {d} {s}", .{ count, name });
        error_module.hint(diagnostic, "raise `Limits.{s}`", .{name});
        checker.stopped = true;
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
            return checker.limit(index, "names", checker.memory.bindings.len);
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
                const time = try checker.literal_time(it.a);
                const cue = try checker.add_cue(index, time);
                _ = try checker.declare(index, .{ .name = name, .item = index, .kind = .cue, .index = cue });
            },
            .cue_series => try checker.cue_series(index),
            .track => {
                const initial = try checker.literal_number(it.a, "a track's initial value");
                const bounds = try checker.number_range(it.b);
                if (!(bounds[0] <= initial and initial <= bounds[1])) {
                    const diagnostic = checker.fail(it.a, .out_of_range, "the initial value {d} is outside the bounds {d}..{d}", .{ initial, bounds[0], bounds[1] });
                    error_module.hint(diagnostic, "a track starts inside its bounds", .{});
                    return error.Checked;
                }
                if (checker.track_count == checker.memory.tracks.len) {
                    return checker.limit(index, "tracks", checker.memory.tracks.len);
                }
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

    fn add_cue(checker: *Checker, index: u32, time: i64) Fail!u32 {
        if (checker.cue_count > 0) {
            const previous = checker.memory.cue_times[checker.cue_count - 1];
            if (time < previous) {
                const diagnostic = checker.fail(index, .cue_out_of_order, "cues are in time order, and this one is before the cue above it", .{});
                error_module.hint(diagnostic, "move it above the cues it comes before", .{});
                return error.Checked;
            }
        }
        if (checker.cue_count == checker.memory.cue_times.len) {
            return checker.limit(index, "cues", checker.memory.cue_times.len);
        }
        const cue = checker.cue_count;
        checker.memory.cue_times[cue] = time;
        checker.cue_count += 1;
        return cue;
    }

    fn cue_series(checker: *Checker, index: u32) Fail!void {
        const it = checker.item(index);
        const from = try checker.literal_time(it.a);
        const to = try checker.literal_time(checker.tree.extra[it.b]);
        const every = try checker.literal_time(checker.tree.extra[it.b + 1]);
        if (every <= 0 or to < from or @rem(to - from, every) != 0) {
            const diagnostic = checker.fail(index, .bad_series, "a series' step must be above 0s and divide its span exactly", .{});
            error_module.hint(diagnostic, "for example `0s..600s every 2s`, which is 301 cues", .{});
            return error.Checked;
        }
        const count_wide = @divExact(to - from, every) + 1;
        if (count_wide > checker.memory.cue_times.len - checker.cue_count) {
            return checker.limit(index, "cues", checker.memory.cue_times.len);
        }
        const count: u32 = @intCast(count_wide);
        const first = try checker.add_cue(index, from);
        for (1..count) |step| _ = try checker.add_cue(index, from + every * @as(i64, @intCast(step)));
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
                const path = try checker.path_of(it.a, true);
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
        checker.declared_last = null;
        const expr = try checker.signal(it.a);
        const declared = checker.declared_last;
        var binding: Binding = .{ .name = name, .item = index, .kind = .signal, .index = expr };
        const node = checker.memory.exprs[expr];
        if (node.tag == .call and node.b == 0) {
            const entry = checker.memory.calls[node.a].entry;
            binding.entry = entry;
            binding.delay = entry.op == .delay;
        }
        const at = try checker.declare(index, binding);
        if (declared) |range| if (value.tag == .call and checker.find_module(checker.text(it.a)) != null) {
            if (checker.instance_count == checker.memory.instances.len) {
                return checker.limit(index, "names", checker.memory.instances.len);
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
            error_module.hint(diagnostic, "declare it above, such as `{s} = delay(0)`", .{name});
            return error.Checked;
        };
        const binding = &checker.memory.bindings[target];
        if (!binding.delay) {
            const diagnostic = checker.fail_token(index, .not_a_delay, "only a delay is fed with `<-`, and `{s}` is not one", .{name});
            error_module.hint(diagnostic, "declare it as `{s} = delay(0)`", .{name});
            return error.Checked;
        }
        if (binding.fed) {
            _ = checker.fail(index, .delay_fed_twice, "the delay `{s}` is already fed", .{name});
            return error.Checked;
        }
        binding.fed = true;
        const expr = try checker.signal(it.a);
        try checker.expect_scalar(it.a, expr, name);
        try checker.push_declaration(index, .{ .feed = .{ .binding = target, .expr = expr, .item = index } });
    }

    fn push_declaration(checker: *Checker, index: u32, declaration_value: Declaration) Fail!void {
        if (checker.declaration_count == checker.memory.declarations.len) {
            return checker.limit(index, "declarations", checker.memory.declarations.len);
        }
        checker.memory.declarations[checker.declaration_count] = declaration_value;
        checker.declaration_count += 1;
    }

    fn push_expr(checker: *Checker, expr: Expr) Fail!u32 {
        if (checker.expr_count == checker.memory.exprs.len) {
            return checker.limit(expr.item, "expressions", checker.memory.exprs.len);
        }
        const at = checker.expr_count;
        var placed = expr;
        placed.item = checker.site_of(expr.item);
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
                return checker.constant(try checker.literal_number(index, "a number"), index);
            },
            .name => return checker.signal_name(index, 0),
            .call => {
                const name = checker.text(index);
                if (checker.lookup(name, .signal)) |entry| {
                    const call = try checker.check_call(entry, index);
                    const shape = try checker.call_shape(call, index);
                    return checker.push_expr(.{ .tag = .call, .a = call, .item = index, .shape = shape });
                }
                if (checker.find_module(name)) |module| return checker.expand_signal(module, index);
                return checker.unknown_call(index);
            },
            .paren => return checker.signal(it.a),
            .add, .multiply => {
                const left = try checker.signal(it.a);
                const right = try checker.signal(it.b);
                if (checker.is_constant(left)) |a| if (checker.is_constant(right)) |b| {
                    return checker.constant(if (it.tag == .add) a + b else a * b, index);
                };
                const tag: Expr.Tag = if (it.tag == .add) .add else .multiply;
                const shape = try checker.combine(index, left, right);
                return checker.push_expr(.{ .tag = tag, .a = left, .b = right, .item = index, .shape = shape });
            },
            .subtract => {
                const left = try checker.signal(it.a);
                const right = try checker.signal(it.b);
                if (checker.is_constant(right)) |b| {
                    if (checker.is_constant(left)) |a| return checker.constant(a - b, index);
                    const negative = try checker.constant(-b, it.b);
                    return checker.push_expr(.{ .tag = .add, .a = left, .b = negative, .item = index, .shape = checker.shape_of(left) });
                }
                const shape = try checker.combine(index, left, right);
                const minus_one = try checker.constant(-1, index);
                const negated = try checker.push_expr(.{ .tag = .multiply, .a = right, .b = minus_one, .item = it.b, .shape = checker.shape_of(right) });
                return checker.push_expr(.{ .tag = .add, .a = left, .b = negated, .item = index, .shape = shape });
            },
            .negate => {
                const operand = try checker.signal(it.a);
                if (checker.is_constant(operand)) |a| return checker.constant(-a, index);
                const minus_one = try checker.constant(-1, index);
                return checker.push_expr(.{ .tag = .multiply, .a = operand, .b = minus_one, .item = index, .shape = checker.shape_of(operand) });
            },
            .output => return checker.output(index, it.a, checker.text(index)),
            .list, .range, .goal, .named, .element => {
                _ = checker.fail(index, .wrong_type, "expected a signal, found {s}", .{item_kind(it.tag)});
                return error.Checked;
            },
            else => unreachable,
        }
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
                const found = checker.find(base_name) orelse return checker.unknown_name(base_index, base_name);
                const bound_to = checker.memory.bindings[found];
                if (bound_to.kind == .signal and checker.shape_of(bound_to.index).components > 1) {
                    return checker.component_of(index, try checker.signal_name(base_index, 0), output_name);
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
            if (base.tag == .call and entry.outputs.len == 0) {
                const vector = try checker.signal(base_index);
                if (checker.shape_of(vector).components > 1) return checker.component_of(index, vector, output_name);
            }
            const diagnostic = checker.fail_token(index, .unknown_output, "{s} has no output `{s}`", .{ entry.name, output_name });
            if (entry.outputs.len > 0) {
                error_module.hint(diagnostic, "its outputs are `position` and `{s}`", .{entry.outputs[0]});
            }
            return error.Checked;
        };
        if (base.tag == .name) return checker.signal_name(base_index, output_slot);
        const call = try checker.check_call(entry, base_index);
        return checker.push_expr(.{ .tag = .call, .a = call, .b = output_slot, .item = index });
    }

    fn signal_name(checker: *Checker, index: u32, output_index: u32) Fail!u32 {
        const name = checker.text(index);
        const found = checker.find(name) orelse return checker.unknown_name(index, name);
        const binding = checker.memory.bindings[found];
        switch (binding.kind) {
            .signal => {
                const shape = if (output_index == 0) checker.shape_of(binding.index) else Shape.scalar;
                return checker.push_expr(.{ .tag = .binding, .a = found, .b = output_index, .item = index, .shape = shape });
            },
            .track => return checker.push_expr(.{ .tag = .track, .a = binding.index, .item = index }),
            else => {
                _ = checker.fail(index, .wrong_type, "`{s}` is a {s}, not a signal", .{ name, kind_name(binding.kind) });
                return error.Checked;
            },
        }
    }

    fn unknown_name(checker: *Checker, index: u32, name: []const u8) Fail {
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
        const diagnostic = checker.fail_token(index, .unknown_call, "there is no call `{s}`", .{name});
        if (error_module.nearest(name, &schema.call_names)) |near| {
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
            return checker.limit(index, "values", checker.memory.values.len);
        }
        if (checker.call_count == checker.memory.calls.len) {
            return checker.limit(index, "calls", checker.memory.calls.len);
        }
        const first = checker.value_count;
        checker.value_count += @intCast(entry.params.len);
        for (entry.params, 0..) |*param, at| {
            const slot = first + at;
            checker.memory.value_items[slot] = checker.site_of(given[at] orelse index);
            checker.memory.values[slot] = if (given[at]) |child|
                try checker.argument(entry, param, child)
            else
                try checker.default_of(entry, param, index);
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
                error_module.hint(diagnostic, "add `{s}: {s}`", .{ param.name, example_of(param) });
                return error.Checked;
            },
            .absent => .absent,
            .number => |number| .{ .number = number },
            .time => |flicks| .{ .time = flicks },
            .word => |word| .{ .word = word },
            .time_range => |range| .{ .time_range = range },
            .unbounded => .{ .number_range = .{ -std.math.inf(f64), std.math.inf(f64) } },
            .seed => .{ .seed = checker.derived_seed() },
            .whole => .absent,
        };
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

    /// The entry called `name` in `role`: a primitive, else one of the client's nouns.
    fn lookup(checker: *const Checker, name: []const u8, role: schema.Role) ?*const Entry {
        if (schema.find(name, role)) |entry| return entry;
        for (checker.memory.clients) |*entry| {
            if (entry.role == role and std.mem.eql(u8, entry.name, name)) return entry;
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
        for (tree.children(tree.item(index).a)) |param| {
            const default = tree.item(param).a;
            if (default == 0 or tree.item(default - 1).tag == .literal) continue;
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
            return checker.limit(report, "modules", checker.memory.modules.len);
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
            .seed_base = noise_module.hash(caller_frame.seed_base, std.hash.Fnv1a_64.hash(found.name) +% ordinal),
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

    /// The error for a module that reaches itself: the modules on the chain of callers, from the
    /// first time it was called, then itself again.
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
    fn mover_of(checker: *Checker, index: u32) Fail!u32 {
        if (checker.bound(index)) |arg| {
            const saved = checker.frame;
            checker.focus(arg.frame);
            defer checker.focus(saved);
            return checker.mover_of(arg.item);
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
                return checker.mover_of(checker.memory.frames[frame].body);
            }
        }
        const diagnostic = checker.fail(index, .wrong_type, "`by` takes a mover", .{});
        error_module.hint(diagnostic, "`spring(time: …)` or `newtonian(speed: …, accel: …, decel: …)`", .{});
        return error.Checked;
    }

    fn shape_of(checker: *const Checker, expr: u32) Shape {
        return checker.memory.exprs[expr].shape;
    }

    /// The shape of `left` and `right` together (section 8): theirs when equal, the other's when
    /// one is a number; a colour and a vector, or two vectors of different sizes, are refused.
    fn combine(checker: *Checker, index: u32, left: u32, right: u32) Fail!Shape {
        const a = checker.shape_of(left);
        const b = checker.shape_of(right);
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

    /// The shape of a call (section 8): what its shaped parameters hold, checked to agree.
    fn call_shape(checker: *Checker, call: u32, index: u32) Fail!Shape {
        const entry = checker.memory.calls[call].entry;
        const values = checker.memory.values[checker.memory.calls[call].values..][0..entry.params.len];
        switch (entry.op) {
            .pack => return .{
                .components = @intCast(entry.params.len),
                .colour = std.mem.eql(u8, entry.name, "oklab"),
            },
            .srgb => return .{ .components = 3, .colour = true },
            .tween => {
                const shape = try checker.agree(index, values[0].shape(), values[1].shape(), "`from` and `to`");
                if (values[5] == .signal) {
                    const after = checker.shape_of(values[5].signal);
                    if (!after.eql(shape)) {
                        _ = checker.fail(index, .wrong_shape, "`after` is {s}, and this tween {s}", .{ after.noun(), shape.noun() });
                        return error.Checked;
                    }
                }
                return shape;
            },
            .spring, .newtonian => {
                const path = checker.memory.paths[values[0].path].shape;
                const from = values[1].shape();
                // A path of numbers is one run, so a `from` with components has nowhere to go.
                if (path.eql(Shape.scalar) and !from.eql(Shape.scalar)) {
                    const diagnostic = checker.fail(index, .wrong_shape, "the goals are numbers, and `from` {s}", .{from.noun()});
                    error_module.hint(diagnostic, "write the goals as {s}s too, or `from` as a number", .{from.noun()[2..]});
                    return error.Checked;
                }
                return checker.agree(index, path, from, "the goals and `from`");
            },
            .chase => return checker.shape_of(values[0].signal),
            .map => return checker.shape_of(values[0].signal),
            else => return Shape.scalar,
        }
    }

    /// Two shapes that must agree, a number broadcast to the other.
    fn agree(checker: *Checker, index: u32, a: Shape, b: Shape, what: []const u8) Fail!Shape {
        if (a.eql(b) or b.eql(Shape.scalar)) return a;
        if (a.eql(Shape.scalar)) return b;
        _ = checker.fail(index, .wrong_shape, "{s} differ: {s} and {s}", .{ what, a.noun(), b.noun() });
        return error.Checked;
    }

    /// A vector or a colour written as numbers (section 8), or null for anything else: a call of
    /// `vec2`, `vec3`, `oklab`, or `srgb` whose arguments are all number literals.
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
        if (entry.op != .pack and entry.op != .srgb) return null;
        const children = checker.tree.children(index);
        if (children.len != entry.params.len) return null;
        for (children) |child| if (checker.item(child).tag != .literal) return null;
        var vector: Vector = .{ .values = @splat(0), .shape = .{
            .components = @intCast(entry.params.len),
            .colour = entry.op == .srgb or std.mem.eql(u8, entry.name, "oklab"),
        } };
        for (children, 0..) |child, at| vector.values[at] = try checker.literal_number(child, "a component");
        if (entry.op == .srgb) {
            for (vector.values[0..3]) |channel| if (!(channel >= 0 and channel <= 1)) {
                const diagnostic = checker.fail(index, .out_of_range, "an sRGB channel is in [0, 1]", .{});
                error_module.hint(diagnostic, "write each of r, g, and b from 0 to 1", .{});
                return error.Checked;
            };
            const lab = colour_module.from_srgb(vector.values[0..3].*);
            vector.values = .{ lab[0], lab[1], lab[2], 0 };
        }
        return vector;
    }

    /// A path of vectors (section 8): one run a component, in order, never shared.
    fn vector_path(checker: *Checker, index: u32, goals: []const Goal, values: []const [4]f64, shape: Shape, declared: bool) Fail!u32 {
        const count = shape.components;
        if (goals.len * count > checker.memory.goals.len - checker.goal_count) {
            return checker.limit(index, "goals", checker.memory.goals.len);
        }
        if (checker.path_count + count > checker.memory.paths.len) return checker.limit(index, "paths", checker.memory.paths.len);
        const first_path = checker.path_count;
        for (0..count) |k| {
            const first = checker.goal_count;
            for (goals, values, 0..) |goal, value, at| {
                checker.memory.goals[first + at] = .{ .cue = goal.cue, .value = value[k] };
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
            return checker.push_expr(.{ .tag = .pick, .a = vector, .b = @intCast(component), .item = index });
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
        return if (ordinal == 0) base else noise_module.hash(base, ordinal);
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
                if (it.tag == .literal) return .{ .number = try checker.literal_number(index, "a number") };
                if (param.shaped) if (try checker.constant_vector(index)) |vector| return .{ .vector = vector };
                if (!param.live) return checker.not_live(entry, param, index);
                const expr = try checker.signal(index);
                try checker.expect_scalar(index, expr, param.name);
                return .{ .signal = expr };
            },
            .integer => {
                const number = try checker.literal_number(index, "a whole number");
                if (!(number >= 0 and number <= 0x1p32 and @floor(number) == number)) {
                    _ = checker.fail(index, .out_of_range, "`{s}` is a whole number from 0 to 2^32", .{param.name});
                    return error.Checked;
                }
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
                return .{ .signal = expr };
            },
            .cue => return .{ .cue = try checker.cue_of(index) },
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
                const path = if (it.tag == .list) try checker.path_of(index, false) else try checker.named_of(index, .path);
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
                for (&points, children) |*point, child| point.* = try checker.literal_number(child, "a control point");
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
                    error_module.hint(diagnostic, "for example `{s}`", .{param.words[0]});
                }
                return error.Checked;
            },
            .mover => return .{ .mover = try checker.mover_of(index) },
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
        const diagnostic = checker.fail(index, .not_live, "{s}'s `{s}` is fixed when it is built, so a signal cannot set it", .{ entry.name, param.name });
        switch (entry.op) {
            .spring, .newtonian => error_module.hint(diagnostic, "chase follows a moving value, and a follower's mover reads signals", .{}),
            else => error_module.hint(diagnostic, "write {s}", .{example_of(param)}),
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
        const found = checker.find(name) orelse return checker.unknown_name(index, name);
        const binding = checker.memory.bindings[found];
        if (binding.kind != kind) {
            _ = checker.fail(index, .wrong_type, "`{s}` is a {s}, not {s}", .{ name, kind_name(binding.kind), kind_name(kind) });
            return error.Checked;
        }
        return binding.index;
    }

    /// A cue: a cue's name, or an element of a series.
    fn cue_of(checker: *Checker, index: u32) Fail!u32 {
        if (checker.bound(index)) |arg| {
            const saved = checker.frame;
            checker.focus(arg.frame);
            defer checker.focus(saved);
            return checker.cue_of(arg.item);
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
            if (binding.kind != .series) {
                _ = checker.fail(index, .wrong_type, "`{s}` is a {s}, not a series", .{ name, kind_name(binding.kind) });
                return error.Checked;
            }
            const element = std.fmt.parseInt(u32, checker.text(index), 10) catch binding.count;
            if (element >= binding.count) {
                _ = checker.fail(index, .out_of_range, "`{s}` has {d} cues, from [0] to [{d}]", .{ name, binding.count, binding.count - 1 });
                return error.Checked;
            }
            return binding.index + element;
        }
        if (it.tag != .name) {
            const diagnostic = checker.fail(index, .wrong_type, "expected a cue, found {s}", .{item_kind(it.tag)});
            error_module.hint(diagnostic, "a cue is a name declared with `cue`", .{});
            return error.Checked;
        }
        const name = checker.text(index);
        const found = checker.find(name) orelse return checker.unknown_name(index, name);
        const binding = checker.memory.bindings[found];
        if (binding.kind != .cue) {
            const diagnostic = checker.fail(index, .wrong_type, "`{s}` is a {s}, not a cue", .{ name, kind_name(binding.kind) });
            if (binding.kind == .series) error_module.hint(diagnostic, "name one of its cues, such as `{s}[0]`", .{name});
            return error.Checked;
        }
        return binding.index;
    }

    fn path_of(checker: *Checker, index: u32, declared: bool) Fail!u32 {
        const children = checker.tree.children(index);
        if (children.len == 0) {
            _ = checker.fail(index, .wrong_type, "a path has at least one goal", .{});
            return error.Checked;
        }
        if (children.len > run_max) return checker.limit(index, "goals in one path", run_max);
        var buffer: [run_max]Goal = undefined;
        var values: [run_max][4]f64 = undefined;
        const fresh = buffer[0..children.len];
        var shape: ?Shape = null;
        for (children, fresh, 0..) |child, *goal, at| {
            const it = checker.item(child);
            if (it.tag != .goal) {
                const diagnostic = checker.fail(child, .wrong_type, "a path's items are goals", .{});
                error_module.hint(diagnostic, "a goal is a cue and a value, such as `c1: 1`", .{});
                return error.Checked;
            }
            const cue_index = try checker.cue_of(it.a);
            var goal_shape = Shape.scalar;
            if (try checker.constant_vector(it.b)) |vector| {
                values[at] = vector.values;
                goal_shape = vector.shape;
            } else {
                values[at][0] = try checker.literal_number(it.b, "a goal's value");
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
            goal.* = .{ .cue = cue_index, .value = values[at][0] };
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
            return checker.limit(index, "goals", checker.memory.goals.len);
        }
        if (checker.path_count == checker.memory.paths.len) return checker.limit(index, "paths", checker.memory.paths.len);
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
        if (children.len > run_max) return checker.limit(index, "regions in one list", run_max);
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
            return checker.limit(index, "regions", checker.memory.regions.len);
        }
        if (checker.run_count == checker.memory.region_runs.len) {
            return checker.limit(index, "region runs", checker.memory.region_runs.len);
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
        const low = try checker.literal_number(it.a, "a range's end");
        const high = try checker.literal_number(it.b, "a range's end");
        return .{ low, high };
    }

    fn literal_number(checker: *Checker, index: u32, what: []const u8) Fail!f64 {
        if (checker.bound(index)) |arg| {
            const saved = checker.frame;
            checker.focus(arg.frame);
            defer checker.focus(saved);
            return checker.literal_number(arg.item, what);
        }
        const it = checker.item(index);
        const token = checker.tree.tokens[it.token];
        if (it.tag != .literal or token.tag != .number) {
            const diagnostic = checker.fail(index, .wrong_type, "expected {s}, found {s}", .{ what, if (it.tag == .literal) literal_kind(token.tag) else item_kind(it.tag) });
            if (it.tag == .literal) error_module.hint(diagnostic, "drop the unit", .{});
            return error.Checked;
        }
        const number = parse_float(checker.text(index)) orelse return checker.bad_number(index);
        return if (it.a == 1) -number else number;
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
        const unit = token_module.unit_of(token.?, checker.source());
        const digits = token_module.digits_of(token.?, checker.source());
        const unit_flicks: u128 = if (unit == .ms) @divExact(flicks_per_second, 1000) else flicks_per_second;
        const result = time_flicks(digits, unit_flicks);
        switch (result) {
            .flicks => |flicks| return if (it.a == 1) -flicks else flicks,
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

fn bits(value: f64) u64 {
    return @bitCast(value);
}

/// Whether two paths hold the same goals, bit for bit, so `-0` never shares with `0`.
fn same_goals(a: []const Goal, b: []const Goal) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x.cue != y.cue or bits(x.value) != bits(y.value)) return false;
    return true;
}

/// Whether two lists of regions are the same, bit for bit.
fn same_regions(a: []const Region, b: []const Region) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (bits(x.low) != bits(y.low) or bits(x.high) != bits(y.high)) return false;
    return true;
}

const TimeResult = union(enum) {
    flicks: i64,
    not_whole: i64,
    exponent,
    too_large,
};

/// Digits such as `2.5` in units of `unit_flicks`, exactly (section 4).
fn time_flicks(digits: []const u8, unit_flicks: u128) TimeResult {
    var mantissa: u128 = 0;
    var places: u32 = 0;
    var fraction = false;
    for (digits) |byte| {
        if (byte == '.') {
            fraction = true;
            continue;
        }
        if (!std.ascii.isDigit(byte)) return .exponent;
        if (mantissa > std.math.maxInt(u64)) return .too_large;
        mantissa = mantissa * 10 + (byte - '0');
        if (fraction) places += 1;
        if (places > 18) return .too_large;
    }
    const scale = std.math.powi(u128, 10, places) catch return .too_large;
    const numerator = mantissa * unit_flicks;
    const whole = numerator / scale;
    if (whole > std.math.maxInt(i64)) return .too_large;
    if (numerator % scale == 0) return .{ .flicks = @intCast(whole) };
    const rounded = (numerator + scale / 2) / scale;
    return .{ .not_whole = @intCast(@min(rounded, std.math.maxInt(i64))) };
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
        .add, .subtract, .multiply, .negate, .paren => "arithmetic",
        .output => "an output",
        .element => "a cue of a series",
        else => "a declaration",
    };
}

fn kind_name(kind: Binding.Kind) []const u8 {
    return switch (kind) {
        .cue => "cue",
        .series => "cue series",
        .track => "track",
        .signal => "signal",
        .path => "path",
        .regions => "list of regions",
    };
}

fn example_of(param: *const schema.Param) []const u8 {
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
        .mover => "spring(time: 0.5s)",
        .seed => "a whole number",
    };
}

/// Checks `tree`, which parsed with no error, into `memory`.
pub fn check(tree: *const Tree, memory: Memory, diagnostics: *Diagnostics) Checked {
    assert(memory.values.len == memory.value_items.len);
    var checker: Checker = .{ .tree = tree, .root = tree, .memory = memory, .diagnostics = diagnostics };
    const before = diagnostics.total();
    assert(memory.frames.len >= frames_max);
    memory.frames[0] = .{ .tree = tree };
    checker.register(tree);
    for (tree.declarations) |index| {
        if (checker.stopped) break;
        checker.declaration(index) catch {};
    }
    var start: u32 = 0;
    if (!checker.stopped) {
        if (checker.start_item) |index| {
            const name = tree.text(index);
            const found = checker.find(name);
            if (found != null and memory.bindings[found.?].kind == .cue) {
                start = memory.bindings[found.?].index;
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
        .ok = diagnostics.total() == before,
    };
}

const testing = std.testing;

// Locks section 4: exact times to 5 places of seconds and 2 of ms, and the nearest otherwise.
test "a time literal is a whole number of flicks or refused" {
    try testing.expectEqual(TimeResult{ .flicks = 352_800_000 }, time_flicks("0.5", flicks_per_second));
    try testing.expectEqual(TimeResult{ .flicks = 7_056 }, time_flicks("0.00001", flicks_per_second));
    try testing.expectEqual(TimeResult{ .flicks = 7_056 }, time_flicks("0.01", 705_600));
    try testing.expectEqual(TimeResult{ .not_whole = 706 }, time_flicks("0.000001", flicks_per_second));
    try testing.expectEqual(TimeResult{ .flicks = 423_360_000_000 }, time_flicks("600", flicks_per_second));
    try testing.expectEqual(TimeResult.exponent, time_flicks("1e3", flicks_per_second));
}
