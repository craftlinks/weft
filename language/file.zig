//! A checked file: the syntax and the checked tables, with no back end (step 57).
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Is
//! `File(limits, vocabulary)` holds what the language writes of a file: its tokens and tree, the
//! checker's bindings, calls, values, cues, goals, regions, tracks, and modules, and the
//! libraries it `use`s. `check_client` parses and checks and runs no back end, so a file of a
//! client's own signals, which a back end such as Weft's refuses, checks with no diagnostic. A
//! back end that builds a program holds these same fields beside its own; Weft's `Compiled` does
//! (step 57), under the same names and types, and a comptime block in `src/lang/lang.zig` holds
//! the two lists equal, so they cannot drift.
//!
//! ## 2. One Function, Two Callers
//! Parsing and checking are written once, in `check_fields`, over a pointer to any struct with
//! those fields. `File` calls it on itself, and `Compiled` on itself, so a fix to one is the
//! other's. The functions that need no program (`cue_name`, `cue_form`, `track_form`, the nouns)
//! are free functions over a `Checked` and a tree for the same reason, and both types call them.
//!
//! ## 3. What Stays a Back End's
//! `File.cue` and `File.track` give a table index, since the id types of Weft's core are not the
//! language's; `Compiled.cue` and `Compiled.track` wrap that index in them. `File` has no `ok`:
//! `checked.ok` says a file checked, and a library that failed to parse leaves it false.
//!
//! ## 4. TigerStyle Invariants
//! - No allocation: every array is a field, sized by `FileLimits`.
//! - Bounded: the same passes as the language's, over fixed arrays.

const std = @import("std");
const assert = std.debug.assert;
const token = @import("token.zig");
const parse = @import("parse.zig");
const diagnostic = @import("error.zig");
const schema = @import("schema.zig");
const format = @import("format.zig");
const check = @import("check.zig");
const FileLimits = @import("limits.zig").FileLimits;

pub const Diagnostic = diagnostic.Diagnostic;

/// A library's name and its text, for `check_client`.
pub const Source = struct { name: []const u8, text: []const u8 };

/// What `cue_name` gives for a cue: the name it was declared with, or for a cue of a series the
/// series' name and the cue's place in it, `bar[2]`.
pub const CueName = struct {
    name: []const u8,
    /// The cue's index in its series, or null for a cue declared alone.
    element: ?u32 = null,
};

/// A noun that only describes (step 27), as its declaration wrote it.
pub const Noun = struct {
    /// The name it is bound to, the client's stable id for it.
    name: []const u8,
    entry: *const schema.Entry,
    /// One value for each of `entry.params`, defaults filled in.
    values: []const check.Value,
    /// Its binding, which a `noun` value of another noun names.
    binding: u32,
    /// Its declaration's item in the syntax's tree, for a client's own diagnostics.
    item: u32,
};

pub const NounIterator = struct {
    checked: *const check.Checked,
    at: u32 = 0,

    /// The next noun, in the file's order, so a noun comes after every noun it names.
    pub fn next(iterator: *NounIterator) ?Noun {
        const checked = iterator.checked;
        while (iterator.at < checked.declarations.len) {
            const declaration = checked.declarations[iterator.at];
            iterator.at += 1;
            if (declaration != .noun) continue;
            return noun_of_checked(checked, declaration.noun.binding);
        }
        return null;
    }
};

/// The tokens and tree of one file, for formatting without checking. `entries` is the list its
/// `format_into` writes named arguments in: a back end's own table.
pub fn Syntax(comptime limits: FileLimits, comptime entries: []const schema.Entry) type {
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

        /// The three numbers of the track `name`, read from the tree alone, so a client finds
        /// them while another line has an error the checker would refuse. The first `track`
        /// line of that name, as the checker binds; null when there is none, when its bounds
        /// are not a range, or when the parse stopped short of the whole file.
        pub fn track_form(syntax: *const Self, name: []const u8) ?check.TrackForm {
            const tree = &syntax.tree;
            if (!tree.complete) return null;
            for (tree.declarations) |index| {
                const item = tree.item(index);
                if (item.tag != .track) continue;
                if (!std.mem.eql(u8, tree.token_text(item.token), name)) continue;
                return check.track_form(tree, index);
            }
            return null;
        }

        /// The parsed file in the canonical format, into `out`.
        pub fn format_into(syntax: *const Self, out: []u8) format.Error![]const u8 {
            assert(syntax.diagnostics.total() == 0);
            return format.format(&syntax.tree, entries, out);
        }
    };
}

/// A file parsed and checked, with no back end (section 1).
pub fn File(comptime limits: FileLimits, comptime vocabulary: schema.Vocabulary) type {
    return struct {
        const Self = @This();
        const Parsed = Syntax(limits, vocabulary.entries);

        syntax: Parsed,
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
        library_syntax: [limits.libraries]Parsed,
        library_list: [limits.libraries]check.Library,
        library_count: u32 = 0,
        /// The library that failed to parse; `errors` then lists its diagnostics.
        failed_library: ?u32 = null,
        instances: [limits.names]check.Instance,
        checked: check.Checked,

        /// Parses and checks `source`, which may `use` any of `libraries`, with a client's
        /// entries beside the vocabulary's, and builds nothing. On an error `errors` lists what
        /// was found; a library that does not parse is one, and `failed_library` names it.
        /// `checked` is valid, and `checked.ok` true, after a return.
        pub fn check_client(
            file: *Self,
            comptime clients: []const schema.Entry,
            libraries: []const Source,
            source: []const u8,
        ) error{Invalid}!void {
            return check_fields(limits, vocabulary, clients, file, libraries, source);
        }

        pub fn errors(file: *const Self) []const Diagnostic {
            return errors_of(limits, file);
        }

        /// The least limits this file checks with, as it checked just now; `errors` keeps
        /// `limits`' value, which the client chooses.
        pub fn needs(file: *const Self) FileLimits {
            assert(file.checked.ok);
            return needs_of(limits, file);
        }

        /// The name of the cue at `cue_index` in the cue table, null for an index past it.
        pub fn cue_name(file: *const Self, cue_index: u32) ?CueName {
            assert(file.checked.ok);
            return cue_name_of(&file.checked, cue_index);
        }

        /// What the declaration of the cue at `cue_index` is made of, null past the table.
        pub fn cue_form(file: *const Self, cue_index: u32) ?check.CueForm {
            assert(file.checked.ok);
            return cue_form_of(&file.checked, cue_index);
        }

        /// The three numbers of the track `name`, null for a name that is not a track.
        pub fn track_form(file: *const Self, name: []const u8) ?check.TrackForm {
            assert(file.checked.ok);
            return track_form_of(&file.checked, &file.syntax.tree, name);
        }

        /// The file's nouns, in its order.
        pub fn nouns(file: *const Self) NounIterator {
            assert(file.checked.ok);
            return .{ .checked = &file.checked };
        }

        /// The noun `binding_index` holds, which a `noun` value names.
        pub fn noun_of(file: *const Self, binding_index: u32) Noun {
            assert(file.checked.ok);
            return noun_of_checked(&file.checked, binding_index);
        }

        /// The noun bound to `name`.
        pub fn noun(file: *const Self, name: []const u8) ?Noun {
            assert(file.checked.ok);
            const index = binding_of(&file.checked, name, .noun) orelse return null;
            return noun_of_checked(&file.checked, index);
        }

        /// The index in the cue table of the cue `name`, null for a name that is not a cue.
        pub fn cue(file: *const Self, name: []const u8) ?u32 {
            assert(file.checked.ok);
            const index = binding_of(&file.checked, name, .cue) orelse return null;
            return file.checked.bindings[index].index;
        }

        /// The index in the track table of the track `name`, null for a name that is not one.
        pub fn track(file: *const Self, name: []const u8) ?u32 {
            assert(file.checked.ok);
            const index = binding_of(&file.checked, name, .track) orelse return null;
            return file.checked.bindings[index].index;
        }
    };
}

/// The index of the binding `name` of `kind`, null when there is none.
pub fn binding_of(checked: *const check.Checked, name: []const u8, kind: check.Binding.Kind) ?u32 {
    for (checked.bindings, 0..) |entry, index| {
        if (entry.kind == kind and std.mem.eql(u8, entry.name, name)) return @intCast(index);
    }
    return null;
}

/// The noun `binding_index` holds, from a file that checked.
pub fn noun_of_checked(checked: *const check.Checked, binding_index: u32) Noun {
    assert(checked.ok);
    const entry = checked.bindings[binding_index];
    assert(entry.kind == .noun);
    return .{
        .name = entry.name,
        .entry = entry.entry.?,
        .values = checked.call_values(entry.index),
        .binding = binding_index,
        .item = entry.item,
    };
}

/// The name of the cue at `cue_index` in the cue table (step 32): a noun's `cue` value, or an
/// event's from `cues(…)`. A cue of a series gives the series and its place in it. Null for an
/// index past the table.
pub fn cue_name_of(checked: *const check.Checked, cue_index: u32) ?CueName {
    assert(checked.ok);
    if (cue_index >= checked.cue_times.len) return null;
    for (checked.bindings) |each| {
        switch (each.kind) {
            .cue => if (each.index == cue_index) return .{ .name = each.name },
            .series => if (cue_index >= each.index and cue_index - each.index < each.count) {
                return .{ .name = each.name, .element = cue_index - each.index };
            },
            else => {},
        }
    }
    // Every cue in the table was added by a `cue` declaration that bound its name, and a file
    // that checked refused none.
    unreachable;
}

/// What the declaration of the cue at `cue_index` in the cue table is made of: a literal, an
/// earlier cue, or both; alone, an item of a list, or a cue of a series spaced `every` a step.
/// Null for an index past the table.
pub fn cue_form_of(checked: *const check.Checked, cue_index: u32) ?check.CueForm {
    assert(checked.ok);
    assert(checked.cue_forms.len == checked.cue_times.len);
    if (cue_index >= checked.cue_forms.len) return null;
    const form = checked.cue_forms[cue_index];
    if (form.written()) |time| switch (time) {
        .cue => |base| assert(base < cue_index),
        .after => |after| assert(after.base < cue_index),
        .literal => {},
    };
    return form;
}

/// The three numbers of the track `name`: each a plain literal's bytes, or what else it is. Null
/// for a name that is not a track.
pub fn track_form_of(
    checked: *const check.Checked,
    tree: *const parse.Tree,
    name: []const u8,
) ?check.TrackForm {
    assert(checked.ok);
    const index = binding_of(checked, name, .track) orelse return null;
    // The checker took its bounds as a range.
    const form = check.track_form(tree, checked.bindings[index].item).?;
    // The checker folded each, so none is a form it refuses.
    assert(form.value.kind != .other);
    assert(form.low.kind != .other);
    assert(form.high.kind != .other);
    return form;
}

/// The diagnostics of a failed parse or check: a library's own when one failed to parse.
pub fn errors_of(comptime limits: FileLimits, target: anytype) []const Diagnostic {
    if (comptime limits.libraries > 0) {
        if (target.failed_library) |at| return target.library_syntax[at].errors();
    }
    return target.syntax.errors();
}

/// The least `FileLimits` a file that checked needs, from `target`, a `File` or anything with
/// its fields. `errors` keeps `limits`', which the client chooses.
pub fn needs_of(comptime limits: FileLimits, target: anytype) FileLimits {
    const checked = &target.checked;
    assert(checked.ok);
    var result: FileLimits = .{
        .errors = limits.errors,
        .tokens = 0,
        .tree = 0,
        .names = 0,
        .cues = @intCast(checked.cue_times.len),
        .goals = @intCast(@max(checked.goals.len, checked.paths.len)),
        .regions = @intCast(@max(checked.regions.len, checked.region_runs.len)),
        .tracks = @intCast(checked.tracks.len),
        .modules = checked.module_count,
        .libraries = target.library_count,
    };
    // The checker's calls and expressions share `tree`, and its values take two a node.
    result.tree = @intCast(@max(@max(checked.calls.len, checked.exprs.len), (checked.values.len + 1) / 2));
    result.names = @intCast(@max(@max(checked.bindings.len, checked.declarations.len), checked.instances.len));
    // A library parses under the same limits as the file.
    var trees: [limits.libraries + 1]*const parse.Tree = undefined;
    trees[0] = &target.syntax.tree;
    for (target.library_syntax[0..target.library_count], 1..) |*syntax, at| trees[at] = &syntax.tree;
    for (trees[0 .. target.library_count + 1]) |tree| {
        result.tokens = @max(result.tokens, @as(u32, @intCast(tree.tokens.len)));
        result.tree = @max(result.tree, @as(u32, @intCast(@max(tree.items.len, tree.extra.len))));
        result.names = @max(result.names, @as(u32, @intCast(tree.declarations.len)));
    }
    return result;
}

/// Parses `source` and its `libraries` and checks it, into the fields of `target`, a `File` or a
/// back end's struct that holds the same ones (section 2). Sets `checked.ok`; nothing else of a
/// back end's.
pub fn check_fields(
    comptime limits: FileLimits,
    comptime vocabulary: schema.Vocabulary,
    comptime clients: []const schema.Entry,
    target: anytype,
    libraries: []const Source,
    source: []const u8,
) error{Invalid}!void {
    target.checked.ok = false;
    target.failed_library = null;
    assert(libraries.len <= limits.libraries);
    if (comptime limits.libraries > 0) {
        for (libraries, 0..) |library, at| {
            const syntax = &target.library_syntax[at];
            if (!syntax.parse_source(library.text) or !syntax.tree.complete) {
                target.failed_library = @intCast(at);
                return error.Invalid;
            }
            target.library_list[at] = .{ .name = library.name, .tree = &syntax.tree };
        }
    }
    target.library_count = @intCast(libraries.len);
    if (!target.syntax.parse_source(source) or !target.syntax.tree.complete) return error.Invalid;
    target.checked = check.check(vocabulary, clients, &target.syntax.tree, .{
        .modules = &target.modules,
        .frames = &target.frames,
        .libraries = target.library_list[0..libraries.len],
        .instances = &target.instances,
        .bindings = &target.bindings,
        .declarations = &target.checked_declarations,
        .calls = &target.calls,
        .values = &target.values,
        .value_items = &target.value_items,
        .exprs = &target.exprs,
        .cue_times = &target.checked_cue_times,
        .cue_forms = &target.checked_cue_forms,
        .goals = &target.checked_goals,
        .paths = &target.checked_paths,
        .regions = &target.checked_regions,
        .region_runs = &target.checked_runs,
        .tracks = &target.checked_tracks,
    }, &target.syntax.diagnostics);
    if (!target.checked.ok) return error.Invalid;
}
