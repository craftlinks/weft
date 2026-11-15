//! Weft's text front end: Jig's files compiled once into a `Program`. This package (module
//! `weft_text`) is Weft's table of calls, its back end, `Compiled`, and `std`; the language is
//! Jig (module `jig`), a repository of its own, and the core is `weft`.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. A Front End, and a Back End
//! Text goes through four stages. The first three are Jig's, each a file with its own guide
//! (`../../jig`), and the last is here:
//! ```text
//! token.zig   bytes to tokens: names, literals with their units, punctuation, comments
//! parse.zig   tokens to a flat tree, one declaration a line
//! check.zig   the tree to checked declarations: names, order, types, defaults, seeds,
//!             each call checked against the table of primitives in src/table.zig
//! src/graph.zig  checked declarations to a Program, through the Builder
//! ```
//! Jig's `format.zig` writes a tree back as canonical text, and its `error.zig` holds the
//! diagnostics. The back end runs once, at compile, so text adds nothing to `eval`: the program
//! is the one a hand-written builder call would make, node for node. A client reads one name for
//! each thing: `jig.…` for the language, `weft_text.…` for what is here, `weft.…` for the core;
//! nothing is re-exported, and `build.zig` exposes the one instance of `weft` and `jig` it was
//! built from, so a client's entries are the type `Compiled` takes.
//!
//! ## 2. Memory
//! `Compiled(limits)` holds every array the four stages write, at sizes fixed at compile time, and
//! the tables the program reads. The `Program` points at its cue and track tables, so a `Compiled`
//! is built in place and never moves, as Play's `Signals` was. A full array is an error that names
//! its field of `Limits`, never a crash.
//!
//! ## 2a. The Language's Part
//! `Compiled` is two jobs in one struct (step 57). Its fields from `syntax` to `checked` are the
//! language's, the ones `jig.File(limits.file(), table.vocabulary)` has, under the same names
//! and types, which a comptime block holds equal; the rest are the program's and its tables.
//! `check_client` runs the language's part only, through the one function `File` calls, and
//! leaves `program` alone; `build_program` is the back end's part; `compile_client` is the two.
//! A client that builds its own program from `checked` and wants no Weft program calls `File`
//! or `check_client`. `Limits` stays the flat struct a client writes and hands the language its
//! part with `file()`; `Syntax(limits)` is the language's `Syntax` at that part.
//!
//! ## 3. Names for a Client
//! The program stores no names (`graph.zig`, section 5). A client asks the `Compiled` for a
//! signal's node, a track, a cue, or where a signal's goal comes from, by the name the text gave
//! it, once at init. The other way, `cue_name` gives a cue's name from its index in the table, a
//! value a noun or an event carries, so a client can print it (step 32).
//!
//! ## 3a. Where a Number Is Written
//! A client that writes a number back into its text, a knob, a slider, a retime, finds it
//! through the checker's own grammar (step 41), never a copy of it: `cue_form` gives what a
//! cue's declaration is made of, `track_form` a track's three numbers as plain literals' bytes
//! or what else they are, and `read_time` and `write_time` read and write a time literal
//! exactly (`check.zig`, sections 3c, 4, and 4a). `Syntax.track_form` reads the tree alone, for
//! a client that binds its numbers while another line has an error. Weft never edits the text:
//! the client replaces its own bytes and compiles again, which checks the edit.
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
//! A client's entries join the table of primitives through `compile_client`, which takes them as
//! a comptime parameter (step 56), so a name clash is a compile error; `entries_of` is the joined
//! list a client formats its files with. A `client` entry
//! (step 14) is a signal the checker accepts and the back end refuses, so the client builds it
//! from `checked`. A `noun` entry (step 27) only describes: the file compiles, and the client
//! walks `nouns()` for each one's name, entry, and values, with `node_of` for a signal's node.
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
const jig = @import("jig");
const weft = @import("weft");
pub const table = @import("src/table.zig");
pub const back_end = @import("src/graph.zig");
const token = jig.token;
const parse = jig.parse;
const diagnostic = jig.diagnostic;
const schema = jig.schema;
const format = jig.format;
const check = jig.check;
const Source = jig.Source;
const CueName = jig.CueName;
const Diagnostic = diagnostic.Diagnostic;
const graph = weft.graph;
const State = graph.State;
const range_module = weft.range;
const motion = weft.motion;
const simulation = weft.simulation;
const track_module = weft.track;
const time_module = weft.time;
const cue_module = weft.cue;
const Sample = weft.recording.Sample;

pub const GoalSource = back_end.GoalSource;
pub const Ids = back_end.Ids;

/// How large a file may be: the language's tables (`jig.FileLimits`) and the back end's, the
/// program's nodes and slab and each track's samples. A flat struct, as a client writes it
/// (step 57); `file` hands the language its part.
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

    /// The language's part: every field of `jig.FileLimits`, with this struct's value.
    pub fn file(limits: Limits) jig.FileLimits {
        var result: jig.FileLimits = undefined;
        inline for (@typeInfo(jig.FileLimits).@"struct".field_names) |name| {
            @field(result, name) = @field(limits, name);
        }
        assert(result.tokens == limits.tokens);
        assert(result.errors == limits.errors);
        return result;
    }
};

/// A library's name and its text, for `compile_with`.
/// The one list a file is checked and formatted against: Weft's table, then a client's entries. A
/// clash between them is a compile error (`schema.join`). A client formats its files with
/// `format.format(tree, entries_of(&clients), out)`, so its calls' named arguments take their
/// entries' order.
pub fn entries_of(comptime clients: []const schema.Entry) []const schema.Entry {
    return schema.join(table.vocabulary, clients);
}

/// The input of a `spread`, which gives one node's value to every lane, else the node itself.
fn through_spread(nodes: []const graph.Node, id: graph.Id) graph.Id {
    assert(id.index < nodes.len);
    return switch (nodes[id.index].op) {
        .spread => |input| input,
        else => id,
    };
}

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

/// The standard library, `std`: modules any file may `use std` for (text/src/std.jig).
pub const std_library = @embedFile("src/std.jig");

/// The tokens and tree of one file, for formatting without compiling: the language's `Syntax`
/// at the language's part of `limits`, formatting with Weft's table (step 57).
pub fn Syntax(comptime limits: Limits) type {
    return jig.Syntax(limits.file(), table.vocabulary.entries);
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
        checked_cue_forms: [limits.cues]check.CueForm,
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

        comptime {
            // Every field of the language's `File` is here, under the same name and type, so the
            // functions that read a `File` read this struct too and the two cannot drift
            // (step 57).
            const Container = jig.File(limits.file(), table.vocabulary);
            const info = @typeInfo(Container).@"struct";
            for (info.field_names, info.field_types) |name, field_type| {
                assert(@hasField(Self, name));
                assert(@FieldType(Self, name) == field_type);
            }
        }

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
        pub fn compile_client(compiled: *Self, comptime clients: []const schema.Entry, libraries: []const Source, source: []const u8) error{Invalid}!void {
            compiled.ok = false;
            try compiled.check_client(clients, libraries, source);
            return compiled.build_program(libraries);
        }

        /// The language's part of a compile (step 57): parses and checks `source` and its
        /// `libraries` and builds no program. `checked` is valid after it, and `program` is not
        /// touched. A file of a client's own signals checks here, which `build_program` refuses.
        pub fn check_client(compiled: *Self, comptime clients: []const schema.Entry, libraries: []const Source, source: []const u8) error{Invalid}!void {
            compiled.ok = false;
            return jig.file.check_fields(limits.file(), table.vocabulary, clients, compiled, libraries, source);
        }

        /// The back end's part: builds the program from `checked`, which `check_client` set, and
        /// refuses a client's signal. `libraries` are the ones `check_client` was given.
        pub fn build_program(compiled: *Self, libraries: []const Source) error{Invalid}!void {
            assert(compiled.checked.ok);
            assert(!compiled.ok);
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

        /// The least `Limits` this file compiles with, as it compiled just now: every field but
        /// `track_samples` and `errors`, which the client chooses, and which keep this `limits`'
        /// values. `weft check` prints it, so a client can size a `Compiled` to a file (step 22).
        /// The language's fields come from `jig.file.needs_of`; the back end adds its own.
        pub fn needs(compiled: *const Self) Limits {
            assert(compiled.ok);
            const file = jig.file.needs_of(limits.file(), compiled);
            const tables = &compiled.tables;
            return .{
                .tokens = file.tokens,
                .tree = file.tree,
                .names = file.names,
                .nodes = @intCast(compiled.program.nodes.len),
                .slab = compiled.program.slab_count,
                .cues = @max(file.cues, @as(u32, @intCast(tables.cues.count))),
                .goals = @max(file.goals, @as(u32, @intCast(tables.goals.count))),
                .regions = @max(file.regions, @as(u32, @intCast(tables.regions.count))),
                .tracks = file.tracks,
                .track_samples = limits.track_samples,
                .modules = file.modules,
                .libraries = file.libraries,
                .errors = limits.errors,
            };
        }

        /// The least language limits the file checked with, as `check_client` left it: what
        /// `needs` says of the language's tables, without a program (step 57).
        pub fn file_needs(compiled: *const Self) jig.FileLimits {
            return jig.file.needs_of(limits.file(), compiled);
        }

        /// The first call of the file that is a client's own signal, which Weft does not build,
        /// as `check_client` left it; null when there is none (step 57).
        pub fn client_signal(compiled: *const Self) ?*const schema.Entry {
            assert(compiled.checked.ok);
            for (compiled.checked.calls) |call| {
                if (call.entry.op == .client) return call.entry;
            }
            return null;
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
                    .seed, .tempo, .start, .module, .use => hash_tokens(&global, tree, index),
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
                if (binding_entry.kind != .signal and binding_entry.kind != .noun) continue;
                const old_at = old.binding(binding_entry.name, binding_entry.kind) orelse continue;
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
                // The analysis widens each range by a rounding margin, so a body that stays inside
                // its declared range is allowed that margin of the declared scale too.
                const declared: range_module.Range = .{ .low = instance.low, .high = instance.high };
                const allowed = declared.widen(declared.scale(), range_module.margin_motion);
                if (reached.low >= allowed.low and reached.high <= allowed.high) continue;
                ok = false;
                const tree = &compiled.syntax.tree;
                const at_token = tree.tokens[tree.item(instance.item).token];
                const found = compiled.syntax.diagnostics.add(.out_of_range, at_token.start, at_token.len, "{s}'s output reaches {d}..{d}, outside its declared {d}..{d}", .{ tree.text(instance.item), reached.low, reached.high, instance.low, instance.high }) orelse continue;
                diagnostic.hint(found, "narrow the body, or widen the declared range", .{});
            }
            return ok;
        }

        pub fn errors(compiled: *const Self) []const Diagnostic {
            return jig.file.errors_of(limits.file(), compiled);
        }

        fn binding(compiled: *const Self, name: []const u8, kind: check.Binding.Kind) ?u32 {
            assert(compiled.ok);
            return jig.file.binding_of(&compiled.checked, name, kind);
        }

        /// The file's nouns, in its order.
        pub fn nouns(compiled: *const Self) jig.file.NounIterator {
            assert(compiled.ok);
            return .{ .checked = &compiled.checked };
        }

        /// The noun `binding` holds, which a `noun` value names.
        pub fn noun_of(compiled: *const Self, binding_index: u32) jig.file.Noun {
            assert(compiled.ok);
            return jig.file.noun_of_checked(&compiled.checked, binding_index);
        }

        /// The noun bound to `name`.
        pub fn noun(compiled: *const Self, name: []const u8) ?jig.file.Noun {
            const index = compiled.binding(name, .noun) orelse return null;
            return compiled.noun_of(index);
        }

        /// The node of a `signal` value of a noun: one value, a vector's pack, or a region's lanes,
        /// as `program.nodes[id.index].extent` says.
        pub fn node_of(compiled: *const Self, value: check.Value) graph.Id {
            assert(compiled.ok);
            return compiled.expr_ids[value.signal].?.first;
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

        /// The nodes that fire the events of the signal `name`, the list `State.events_of` takes
        /// (step 23): its first node, followed through a `spread` to its input and through a
        /// `pack` to its components, sorted, with the nodes that fire nothing left out. So a bounce
        /// in a region with no stagger, which is one bounce spread over the lanes, and a vector's
        /// spring, one spring a component, give their events. Empty for a name that is not a
        /// signal. `out` holds at least `graph.components_max` ids.
        pub fn event_sources(
            compiled: *const Self,
            name: []const u8,
            out: []graph.Id,
        ) []const graph.Id {
            assert(out.len >= graph.components_max);
            const first = compiled.signal(name) orelse return out[0..0];
            const nodes = compiled.program.nodes;
            const top = through_spread(nodes, first);
            var candidates: [graph.components_max]graph.Id = undefined;
            var candidate_count: usize = 0;
            switch (nodes[top.index].op) {
                .pack => |pack| for (pack.inputs[0..pack.count]) |input| {
                    candidates[candidate_count] = through_spread(nodes, input);
                    candidate_count += 1;
                },
                else => {
                    candidates[0] = top;
                    candidate_count = 1;
                },
            }
            var count: usize = 0;
            for (candidates[0..candidate_count]) |id| {
                if (!State.fires_events(&nodes[id.index])) continue;
                // An insertion that keeps `out` ascending, dropping a component read twice.
                var at = count;
                while (at > 0 and out[at - 1].index > id.index) : (at -= 1) {}
                if (at > 0 and out[at - 1].index == id.index) continue;
                std.mem.copyBackwards(graph.Id, out[at + 1 .. count + 1], out[at..count]);
                out[at] = id;
                count += 1;
            }
            assert(count <= graph.components_max);
            assert(State.sources_valid(&compiled.program, out[0..count]));
            return out[0..count];
        }

        pub fn track(compiled: *const Self, name: []const u8) ?track_module.TrackId {
            const index = compiled.binding(name, .track) orelse return null;
            return .{ .index = compiled.checked.bindings[index].index };
        }

        pub fn cue(compiled: *const Self, name: []const u8) ?cue_module.Cue {
            const index = compiled.binding(name, .cue) orelse return null;
            return .{ .index = compiled.checked.bindings[index].index };
        }

        /// The name of the cue at `cue_index` in the cue table (step 32): a noun's `cue` value,
        /// or an event's from `cues(…)`. A cue of a series gives the series and its place in it.
        /// Null for an index past the table.
        pub fn cue_name(compiled: *const Self, cue_index: u32) ?CueName {
            assert(compiled.ok);
            return jig.file.cue_name_of(&compiled.checked, cue_index);
        }

        /// What the declaration of the cue at `cue_index` in the cue table is made of (section
        /// 3a): a literal, an earlier cue, or both; alone, an item of a list, or a cue of a
        /// series spaced `every` a step. Null for an index past the table.
        pub fn cue_form(compiled: *const Self, cue_index: u32) ?check.CueForm {
            assert(compiled.ok);
            return jig.file.cue_form_of(&compiled.checked, cue_index);
        }

        /// The three numbers of the track `name` (section 3a): each a plain literal's bytes, or
        /// what else it is. Null for a name that is not a track.
        pub fn track_form(compiled: *const Self, name: []const u8) ?check.TrackForm {
            assert(compiled.ok);
            return jig.file.track_form_of(&compiled.checked, &compiled.syntax.tree, name);
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
            found.render(source, "test.jig", &writer) catch {};
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
    const noise_module = weft.noise;
    const expected: noise_module.Noise = .{ .shape = .smooth, .hz = 1, .seed = std.hash.Fnv1a_64.hash("n") };
    try testing.expectEqual(expected.derive(0).seed, n.seed);
}

// Locks a cue after a cue (`check.zig`, section 4a): the table holds the sums, a series may
// start from one, and the order rule still holds.
test "a cue is a time, or a cue and a time after it" {
    const compiled = try compile_ok(
        \\cue b1 = 2s
        \\cue hit = b1 + 500ms
        \\cue same = hit
        \\cue tick = hit + 1s..hit + 3s every 500ms
        \\cue last = tick[4] + 250ms
        \\rise = tween(from: 0, to: 1, at: hit, over: 1s)
        \\
    );
    const second = time_module.flicks_per_second;
    const times = compiled.tables.cues.times[0..compiled.tables.cues.count];
    try testing.expectEqual(@as(usize, 9), times.len);
    try testing.expectEqual(@as(i64, 2 * second + second / 2), times[1].flicks);
    try testing.expectEqual(times[1].flicks, times[2].flicks);
    try testing.expectEqual(@as(i64, 3 * second + second / 2), times[3].flicks);
    try testing.expectEqual(@as(i64, 5 * second + 3 * second / 4), times[8].flicks);
    try testing.expectEqual(diagnostic.Code.cue_out_of_order, (try first_error("cue a = 1s\ncue b = a - 500ms\n")).code);
    try testing.expectEqual(diagnostic.Code.cue_out_of_order, (try first_error("cue a = 1s\ncue b = 2s\ncue c = a + 500ms\n")).code);
    try testing.expectEqual(diagnostic.Code.wrong_type, (try first_error("cue a = 1s\ncue b = 500ms + a\n")).code);
    try testing.expectEqual(diagnostic.Code.wrong_type, (try first_error("cue a = 1s\ncue b = a + 2\n")).code);
    try testing.expectEqual(diagnostic.Code.used_before_declared, (try first_error("cue b = a + 1s\ncue a = 1s\n")).code);
    // The canonical format keeps the sum as it was written.
    var buffer: [256]u8 = undefined;
    _ = try compile_ok("cue b1=2s\ncue hit=b1+500ms\n");
    try testing.expectEqualStrings("cue b1 = 2s\ncue hit = b1 + 500ms\n", try small.syntax.format_into(&buffer));
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
        .{ .source = "x = 2sec\n", .code = .bad_unit, .hint = "a unit is s, ms, b, or hz, right after the number" },
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
    "cue c0 = 0s\ncue c1 = 1s\np = spring([c0: vec2(0, 1), c1: vec2(1, 0)], from: 0.5, time: 0.5s)\n" ++
        "c = tween(from: srgb(1, 0.5, 0), to: oklab(0.6, -0.1, 0.1), at: c0, over: 2s)\n" ++
        "d = tween(to: srgb(0, 0, 1), at: c1, over: 1s, after: c)\n" ++
        "v = chase(vec3(wave(sine, 1hz), 0, p.y), time: 0.25s) * 2 - p.x\nl = c.l + map(p, from: 0..1, to: 2..3).y\n" ++
        "module m(a) = a.x * vec2(1, 2)\nq = m(p)\nr = spring([c0: 1], from: 0, time: 1s)\n",
    "cue c0 = 0s\nb = lanes(8, tween(from: 0, to: lane * 0.1, at: c0, over: 1s, stagger: 5ms))\n" ++
        "n = lanes(8, noise(smooth, 1hz) + lane / 4)\nh = lanes(8, bounce(0..1, speed: 1, at: c0, stagger: -2ms))\n" ++
        "fb = lanes(8, delay(0))\nfb <- n * 0.5 + fb * 0.25\nv = lanes(8, vec2(lane, 1)) + b\n",
    // Functions of a value (step 26): numbers that fold, a vector, lanes, a simulated input,
    // and a clamp as a module.
    "cue c0 = 0s\nw = wave(sine, 1hz)\na = abs(w - 0.5)\nm = min(vec2(w, 1), 0.5) + max(-0, 0)\n" ++
        "x = max(lanes(4, lane), abs(-1))\nmodule hold(v, lo, hi) = min(max(v, lo), hi)\n" ++
        "c = hold(chase(w, time: 0.25s) * 2, -1, 1)\nk = lanes(4, min(abs(lane - 2), w))\n",
    // Functions of a value (step 33): every one, numbers that fold and overflow, a vector, lanes,
    // a simulated input, and a quantize as a module.
    "cue c0 = 0s\nw = wave(sine, 1hz) * 4\ns = sin(w) + cos(vec2(w, 1)).y\ne = exp(w * 200) + ln(w)\n" ++
        "q = sqrt(w - 1) + floor(w) + round(-0.5)\np = pow(w, 3) + pow(1e200, 2)\n" ++
        "module snap(v, step) = round(v / step) * step\nk = lanes(4, snap(chase(w, time: 0.25s), 0.5) + lane)\n",
    // A cue chosen by lane and a series written as a list (step 28), through a module too.
    "cue c0 = 0s\ncue beat = [1s, c0 + 1080ms, 1160ms, 1560ms]\n" ++
        "t = lanes(4, tween(from: 0, to: 1, at: beat[lane], over: 300ms, ease: out))\n" ++
        "b = lanes(4, bounce(0..1, speed: 4, at: beat[lane]))\nmodule letter(at) = tween(to: 2, at: at, over: 1s, after: t)\n" ++
        "u = lanes(4, letter(beat[lane]))\nn = cues(beat)\n",
    // Where a number is written (step 41): every form of a cue, and a track's folded numbers.
    "cue a = -250ms\ncue b = a\ncue c = b + 1.5s\ncue s = [2s, c + 1s, s0]\ncue s0 = 3s\n" ++
        "cue bar = s[1] + 1s..s[1] + 5s every 2s\ntrack t = 2 * 0.25 in -pi..tau\ntrack u = 1e-1 in 0..1\n",
    // A tempo and times in beats (Jig step 1): a list, and a series whose cues are rounded once.
    "tempo 174\ncue c = [1b, 2.5b]\ncue s = 0b..4b every 1b\n",
    // A loop that runs away within half a second, so the reader meets the bound (step 19).
    "cue c0 = 0s\nfb = delay(0)\nloop = chase(1 + fb * 1e100, time: 0.01s)\nfb <- loop\nx = loop * loop * loop\n",
};

var fuzz_syntax: Syntax(.{}) = undefined;
var fuzz_slab: [1024]f64 = undefined;
var fuzz_out: [1 << 16]u8 = undefined;
var fuzz_again: [1 << 16]u8 = undefined;

/// Compiles and formats one input: it must compile or give an error, and a file that parsed must
/// format idempotently or refuse a comment.
fn fuzz_one(input: []const u8) !void {
    const compiled = small.compile(input);
    if (compiled) |_| {
        // A file that compiles also reads, at its start and half a second in, and a loop that
        // runs away saturates rather than crashing (step 19).
        var state = State.init(small.program, fuzz_slab[0..small.program.slab_count]);
        for ([_]i64{ 0, @divExact(time_module.flicks_per_second, 2) }) |flicks| {
            state.eval(.{ .flicks = flicks });
            _ = state.finite();
        }
        try fuzz_forms(small);
    } else |_| try testing.expect(small.errors().len > 0);
    if (!fuzz_syntax.parse_source(input) or !fuzz_syntax.tree.complete) return;
    for (fuzz_syntax.tree.declarations) |index| {
        if (fuzz_syntax.tree.item(index).tag == .track) _ = check.track_form(&fuzz_syntax.tree, index);
    }
    const formatted = fuzz_syntax.format_into(&fuzz_out) catch |err| {
        try testing.expectEqual(error.CommentPlacement, err);
        return;
    };
    errdefer std.debug.print("input: {any}\n", .{input});
    try testing.expect(fuzz_syntax.parse_source(formatted));
    const again = try fuzz_syntax.format_into(&fuzz_again);
    try testing.expectEqualStrings(formatted, again);
}

/// A file that compiled: each cue's form sums to the cue's time, and each track's numbers are
/// forms the checker folds (section 3a).
fn fuzz_forms(compiled: anytype) !void {
    const times = compiled.checked.cue_times;
    for (times, 0..) |time, cue| {
        const form = compiled.cue_form(@intCast(cue)).?;
        const written = form.written() orelse {
            const from = fuzz_sum(times, form.every.from);
            if (form.every.step.unit != .b) {
                try testing.expectEqual(time, from + form.every.step.signed() * form.every.element);
            } else {
                // A beat series' cue is not `from + step * element` (Jig step 1).
                const source = compiled.syntax.tree.source;
                try testing.expectEqual(time, check.series_flicks(source, times, form.every, compiled.checked.tempo));
            }
            continue;
        };
        try testing.expectEqual(time, fuzz_sum(times, written));
    }
    for (compiled.checked.bindings) |binding| {
        if (binding.kind == .track) _ = compiled.track_form(binding.name).?;
    }
}

fn fuzz_sum(times: []const i64, time: check.CueTime) i64 {
    return switch (time) {
        .literal => |literal| literal.signed(),
        .cue => |base| times[base],
        .after => |after| times[after.base] + after.offset.signed(),
    };
}

/// Inputs of each kind the fuzz test runs: random ones, and mutated ones.
pub const fuzz_count = 20_000;

// Locks section 4: random bytes and mutations of the examples never crash the front end, and
// each compiles or gives an error, within the limits.
test "random bytes never crash the front end" {
    var prng = std.Random.DefaultPrng.init(0x5eed_12);
    const random = prng.random();
    var buffer: [512]u8 = undefined;
    const alphabet = "abcehimnorstvz019._ =<-,:()[]#+*/\n\t\x00\xff";
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
