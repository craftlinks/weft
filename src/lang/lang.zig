//! The language: a small declarative text that compiles once into a `Program`.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. A Front End
//! Text goes through four stages, each a file with its own guide:
//! ```text
//! token.zig   bytes to tokens: names, literals with their units, punctuation, comments
//! parse.zig   tokens to a flat tree, one declaration a line
//! check.zig   the tree to checked declarations: names, order, types, defaults, seeds,
//!             each call checked against the table of primitives in schema.zig
//! graph.zig   checked declarations to a Program, through the Builder
//! ```
//! `format.zig` writes a tree back as canonical text, and `error.zig` holds the diagnostics. The
//! back end runs once, at compile, so text adds nothing to `eval`: the program is the one a
//! hand-written builder call would make, node for node.
//!
//! ## 2. Memory
//! `Compiled(limits)` holds every array the four stages write, at sizes fixed at compile time, and
//! the tables the program reads. The `Program` points at its cue and track tables, so a `Compiled`
//! is built in place and never moves, as Play's `Signals` was. A full array is an error that names
//! its field of `Limits`, never a crash.
//!
//! ## 3. Names for a Client
//! The program stores no names (`graph.zig`, section 5). A client asks the `Compiled` for a
//! signal's node, a track, a cue, or where a signal's goal comes from, by the name the text gave
//! it, once at init.
//!
//! ## 4. Modules and Libraries
//! A module (step 13) is checked where it is used: the checker expands it into the arrays a
//! hand-written graph would fill (`check.zig`, section 6), so the back end and the program never
//! see one. A library is a file of modules a client passes to `compile_with` by name, and a
//! `use` line brings its modules in. The core reads no files: a library is text the client
//! already holds, such as `std_library`, and it is parsed into a `Syntax` of its own, so its
//! items are in its own tree. A module may declare the range its output stays in; that is
//! checked after the build, against the instance's node, for an instance bound to a name.
//!
//! A client's nouns (step 14) join the table of primitives through `compile_client`. The checker
//! accepts them, and the back end refuses them, so the client builds them from `checked`.
//!
//! ## 5. Recompiling and Carry
//! A client that recompiles a running program, as Play's editor does on each edit (step 15),
//! keeps two `Compiled`s and moves its readers from the old to the new. A seekable program needs
//! nothing moved: a fresh reader computes the same values. A simulated one would replay every
//! step from its start, which at 600 s costs tens of milliseconds a reader, so `carry` keeps the
//! old reader's steps and checkpoints when no simulated node changed:
//! - A binding's fingerprint hashes its declaration's tokens (comments and spacing left out),
//!   the fingerprints of the earlier bindings it names, and the seed, the start, the modules, and
//!   the libraries. Two bindings with one name and one fingerprint build the same nodes.
//! - `twins` pairs each node with the node at the same place among its binding's nodes in the
//!   old program; a track's node is skipped, since it is built where it is first read.
//! - `State.adopt` takes the old reader's state only when every simulated node has a twin, so a
//!   changed simulated node, or one whose input changed, starts the whole reader fresh, which is
//!   right: its history is a new one. A file that feeds a delay never carries.
//! - `carry_tracks` writes a track's writes into the new program's track of the same name,
//!   before any reader reads, so a knob's past survives an edit.
//!
//! ## 6. Robustness
//! Any bytes compile to a program or to at least one diagnostic, and never crash: the fuzz test
//! below feeds random bytes and mutated examples through compile and format, and every limit is
//! a diagnostic. A file that parsed formats to canonical text, idempotently.
//!
//! ## 7. TigerStyle Invariants
//! - No allocation: every array is a field, sized by `Limits`.
//! - Compile is bounded: one pass for tokens, one for the tree, one for the checks, and one for
//!   the nodes, each over arrays of fixed size, with expressions nested at most
//!   `parse.depth_max` deep.

const std = @import("std");
const assert = std.debug.assert;
pub const token = @import("token.zig");
pub const parse = @import("parse.zig");
pub const diagnostic = @import("error.zig");
pub const schema = @import("schema.zig");
pub const format = @import("format.zig");
pub const check = @import("check.zig");
pub const back_end = @import("graph.zig");
const graph = @import("../core/graph.zig");
const State = graph.State;
const range_module = @import("../core/range.zig");
const motion = @import("../core/motion.zig");
const simulation = @import("../core/simulation.zig");
const track_module = @import("../core/track.zig");
const time_module = @import("../core/time.zig");
const cue_module = @import("../core/cue.zig");
const Sample = @import("../core/recording.zig").Sample;

pub const Diagnostic = diagnostic.Diagnostic;
pub const GoalSource = back_end.GoalSource;
pub const Ids = back_end.Ids;

pub const Limits = struct {
    /// Tokens, comments and newlines included.
    tokens: u32 = 4096,
    /// Items of the tree, and the checker's calls and expressions.
    tree: u32 = 4096,
    /// Declarations and names.
    names: u32 = 256,
    nodes: u32 = 256,
    /// The f64 of the program's slab.
    slab: u32 = 4096,
    cues: u32 = 512,
    goals: u32 = 256,
    regions: u32 = 64,
    tracks: u32 = 8,
    /// Each track's samples: the writes it can hold.
    track_samples: u32 = 1024,
    /// Modules in the file and its libraries.
    modules: u32 = 32,
    /// Libraries a file may `use`, passed to `compile_with`. None by default, so a client that
    /// never uses one pays for no library's tree.
    libraries: u32 = 0,
    /// Diagnostics kept; more are counted.
    errors: u32 = 16,
};

/// A library's name and its text, for `compile_with`.
pub const Source = struct { name: []const u8, text: []const u8 };

/// Hashes the tags and texts of an item's tokens, comments and newlines left out, so spacing and
/// comments never change a fingerprint.
fn hash_tokens(hash: *std.hash.Fnv1a_64, tree: *const parse.Tree, index: u32) void {
    const item = tree.item(index);
    for (tree.tokens[item.first .. item.last + 1]) |each| {
        if (each.tag == .comment or each.tag == .newline) continue;
        hash.update(std.mem.asBytes(&each.tag));
        hash.update(each.text(tree.source));
    }
}

/// The standard library, `std`: modules any file may `use std` for (src/lang/std.weft).
pub const std_library = @embedFile("std.weft");

/// The tokens and tree of one file, for formatting without compiling.
pub fn Syntax(comptime limits: Limits) type {
    return struct {
        const Self = @This();

        tokens: [limits.tokens]token.Token,
        items: [limits.tree]parse.Item,
        extra: [limits.tree]u32,
        stack: [limits.tree]u32,
        declarations: [limits.names]u32,
        diagnostic_entries: [limits.errors]Diagnostic,
        diagnostics: diagnostic.List,
        tree: parse.Tree,

        /// Parses `source`; false when it has an error, which `errors` lists.
        pub fn parse_source(syntax: *Self, source: []const u8) bool {
            syntax.diagnostics = .init(&syntax.diagnostic_entries);
            const tokens = token.tokenize(source, &syntax.tokens);
            if (tokens.full) {
                const at: u32 = syntax.tokens[tokens.count - 1].start;
                const found = syntax.diagnostics.add(.limit, at, 1, "the file has more than {d} tokens", .{limits.tokens});
                diagnostic.hint(found, "raise `Limits.tokens`", .{});
            }
            syntax.tree = parse.parse(source, syntax.tokens[0..tokens.count], .{
                .items = &syntax.items,
                .extra = &syntax.extra,
                .stack = &syntax.stack,
                .declarations = &syntax.declarations,
            }, &syntax.diagnostics);
            return syntax.diagnostics.total() == 0;
        }

        pub fn errors(syntax: *const Self) []const Diagnostic {
            return syntax.diagnostics.items();
        }

        /// The parsed file in the canonical format, into `out`.
        pub fn format_into(syntax: *const Self, out: []u8) format.Error![]const u8 {
            assert(syntax.diagnostics.total() == 0);
            return format.format(&syntax.tree, out);
        }
    };
}

/// A compiled file: its program, its tables, and its names (section 2).
pub fn Compiled(comptime limits: Limits) type {
    return struct {
        const Self = @This();

        syntax: Syntax(limits),
        bindings: [limits.names]check.Binding,
        checked_declarations: [limits.names]check.Declaration,
        calls: [limits.tree]check.Call,
        values: [2 * limits.tree]check.Value,
        value_items: [2 * limits.tree]u32,
        exprs: [limits.tree]check.Expr,
        checked_cue_times: [limits.cues]i64,
        checked_goals: [limits.goals]check.Goal,
        checked_paths: [limits.goals]check.Run,
        checked_regions: [limits.regions]check.Region,
        checked_runs: [limits.regions]check.Run,
        checked_tracks: [limits.tracks]check.Track,
        modules: [limits.modules]check.Module,
        frames: [check.frames_max]check.Frame,
        library_syntax: [limits.libraries]Syntax(limits),
        library_list: [limits.libraries]check.Library,
        library_count: u32 = 0,
        /// The library that failed to parse; `errors` then lists its diagnostics.
        failed_library: ?u32 = null,
        instances: [limits.names]check.Instance,
        ranges: [limits.nodes]range_module.Range,
        checked: check.Checked,
        nodes: [limits.nodes]graph.Node,
        cue_times: [limits.cues]time_module.Time,
        goal_entries: [limits.goals]motion.Goal,
        region_entries: [limits.regions]simulation.Region,
        track_entries: [limits.tracks]track_module.Track,
        track_samples: [limits.tracks * limits.track_samples]Sample,
        paths: [limits.goals]motion.Path,
        runs: [limits.regions]simulation.Span,
        ids: [limits.names]Ids,
        goal_sources: [limits.names]GoalSource,
        track_nodes: [limits.tracks]?graph.Id,
        expr_ids: [limits.tree]?back_end.Ids,
        node_ranges: [limits.names]back_end.NodeRange,
        /// Each binding's fingerprint (section 5), for a recompile's carry.
        fingerprints: [limits.names]u64,
        /// The file feeds a delay, so a recompile never carries its state (section 5).
        has_feed: bool,
        tables: back_end.Tables,
        program: graph.Program,
        ok: bool,

        /// Compiles `source` in place. On an error, `errors` lists what was found, and the
        /// program is not set.
        pub fn compile(compiled: *Self, source: []const u8) error{Invalid}!void {
            return compiled.compile_with(&.{}, source);
        }

        /// Compiles `source`, which may `use` any of `libraries`. A library that does not parse
        /// is an error: `errors` then lists its diagnostics, and `failed_library` names it.
        pub fn compile_with(compiled: *Self, libraries: []const Source, source: []const u8) error{Invalid}!void {
            return compiled.compile_client(&.{}, libraries, source);
        }

        /// Compiles `source` with a client's nouns beside the primitives. A client noun is checked
        /// like a primitive, and the back end refuses it: the client builds it from `checked`, which
        /// is set even when the back end refuses.
        pub fn compile_client(compiled: *Self, clients: []const schema.Entry, libraries: []const Source, source: []const u8) error{Invalid}!void {
            compiled.ok = false;
            compiled.failed_library = null;
            assert(libraries.len <= limits.libraries);
            if (comptime limits.libraries > 0) {
                for (libraries, 0..) |library, at| {
                    const syntax = &compiled.library_syntax[at];
                    if (!syntax.parse_source(library.text) or !syntax.tree.complete) {
                        compiled.failed_library = @intCast(at);
                        return error.Invalid;
                    }
                    compiled.library_list[at] = .{ .name = library.name, .tree = &syntax.tree };
                }
            }
            compiled.library_count = @intCast(libraries.len);
            if (!compiled.syntax.parse_source(source) or !compiled.syntax.tree.complete) return error.Invalid;
            compiled.checked = check.check(&compiled.syntax.tree, .{
                .modules = &compiled.modules,
                .frames = &compiled.frames,
                .libraries = compiled.library_list[0..libraries.len],
                .instances = &compiled.instances,
                .clients = clients,
                .bindings = &compiled.bindings,
                .declarations = &compiled.checked_declarations,
                .calls = &compiled.calls,
                .values = &compiled.values,
                .value_items = &compiled.value_items,
                .exprs = &compiled.exprs,
                .cue_times = &compiled.checked_cue_times,
                .goals = &compiled.checked_goals,
                .paths = &compiled.checked_paths,
                .regions = &compiled.checked_regions,
                .region_runs = &compiled.checked_runs,
                .tracks = &compiled.checked_tracks,
            }, &compiled.syntax.diagnostics);
            if (!compiled.checked.ok) return error.Invalid;
            const program = back_end.build(&compiled.checked, &compiled.syntax.tree, .{
                .nodes = &compiled.nodes,
                .slab_count_max = limits.slab,
                .cue_times = &compiled.cue_times,
                .goal_entries = &compiled.goal_entries,
                .region_entries = &compiled.region_entries,
                .track_entries = &compiled.track_entries,
                .track_samples = &compiled.track_samples,
                .paths = &compiled.paths,
                .runs = &compiled.runs,
                .ids = &compiled.ids,
                .goal_sources = &compiled.goal_sources,
                .track_nodes = &compiled.track_nodes,
                .expr_ids = &compiled.expr_ids,
                .node_ranges = &compiled.node_ranges,
            }, &compiled.tables, &compiled.syntax.diagnostics) orelse return error.Invalid;
            compiled.program = program;
            if (!compiled.check_declared_ranges()) return error.Invalid;
            compiled.fingerprint(libraries);
            compiled.ok = true;
        }

        /// Each binding's fingerprint (section 5): its declaration's tokens, the fingerprint of
        /// every earlier binding it names, and what every declaration depends on: the seed, the
        /// start, the modules, and the libraries.
        fn fingerprint(compiled: *Self, libraries: []const Source) void {
            const tree = &compiled.syntax.tree;
            const bindings = compiled.checked.bindings;
            var global = std.hash.Fnv1a_64.init();
            for (libraries) |library| global.update(library.text);
            for (tree.declarations) |index| {
                switch (tree.item(index).tag) {
                    .seed, .start, .module, .use => hash_tokens(&global, tree, index),
                    else => {},
                }
            }
            const base = global.final();
            for (bindings, 0..) |entry, at| {
                var hash = std.hash.Fnv1a_64.init();
                hash.update(std.mem.asBytes(&base));
                hash_tokens(&hash, tree, entry.item);
                const item = tree.item(entry.item);
                for (item.first..item.last + 1) |token_index| {
                    const named = tree.tokens[token_index];
                    if (named.tag != .name) continue;
                    const name = named.text(tree.source);
                    for (bindings[0..at], 0..) |earlier, earlier_at| {
                        if (!std.mem.eql(u8, earlier.name, name)) continue;
                        hash.update(std.mem.asBytes(&compiled.fingerprints[earlier_at]));
                        break;
                    }
                }
                compiled.fingerprints[at] = hash.final();
            }
            compiled.has_feed = false;
            for (compiled.checked.declarations) |declaration| {
                if (declaration == .feed) compiled.has_feed = true;
            }
        }

        /// For each node of this program, its twin in `old`'s (section 5), or null: a node of a
        /// binding with the same name and fingerprint in both, at the same place among the
        /// binding's nodes, a track's nodes not counted.
        pub fn twins(compiled: *const Self, old: *const Self, out: []?u32) void {
            assert(compiled.ok and old.ok);
            assert(out.len == compiled.program.nodes.len);
            @memset(out, null);
            for (compiled.checked.bindings, 0..) |binding_entry, at| {
                if (binding_entry.kind != .signal) continue;
                const old_at = old.binding(binding_entry.name, .signal) orelse continue;
                if (old.fingerprints[old_at] != compiled.fingerprints[at]) continue;
                const range = compiled.node_ranges[at];
                const old_range = old.node_ranges[old_at];
                var j = old_range.first;
                for (range.first..range.end) |i| {
                    if (compiled.program.nodes[i].op == .track) continue;
                    while (j < old_range.end and old.program.nodes[j].op == .track) j += 1;
                    if (j == old_range.end) break;
                    out[i] = j;
                    j += 1;
                }
            }
        }

        /// Keeps `old_state`'s simulated state in `state`, a reader of this program, when every
        /// simulated node has its twin in `old` (section 5). False, changing nothing, otherwise:
        /// the reader then starts fresh, which is right, since a changed simulated node has a
        /// history of its own.
        pub fn carry(compiled: *const Self, state: *State, old: *const Self, old_state: *const State) bool {
            assert(compiled.ok and old.ok);
            if (compiled.has_feed or old.has_feed) return false;
            var found: [limits.nodes]?u32 = undefined;
            const twins_found = found[0..compiled.program.nodes.len];
            compiled.twins(old, twins_found);
            return state.adopt(old_state, twins_found);
        }

        /// Writes again, into this program's tracks, every write a track of the same name has
        /// in `old`, in time order, but those outside the new bounds, which are dropped. Call it
        /// before a reader of this program first reads.
        pub fn carry_tracks(compiled: *Self, old: *const Self) void {
            assert(compiled.ok and old.ok);
            for (compiled.checked.bindings) |binding_entry| {
                if (binding_entry.kind != .track) continue;
                const old_at = old.binding(binding_entry.name, .track) orelse continue;
                const from = old.tables.tracks.at(.{ .index = old.checked.bindings[old_at].index });
                const id: track_module.TrackId = .{ .index = binding_entry.index };
                const to = compiled.tables.tracks.at(id);
                for (from.table()) |sample| {
                    if (sample.value < to.low or sample.value > to.high) continue;
                    compiled.tables.tracks.write(id, sample.time, sample.value) catch break;
                }
            }
        }

        /// Each module instance with a declared range keeps its output inside it (section 3).
        fn check_declared_ranges(compiled: *Self) bool {
            if (compiled.checked.instances.len == 0) return true;
            compiled.program.ranges(compiled.ranges[0..compiled.program.nodes.len]);
            var ok = true;
            for (compiled.checked.instances) |instance| {
                const id = compiled.ids[instance.binding].first;
                const reached = compiled.ranges[id.index];
                if (reached.low >= instance.low and reached.high <= instance.high) continue;
                ok = false;
                const tree = &compiled.syntax.tree;
                const at_token = tree.tokens[tree.item(instance.item).token];
                const found = compiled.syntax.diagnostics.add(.out_of_range, at_token.start, at_token.len, "{s}'s output reaches {d}..{d}, outside its declared {d}..{d}", .{ tree.text(instance.item), reached.low, reached.high, instance.low, instance.high }) orelse continue;
                diagnostic.hint(found, "narrow the body, or widen the declared range", .{});
            }
            return ok;
        }

        pub fn errors(compiled: *const Self) []const Diagnostic {
            if (comptime limits.libraries > 0) {
                if (compiled.failed_library) |at| return compiled.library_syntax[at].errors();
            }
            return compiled.syntax.errors();
        }

        fn binding(compiled: *const Self, name: []const u8, kind: check.Binding.Kind) ?u32 {
            assert(compiled.ok);
            for (compiled.checked.bindings, 0..) |entry, index| {
                if (entry.kind == kind and std.mem.eql(u8, entry.name, name)) return @intCast(index);
            }
            return null;
        }

        /// The node of the signal `name`: a bounce's position.
        pub fn signal(compiled: *const Self, name: []const u8) ?graph.Id {
            const index = compiled.binding(name, .signal) orelse return null;
            return compiled.ids[index].first;
        }

        /// The nodes of the signal `name`: a bounce's position and velocity.
        pub fn outputs(compiled: *const Self, name: []const u8) ?Ids {
            const index = compiled.binding(name, .signal) orelse return null;
            return compiled.ids[index];
        }

        pub fn track(compiled: *const Self, name: []const u8) ?track_module.TrackId {
            const index = compiled.binding(name, .track) orelse return null;
            return .{ .index = compiled.checked.bindings[index].index };
        }

        pub fn cue(compiled: *const Self, name: []const u8) ?cue_module.Cue {
            const index = compiled.binding(name, .cue) orelse return null;
            return .{ .index = compiled.checked.bindings[index].index };
        }

        /// Where the goal of the signal `name` comes from: a spring's or a Newtonian move's
        /// path, a chase's target, or none.
        pub fn goal(compiled: *const Self, name: []const u8) GoalSource {
            const index = compiled.binding(name, .signal) orelse return .none;
            return compiled.goal_sources[index];
        }
    };
}

const testing = std.testing;

const Small = Compiled(.{
    .tokens = 1024,
    .tree = 1024,
    .names = 64,
    .nodes = 64,
    .slab = 1024,
    .cues = 400,
    .goals = 32,
    .regions = 16,
    .tracks = 4,
    .track_samples = 4,
    .errors = 8,
});

var small: Small = undefined;

fn compile_ok(source: []const u8) !*Small {
    small.compile(source) catch {
        for (small.errors()) |found| {
            var buffer: [512]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            found.render(source, "test.weft", &writer) catch {};
            std.debug.print("{s}", .{writer.buffered()});
        }
        return error.TestUnexpectedResult;
    };
    return &small;
}

fn first_error(source: []const u8) !*const Diagnostic {
    try testing.expectError(error.Invalid, small.compile(source));
    try testing.expect(small.errors().len > 0);
    return &small.errors()[0];
}

// Locks a small file end to end: the nodes it builds equal the builder's, in text order, and the
// names find them.
test "a file compiles to the program the builder would make" {
    const compiled = try compile_ok(
        \\seed 7
        \\cue c0 = 0s
        \\cue c1 = 2s
        \\track rate = 0.5 in 0.25..2
        \\moves = [c1: 1]
        \\wave = wave(sine, 0.5hz)
        \\spring = spring(moves, time: 0.5s, overshoot: 0.2)
        \\pulse = oscillator(sine, rate: rate)
        \\sum = wave + spring * 0.5 - 1
        \\
    );
    var nodes: [16]graph.Node = undefined;
    var times: [2]time_module.Time = undefined;
    var cues = cue_module.Cues.init(&times);
    _ = try cues.add(.{ .flicks = 0 });
    const c1 = try cues.add(.{ .flicks = 2 * time_module.flicks_per_second });
    var goal_entries: [1]motion.Goal = undefined;
    var goals = motion.Goals.init(&goal_entries);
    const path = try goals.add(&.{.{ .cue = c1, .value = 1 }});
    var track_entries: [1]track_module.Track = undefined;
    var samples: [4]Sample = undefined;
    var tracks = track_module.Tracks.init(&track_entries);
    const rate = try tracks.add(&samples, 0.25, 2, 0.5);
    var builder = graph.Builder.init(&nodes, .{
        .slab_count_max = 1024,
        .cues = &cues,
        .goals = goals.table(),
        .tracks = &tracks,
        .seed = 7,
    });
    const wave = try builder.wave(.{ .shape = .sine, .hz = 0.5 });
    const spring = try builder.spring(.{
        .from = 0,
        .goals = path,
        .time = .{ .flicks = 352_800_000 },
        .overshoot = 0.2,
    });
    const rate_node = try builder.track(rate);
    const pulse = try builder.oscillator(.{ .shape = .sine, .rate = rate_node });
    const half = try builder.constant(0.5);
    const product = try builder.multiply(spring, half);
    const total = try builder.add(wave, product);
    const minus_one = try builder.constant(-1);
    const sum = try builder.add(total, minus_one);
    const expected = builder.finish();
    try testing.expectEqual(expected.nodes.len, compiled.program.nodes.len);
    for (expected.nodes, compiled.program.nodes) |a, b| try testing.expect(std.meta.eql(a, b));
    try testing.expectEqual(expected.slab_count, compiled.program.slab_count);
    try testing.expectEqual(wave, compiled.signal("wave").?);
    try testing.expectEqual(pulse, compiled.signal("pulse").?);
    try testing.expectEqual(sum, compiled.signal("sum").?);
    try testing.expectEqual(rate, compiled.track("rate").?);
    try testing.expectEqual(c1, compiled.cue("c1").?);
    try testing.expectEqual(path, compiled.goal("spring").path.path);
    try testing.expectEqual(GoalSource.none, compiled.goal("wave"));
}

// Locks each declaration and form: a cue series, a bounce's outputs, a delay fed below, a follower
// over shared regions, and seeds from names.
test "series, outputs, delays, and shared regions" {
    const compiled = try compile_ok(
        \\cue bar = 0s..600s every 2s
        \\b = bounce(0..1, speed: 0.7, at: bar[0])
        \\v = b.velocity * 2
        \\bars = cues(bar)
        \\fb = delay(0)
        \\loop = chase(1 + fb * -0.8, time: 0.5s, overshoot: 0.2)
        \\fb <- loop
        \\a = follow([0..1], by: spring(time: 1s), pause: 0s..1s)
        \\z = follow([0..1], by: newtonian(speed: 1, accel: 16, decel: 16))
        \\n = noise(smooth, 1hz)
        \\
    );
    const program = compiled.program;
    try testing.expectEqual(@as(u32, 301), compiled.tables.cues.count);
    const ids = compiled.outputs("b").?;
    try testing.expectEqual(ids.first.index + 1, ids.second.?.index);
    const bars = program.nodes[compiled.signal("bars").?.index].op.cues;
    try testing.expectEqual(@as(u32, 301), bars.count);
    try testing.expectEqual(@as(usize, 1), compiled.tables.regions.count);
    const a = program.nodes[compiled.signal("a").?.index].op.follow;
    const z = program.nodes[compiled.signal("z").?.index].op.follow;
    try testing.expectEqual(a.regions, z.regions);
    const delay = program.nodes[compiled.signal("fb").?.index].op.delay;
    try testing.expectEqual(compiled.signal("loop").?, delay.input.?);
    const n = program.nodes[compiled.signal("n").?.index].op.noise;
    const noise_module = @import("../core/noise.zig");
    const expected: noise_module.Noise = .{ .shape = .smooth, .hz = 1, .seed = std.hash.Fnv1a_64.hash("n") };
    try testing.expectEqual(expected.derive(0).seed, n.seed);
}

// Locks the errors with their suggestions, one each.
test "errors name the problem and suggest the fix" {
    const Case = struct { source: []const u8, code: diagnostic.Code, hint: []const u8 };
    const cases = [_]Case{
        .{ .source = "n = noise(smooth, 1hz)\nc = chase(n, tme: 1s)\n", .code = .unknown_parameter, .hint = "did you mean `time`?" },
        .{ .source = "noise = wave(sine, 1hz)\nc = chase(nosie, time: 1s)\n", .code = .unknown_name, .hint = "did you mean `noise`?" },
        .{ .source = "x = wave(sine, 1hz)\nc = chase(x, time: 0.5)\n", .code = .wrong_type, .hint = "a time needs a unit: `0.5s`?" },
        .{ .source = "w = wave(sine, 1)\n", .code = .wrong_type, .hint = "write `1hz`" },
        .{ .source = "a = chase(b, time: 1s)\nb = wave(sine, 1hz)\n", .code = .used_before_declared, .hint = "move it up, or go through a delay" },
        .{ .source = "w = wav(sine, 1hz)\n", .code = .unknown_call, .hint = "did you mean `wave`?" },
        .{ .source = "w = wave(sin, 1hz)\n", .code = .unknown_word, .hint = "did you mean `sine`?" },
        .{ .source = "cue c = 0.000001s\n", .code = .not_whole_flicks, .hint = "the nearest is 706 flicks; seconds are exact to 5 places, ms to 2" },
        .{ .source = "w = wave(sine, 1hz)\nw = wave(sine, 2hz)\n", .code = .duplicate_name, .hint = "it was declared on line 1" },
        .{ .source = "cue c0 = 0s\ncue c1 = 1s\nm = [c1: 1]\nw = wave(sine, 1hz)\ns = spring(m, time: w)\n", .code = .not_live, .hint = "chase follows a moving value, and a follower's mover reads signals" },
        .{ .source = "cue c0 = 0s\nm = [c0: 1]\ns = spring(m, time: 1s, overshoot: 1.5)\n", .code = .refused, .hint = "0 settles without passing the goal; 0.5 is bouncy" },
        .{ .source = "f = follow([0..1], by: spring(time: 1s))\n", .code = .refused, .hint = "declare one, such as `cue c0 = 0s`" },
        .{ .source = "fb = delay(0)\n", .code = .delay_not_fed, .hint = "add `fb <- …` below the signal it delays" },
        .{ .source = "cue = wave(sine, 1hz)\n", .code = .reserved_name, .hint = "choose another name, such as `cue_1`" },
        .{ .source = "w = wave(sine, hz: 1hz, 2)\n", .code = .positional_after_named, .hint = "write it first, or give it its name" },
        .{ .source = "s = spring(time: 1s)\n", .code = .missing_argument, .hint = "add `goals: goals, such as [c1: 1]`" },
        .{ .source = "x = 2sec\n", .code = .bad_unit, .hint = "a unit is s, ms, or hz, right after the number" },
    };
    for (cases) |case| {
        const found = try first_error(case.source);
        testing.expectEqual(case.code, found.code) catch |err| {
            std.debug.print("{s}: {s}\n", .{ case.source, found.message_text() });
            return err;
        };
        testing.expectEqualStrings(case.hint, found.hint_text()) catch |err| {
            std.debug.print("{s}: {s}\n", .{ case.source, found.message_text() });
            return err;
        };
    }
}

// Locks section 2's limits: a file past a limit is an error naming the field.
test "a limit is an error that names its field" {
    const found = try first_error("cue bar = 0s..1000s every 1s\n");
    try testing.expectEqual(diagnostic.Code.limit, found.code);
    try testing.expectEqualStrings("raise `Limits.cues`", found.hint_text());
}

/// The fuzz test's inputs: random bytes, then mutations of these.
const fuzz_seeds = [_][]const u8{
    "seed 7\ncue c0 = 0s\ncue c1 = 2s\ntrack t = 0.5 in 0.125..2\nmoves = [c1: 1]\n" ++
        "n = noise(smooth, 1hz, seed: 1)\ns = spring(moves, time: 0.5s)\nc = chase(n, time: t)\n",
    "cue bar = 0s..10s every 2s\nb = bounce(0..1, speed: 0.7, at: bar[0])\nv = b.velocity\n" ++
        "bars = cues(bar)\n",
    "cue c0 = 0s\nfb = delay(0)\nl = chase(1 + fb * -0.8, time: 0.5s)\nfb <- l\n" ++
        "f = follow(\n    [0..1], # one\n    by: newtonian(speed: 1, accel: 4, decel: 4),\n    seed: 9,\n)\n",
    "module m(x, y: 2) in -4..4 = x * y\nmodule n(g) = m(g, y: 0.5) + m(m(g))\n" ++
        "module w(t: 0.3s) = spring(time: t)\nout = n(wave(sine, 1hz))\n" ++
        "f = follow([0..1], by: w(), seed: 3)\nuse std\n",
};

var fuzz_syntax: Syntax(.{}) = undefined;
var fuzz_out: [1 << 16]u8 = undefined;
var fuzz_again: [1 << 16]u8 = undefined;

/// Compiles and formats one input: it must compile or give an error, and a file that parsed must
/// format idempotently or refuse a comment.
fn fuzz_one(input: []const u8) !void {
    const compiled = small.compile(input);
    if (compiled) |_| {} else |_| try testing.expect(small.errors().len > 0);
    if (!fuzz_syntax.parse_source(input) or !fuzz_syntax.tree.complete) return;
    const formatted = fuzz_syntax.format_into(&fuzz_out) catch |err| {
        try testing.expectEqual(error.CommentPlacement, err);
        return;
    };
    errdefer std.debug.print("input: {any}\n", .{input});
    try testing.expect(fuzz_syntax.parse_source(formatted));
    const again = try fuzz_syntax.format_into(&fuzz_again);
    try testing.expectEqualStrings(formatted, again);
}

/// Inputs of each kind the fuzz test runs: random ones, and mutated ones.
pub const fuzz_count = 20_000;

// Locks section 4: random bytes and mutations of the examples never crash the front end, and
// each compiles or gives an error, within the limits.
test "random bytes never crash the front end" {
    var prng = std.Random.DefaultPrng.init(0x5eed_12);
    const random = prng.random();
    var buffer: [512]u8 = undefined;
    const alphabet = "abcehimnorstvz019._ =<-,:()[]#+*\n\t\x00\xff";
    for (0..fuzz_count) |_| {
        const len = random.uintAtMost(usize, 256);
        for (buffer[0..len]) |*byte| {
            byte.* = if (random.boolean()) alphabet[random.uintLessThan(usize, alphabet.len)] else random.int(u8);
        }
        try fuzz_one(buffer[0..len]);
    }
    for (0..fuzz_count) |_| {
        const seed = fuzz_seeds[random.uintLessThan(usize, fuzz_seeds.len)];
        var len = seed.len;
        @memcpy(buffer[0..len], seed);
        for (0..1 + random.uintLessThan(usize, 4)) |_| {
            const at = random.uintAtMost(usize, len);
            switch (random.uintLessThan(u8, 3)) {
                0 => if (at < len) {
                    buffer[at] = alphabet[random.uintLessThan(usize, alphabet.len)];
                },
                1 => if (len < buffer.len) {
                    std.mem.copyBackwards(u8, buffer[at + 1 .. len + 1], buffer[at..len]);
                    buffer[at] = alphabet[random.uintLessThan(usize, alphabet.len)];
                    len += 1;
                },
                else => if (at < len) {
                    std.mem.copyForwards(u8, buffer[at .. len - 1], buffer[at + 1 .. len]);
                    len -= 1;
                },
            }
        }
        try fuzz_one(buffer[0..len]);
    }
}

test {
    _ = token;
    _ = parse;
    _ = diagnostic;
    _ = schema;
    _ = format;
    _ = check;
    _ = back_end;
}
