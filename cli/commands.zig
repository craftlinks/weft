//! The weft command's four commands, as functions that write to a writer (step 14). `main.zig`
//! reads the files and the arguments; the tests call these with the same bytes.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Thin Over the Library
//! Each command is a call into `weft.lang` and `weft.Program`, then JSON or diagnostics. No
//! command knows anything a window or a client could not reach through the library.
//!
//! ## 2. The Output Is the Contract
//! An agent reads these bytes, so they are locked by goldens (`test/golden/cli`). JSON is written
//! by hand: keys in a fixed order, no whitespace, numbers in Zig's shortest round-trip form, and
//! a number that is not finite (an unbounded range) as `null`, since JSON has no infinity.
//!
//! ## 3. Sampling
//! `sample` walks one fresh reader through the times of the window, in order, so a simulated
//! program steps forwards and never seeks back, and reads every named signal at each time
//! (step 38). The JSON is written signal by signal, so a walk keeps its signals' values in
//! `kept_values`, `values_max` f64 (512 KiB): its signals are taken in order, greedily, as many
//! as fit there, and the next walk takes the rest. A signal that alone does not fit, such as
//! a thousand lanes at a thousand times, has a walk of its own that writes its values as it
//! reads them and keeps none, as every signal did before step 38. So every request runs, most in
//! one walk, and the memory is bounded. A reader cannot tell a fresh state from one that read
//! other signals, so the values are the ones a reader of one signal gives, which makes the walk
//! a cache. The events are read along the first walk, in pieces: before the `eval` at each time,
//! those since the last, then after the walk the last piece, up to the window's end. In order
//! of time the pieces leave `events` as one query of the window would, and a stepped reader
//! goes forwards only, where a read of the events after an `eval` would replay from the start.
//! A file with no signal to sample reads its events on a reader of their own. A window that
//! starts late still steps from the start, as a fresh reader has no checkpoint.
//!
//! A vector or a colour (step 16) has `"components"` and each value is an array of them, OKLab
//! for a colour; a signal of many lanes (step 17) has `"lanes"` and each value is an array of its
//! lanes. A number has none of these, so a file of numbers samples as it did before vectors.
//! Each event has its time in flicks, its source node, and its instance, the lane, then the name
//! of the signal it belongs to, where one is, and its value (step 18).
//! With `--events`, the reader asks `events_of` for the nodes `Compiled.event_sources` gives each
//! name, merged (step 23), so the buffer holds only those sources' events, and a region's bounce
//! with no stagger or a vector's spring, whose binding's first node is a `spread` or a `pack`,
//! keeps its events. An event is named by the first signal in the file whose event sources hold
//! its source, so those events carry their binding's name too, with or without `--events`.
//!
//! ## 4. A Client's Command
//! `describe`, `check`, and `sample` take a client's entries (step 32), so a client with nouns
//! builds its own command on these functions; the `weft` command passes none, and its bytes do
//! not change. `check` counts the nouns on its `ok:` line when there are any. `sample` lists
//! signals only, as it skips cues and tracks: a noun is not a signal, and a signal a noun reads
//! inline has no name, so a file binds it on a line of its own to sample it, and naming a noun
//! says so. `check` stops after Weft's part: a client's own checks of its nouns run after the
//! compile, add their diagnostics to `compiled.syntax.diagnostics`, and are rendered by the
//! client.
//!
//! A client compiles into its own `lang.Compiled(its limits)`, so `For(client_limits)` (step 37)
//! holds `check`, `summary`, `sample`, and `sample_compiled` for that type, with the buffers its
//! limits size; this file's `check` and the rest are `For(limits)`'s, so the `weft` command is
//! the same code at the same sizes. A client with checks of its own has compiled already, so it
//! calls `summary` for `check`'s lines and `sample_compiled` for `sample`'s JSON on the
//! `Compiled` it holds, which compiles each file once, at the client's limits: a full array is
//! an error naming the client's number, and a field larger than the command's holds. More
//! libraries than the client's `libraries` is an error, not an assert. `sample_compiled` reads
//! the tables as the `Compiled` holds them, a track's writes included.
//!
//! ## 5. TigerStyle Invariants
//! - No allocation: every buffer is a file-scope variable, sized by the constants below, or one
//!   of a `For`, sized by its client's `nodes`.
//! - Bounded: at most `samples_max` times, `signals_max` signals, and `events_max` events a run,
//!   and at most `signals_max` walks of the window, one a signal when no two fit together.

const std = @import("std");
const assert = std.debug.assert;
const weft = @import("weft");
const lang = weft.lang;
const schema = lang.schema;

pub const limits: lang.Limits = .{
    .tokens = 16384,
    .tree = 16384,
    .names = 512,
    .nodes = 1024,
    // Only a number the builder compares against, never an array: `sample` allocates the slab.
    .slab = std.math.maxInt(u32),
    .cues = 512,
    .goals = 256,
    .regions = 64,
    .tracks = 16,
    .track_samples = 1024,
    .modules = 64,
    .libraries = 2,
};

pub const Compiled = lang.Compiled(limits);
pub const Syntax = lang.Syntax(limits);

pub const samples_max = 1024;
pub const events_max = 1024;
pub const signals_max = 16;
/// The values, as f64, that one walk of `sample` keeps: every signal at every time with
/// `components_max` values each, 512 KiB (section 3).
pub const values_max = signals_max * samples_max * weft.graph.components_max;

const flicks_per_second: f64 = @floatFromInt(weft.time.flicks_per_second);

comptime {
    // A walk keeps every signal at every time when each has four values or fewer, a vector, a
    // colour, or four lanes, and the buffer stays 512 KiB of a client's static memory.
    assert(values_max == signals_max * samples_max * weft.graph.components_max);
    assert(values_max * @sizeOf(f64) == 512 << 10);
    assert(events_max <= std.math.maxInt(u32));
}

/// A file's text and the name its diagnostics give it.
pub const Source = struct { name: []const u8, text: []const u8 };

/// A window of times, in flicks: `from`, then every `step`, up to `to`.
pub const Window = struct {
    from: i64,
    to: i64,
    step: i64,

    /// A window the sampler can run: a positive step, an end at or after the start, and no more
    /// than `samples_max` times.
    pub fn valid(window: Window) bool {
        if (window.step <= 0 or window.to < window.from) return false;
        return @divFloor(window.to - window.from, window.step) < samples_max;
    }

    pub fn count(window: Window) usize {
        assert(window.valid());
        return @intCast(@divFloor(window.to - window.from, window.step) + 1);
    }
};

/// What `describe` and `parse` parse into: they take no `Compiled`, so Weft's own limits.
var scratch: Syntax = undefined;
/// The window's events, and the values one walk keeps (section 3). Neither depends on a
/// client's limits, so every `For` shares them: a command makes one call at a time.
var events: [events_max]weft.Event = undefined;
var kept_values: [values_max]f64 = undefined;

/// `check`, `summary`, `sample`, and `sample_compiled` on a client's own
/// `lang.Compiled(client_limits)` (section 4), with the buffers its limits size. The `weft`
/// command's are `For(limits)`'s, which this file exports as `check`, `summary`, `sample`, and
/// `sample_compiled`.
pub fn For(comptime client_limits: lang.Limits) type {
    comptime {
        assert(client_limits.nodes >= 1);
        assert(client_limits.nodes <= std.math.maxInt(u32));
    }
    return struct {
        /// The client's own `Compiled`, the type it already holds: `lang.Compiled(client_limits)`.
        const ClientCompiled = lang.Compiled(client_limits);
        // The names this file exports for `For(limits)` are its own too, so calls within it
        // say which they mean.
        const Self = @This();

        /// Each node's range, for the heads of `sample`'s signals.
        var ranges: [client_limits.nodes]weft.Range = undefined;
        /// The name each node's events print with, by `name_sources` (section 3).
        var source_names: [client_limits.nodes]?[]const u8 = undefined;

        /// `weft check`: the file's diagnostics, or its `summary`. True when it compiles. A
        /// client's command passes its entries as `clients` (section 4); the `weft` command none.
        pub fn check(
            compiled: *ClientCompiled,
            writer: *std.Io.Writer,
            source: Source,
            libraries: []const lang.Source,
            clients: []const schema.Entry,
        ) !bool {
            if (!try libraries_fit(writer, libraries, client_limits.libraries)) return false;
            compiled.compile_client(clients, libraries, source.text) catch {
                try render_errors(compiled, writer, source, libraries);
                return false;
            };
            try Self.summary(compiled, writer);
            return true;
        }

        /// What `check` prints of a file that compiled: the `ok:` line, the least `Limits`, and
        /// what a lane costs, from a `Compiled` the client already holds, so a client with checks
        /// of its own compiles once (section 4).
        pub fn summary(compiled: *const ClientCompiled, writer: *std.Io.Writer) !void {
            assert(compiled.ok);
            const program = compiled.program;
            assert(program.nodes.len <= client_limits.nodes);
            const report = program.report();
            // The counts of step 18, then every field a client's `Limits` must hold.
            const counts = "ok: {d} nodes, a slab of {d}, {d} cues, {d} goals, {d} regions, {d} tracks";
            try writer.print(counts, .{
                program.nodes.len,
                program.slab_count,
                compiled.checked.cue_times.len,
                compiled.checked.goals.len,
                compiled.checked.regions.len,
                compiled.checked.tracks.len,
            });
            const noun_count = nouns_of(compiled);
            if (noun_count > 0) try writer.print(", {d} nouns", .{noun_count});
            try writer.print(", {s}, {s}\n", .{
                if (report.seekable) "seekable" else "live",
                if (report.stepped) "stepped" else "closed form",
            });
            // The least `Limits` the file compiles with, to paste (step 22).
            const needs = compiled.needs();
            try writer.writeAll("limits: .{");
            inline for (@typeInfo(lang.Limits).@"struct".field_names, 0..) |name, at| {
                const chosen = comptime std.mem.eql(u8, name, "track_samples") or
                    std.mem.eql(u8, name, "errors");
                if (chosen) continue;
                const comma = if (at == 0) "" else ",";
                try writer.print("{s} .{s} = {d}", .{ comma, name, @field(needs, name) });
            }
            try writer.writeAll(" }\n");
            const lane_cost = slab_per_lane(program);
            if (lane_cost > 0) try writer.print("a lane costs {d} of the slab\n", .{lane_cost});
        }

        /// How many nouns the file declares (section 4).
        fn nouns_of(compiled: *const ClientCompiled) u32 {
            var count: u32 = 0;
            for (compiled.checked.declarations) |declaration| {
                count += @intFromBool(declaration == .noun);
            }
            assert(count <= compiled.checked.declarations.len);
            return count;
        }

        /// The diagnostics of a failed compile, against the text they are about: a library's own
        /// when a library failed to parse.
        fn render_errors(
            compiled: *const ClientCompiled,
            writer: *std.Io.Writer,
            source: Source,
            libraries: []const lang.Source,
        ) !void {
            const failed: Source = if (compiled.failed_library) |at|
                .{ .name = libraries[at].name, .text = libraries[at].text }
            else
                source;
            for (compiled.errors()) |found| try found.render(failed.text, failed.name, writer);
        }

        /// `weft sample`: each named signal's range and its value at each time of `window`,
        /// then the events in the window, as JSON (section 3), after compiling `source` with the
        /// client's entries. False, with a message, when the file or a name is wrong.
        pub fn sample(
            gpa: std.mem.Allocator,
            compiled: *ClientCompiled,
            writer: *std.Io.Writer,
            source: Source,
            libraries: []const lang.Source,
            clients: []const schema.Entry,
            names: []const []const u8,
            window: Window,
            filter: Filter,
        ) !bool {
            assert(window.valid());
            assert(names.len <= signals_max);
            if (!try libraries_fit(writer, libraries, client_limits.libraries)) return false;
            compiled.compile_client(clients, libraries, source.text) catch {
                try render_errors(compiled, writer, source, libraries);
                return false;
            };
            return Self.sample_compiled(gpa, compiled, writer, names, window, filter);
        }

        /// `sample` of a `Compiled` the client already holds, compiled with its entries, so a
        /// client with checks of its own compiles once (section 4). With no names, every
        /// top-level signal in text order, up to `signals_max`. False, with a message, when a
        /// name is wrong or the slab does not fit in memory.
        pub fn sample_compiled(
            gpa: std.mem.Allocator,
            compiled: *const ClientCompiled,
            writer: *std.Io.Writer,
            names: []const []const u8,
            window: Window,
            filter: Filter,
        ) !bool {
            assert(compiled.ok);
            assert(window.valid());
            assert(names.len <= signals_max);
            assert(filter.events.len <= signals_max);
            if (filter.lanes) |lanes| assert(lanes[0] <= lanes[1]);
            var default_names: [signals_max][]const u8 = undefined;
            const list = if (names.len > 0) names else default_signals(compiled, &default_names);
            var ids: [signals_max]weft.Id = undefined;
            for (list, 0..) |name, at| {
                ids[at] = compiled.signal(name) orelse return not_a_signal(compiled, writer, name);
            }
            // The nodes that fire the named signals' events, merged, ascending, for `events_of`.
            var event_ids: [signals_max * weft.graph.components_max]weft.Id = undefined;
            var event_count: usize = 0;
            for (filter.events) |name| {
                if (compiled.signal(name) == null) return not_a_signal(compiled, writer, name);
                var found: [weft.graph.components_max]weft.Id = undefined;
                for (compiled.event_sources(name, &found)) |id| {
                    event_count = insert_source(event_ids[0 .. event_count + 1], event_count, id);
                }
            }
            const program = compiled.program;
            assert(program.nodes.len <= client_limits.nodes);
            const slab_count = program.reader_slab_count();
            const slab = gpa.alloc(f64, @intCast(slab_count)) catch {
                const refusal = "error: a slab of {d} values does not fit in memory\n";
                try writer.print(refusal, .{slab_count});
                return false;
            };
            defer gpa.free(slab);
            program.ranges(ranges[0..program.nodes.len]);
            var reads: [signals_max]Read = undefined;
            for (ids[0..list.len], reads[0..list.len]) |id, *read| {
                const extent = program.nodes[id.index].extent;
                read.* = .{
                    .id = id,
                    .lanes = extent.lanes,
                    .kept = kept_lanes(extent.lanes, filter.lanes),
                    .components = extent.components,
                    .range = ranges[id.index],
                };
            }
            var gather: Gather = .{
                .sources = if (filter.events.len == 0) null else event_ids[0..event_count],
                .read = window.from,
                .found = 0,
            };
            const head = "{{\"from\":{d},\"to\":{d},\"step\":{d},\"signals\":[";
            try writer.print(head, .{ window.from, window.to, window.step });
            const lanes = filter.lanes;
            try write_signals(writer, program, slab, list, reads[0..list.len], window, lanes, &gather);
            assert(gather.read == window.to);
            try writer.writeAll("],\"events\":[");
            name_sources(compiled);
            const names_of_sources = source_names[0..program.nodes.len];
            try write_events(writer, program, events[0..gather.found], names_of_sources, lanes);
            try writer.writeAll("]}\n");
            return true;
        }

        /// The refusal of a name `sample` cannot read. A noun's says what to do instead
        /// (section 4).
        fn not_a_signal(
            compiled: *const ClientCompiled,
            writer: *std.Io.Writer,
            name: []const u8,
        ) !bool {
            try writer.writeAll("error: ");
            try json_string(writer, name);
            if (compiled.noun(name)) |found| {
                const instead = " is a noun, `{s}`, not a signal; bind a signal it reads on a line" ++
                    " of its own to sample it\n";
                try writer.print(instead, .{found.entry.name});
                return false;
            }
            try writer.writeAll(" is not a signal of the file\n");
            return false;
        }

        /// Names each node that fires events by the first signal, in the file's order, whose
        /// `Compiled.event_sources` hold it (step 23), so a region's bounce with no stagger and a
        /// vector's spring print their binding's name. The first declared wins where two share a
        /// source, as `b = a` shares `a`'s: it is the name the source was made under.
        fn name_sources(compiled: *const ClientCompiled) void {
            const count = compiled.program.nodes.len;
            assert(count <= client_limits.nodes);
            @memset(source_names[0..count], null);
            for (compiled.checked.bindings) |binding| {
                if (binding.kind != .signal) continue;
                var found: [weft.graph.components_max]weft.Id = undefined;
                for (compiled.event_sources(binding.name, &found)) |id| {
                    if (source_names[id.index] == null) source_names[id.index] = binding.name;
                }
            }
        }

        /// The top-level signals of the file, in text order.
        fn default_signals(
            compiled: *const ClientCompiled,
            buffer: *[signals_max][]const u8,
        ) []const []const u8 {
            var count: usize = 0;
            for (compiled.checked.bindings) |binding| {
                if (binding.kind != .signal or count == signals_max) continue;
                buffer[count] = binding.name;
                count += 1;
            }
            return buffer[0..count];
        }
    };
}

const weft_command = For(limits);
pub const check = weft_command.check;
pub const summary = weft_command.summary;
pub const sample = weft_command.sample;
pub const sample_compiled = weft_command.sample_compiled;

/// Refuses more libraries than `libraries_max`, a client's `Limits.libraries`, which the library
/// would otherwise assert on. The error names the client's number.
fn libraries_fit(writer: *std.Io.Writer, libraries: []const lang.Source, libraries_max: u32) !bool {
    if (libraries.len <= libraries_max) return true;
    assert(libraries.len > libraries_max);
    const refusal = "error: at most {d} libraries, given {d}\n";
    try writer.print(refusal, .{ libraries_max, libraries.len });
    return false;
}

/// The f64 each lane of a region adds to the slab: each node of more than one lane's values and
/// caches over its lanes, rounded up, summed. 0 for a file with no region.
fn slab_per_lane(program: weft.Program) u64 {
    var total: u64 = 0;
    for (program.nodes) |node| {
        if (node.extent.lanes <= 1) continue;
        const region = node.extent.count() + node.op.cache_count(node.extent.count());
        total += (region + node.extent.lanes - 1) / node.extent.lanes;
    }
    return total;
}

/// `weft describe`: the primitives, the modules of each library, and a client's nouns, as JSON.
pub fn describe(writer: *std.Io.Writer, libraries: []const lang.Source, nouns: []const schema.Entry) !void {
    try writer.writeAll("{\"primitives\":[");
    for (&schema.entries, 0..) |*entry, at| {
        if (at > 0) try writer.writeAll(",");
        try json_entry(writer, entry);
    }
    try writer.writeAll("],\"modules\":[");
    var first = true;
    for (libraries) |library| {
        if (!scratch.parse_source(library.text)) return error.LibraryInvalid;
        const tree = &scratch.tree;
        for (tree.declarations) |index| {
            const item = tree.item(index);
            if (item.tag != .module) continue;
            if (!first) try writer.writeAll(",");
            first = false;
            try writer.writeAll("{\"name\":");
            try json_string(writer, tree.text(index));
            try writer.writeAll(",\"library\":");
            try json_string(writer, library.name);
            try writer.writeAll(",\"params\":[");
            for (tree.children(item.a), 0..) |param, position| {
                if (position > 0) try writer.writeAll(",");
                const default = tree.item(param).a;
                try writer.writeAll("{\"name\":");
                try json_string(writer, tree.text(param));
                try writer.writeAll(",\"default\":");
                if (default == 0) try writer.writeAll("null") else try json_string(writer, source_of(tree, default - 1));
                try writer.writeAll("}");
            }
            try writer.writeAll("],\"range\":");
            if (item.c == 0) try writer.writeAll("null") else try json_string(writer, source_of(tree, item.c - 1));
            try writer.writeAll(",\"body\":");
            try json_string(writer, source_of(tree, item.b));
            try writer.writeAll("}");
        }
    }
    try writer.writeAll("],\"nouns\":[");
    for (nouns, 0..) |*entry, at| {
        if (at > 0) try writer.writeAll(",");
        try json_entry(writer, entry);
    }
    try writer.writeAll("]}\n");
}

/// The text an item covers, as written.
fn source_of(tree: *const lang.parse.Tree, index: u32) []const u8 {
    const item = tree.item(index);
    const first = tree.tokens[item.first];
    const last = tree.tokens[item.last];
    return tree.source[first.start .. last.start + last.len];
}

fn json_entry(writer: *std.Io.Writer, entry: *const schema.Entry) !void {
    try writer.writeAll("{\"name\":");
    try json_string(writer, entry.name);
    try writer.print(",\"role\":\"{s}\",\"op\":\"{s}\",\"summary\":", .{ @tagName(entry.role), @tagName(entry.op) });
    try json_string(writer, entry.summary);
    // How it takes lanes, and what its events carry (step 22).
    try writer.print(",\"lanes\":\"{s}\",\"events\":", .{@tagName(entry.lane_rule())});
    if (entry.event_value()) |value| try json_string(writer, value) else try writer.writeAll("null");
    try writer.writeAll(",\"outputs\":[");
    for (entry.outputs, 0..) |output, index| {
        if (index > 0) try writer.writeAll(",");
        try json_string(writer, output);
    }
    try writer.writeAll("],\"params\":[");
    for (entry.params, 0..) |param, at| {
        if (at > 0) try writer.writeAll(",");
        try writer.writeAll("{\"name\":");
        try json_string(writer, param.name);
        try writer.print(",\"kind\":\"{s}\",\"live\":{s},\"shaped\":{s},\"positional\":{s}", .{
            @tagName(param.kind),
            if (param.live) "true" else "false",
            if (param.shaped) "true" else "false",
            if (param.positional) "true" else "false",
        });
        // Only where it is true, the `at` of `tween` and `bounce` (step 28), so no other line moves.
        if (param.by_lane) try writer.writeAll(",\"by_lane\":true");
        try writer.writeAll(",\"default\":");
        switch (param.default) {
            .required => try writer.writeAll("null"),
            .number => |number| try json_number(writer, number),
            .time => |flicks| try json_number(writer, @as(f64, @floatFromInt(flicks)) / flicks_per_second),
            .word => |word| try json_string(writer, param.words[word]),
            .time_range => |range| {
                try writer.writeAll("[");
                try json_number(writer, @as(f64, @floatFromInt(range[0])) / flicks_per_second);
                try writer.writeAll(",");
                try json_number(writer, @as(f64, @floatFromInt(range[1])) / flicks_per_second);
                try writer.writeAll("]");
            },
            .absent, .unbounded, .seed, .whole, .after => try json_string(writer, @tagName(param.default)),
            .text => |text| try json_string(writer, text),
        }
        try writer.writeAll(",\"words\":[");
        for (param.words, 0..) |word, index| {
            if (index > 0) try writer.writeAll(",");
            try json_string(writer, word);
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("]}");
}

/// `weft parse --json`: the flat tree, one item at a time, with the children of a call or list.
pub fn parse(writer: *std.Io.Writer, source: Source) !bool {
    if (!scratch.parse_source(source.text)) {
        for (scratch.errors()) |found| try found.render(source.text, source.name, writer);
        return false;
    }
    const tree = &scratch.tree;
    try writer.writeAll("{\"items\":[");
    for (tree.items, 0..) |item, at| {
        const index: u32 = @intCast(at);
        if (at > 0) try writer.writeAll(",");
        try writer.print("{{\"index\":{d},\"tag\":\"{s}\",\"text\":", .{ at, @tagName(item.tag) });
        try json_string(writer, tree.text(index));
        try writer.print(",\"a\":{d},\"b\":{d},\"c\":{d},\"children\":[", .{ item.a, item.b, item.c });
        if (item.tag == .call or item.tag == .list) {
            for (tree.children(index), 0..) |child, position| {
                if (position > 0) try writer.writeAll(",");
                try writer.print("{d}", .{child});
            }
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("],\"declarations\":[");
    for (tree.declarations, 0..) |declaration, at| {
        if (at > 0) try writer.writeAll(",");
        try writer.print("{d}", .{declaration});
    }
    try writer.writeAll("]}\n");
    return true;
}

/// What `sample` keeps: the events of the sources bound to `events`, all when it is empty, and
/// lanes `lanes[0]` to `lanes[1]`, both included, all when it is null (step 22).
pub const Filter = struct {
    events: []const []const u8 = &.{},
    lanes: ?[2]u32 = null,
};

/// Every signal of `reads`, in its walks (section 3), the first of which reads the events into
/// `gather`; with no signal, the events on a reader of their own.
fn write_signals(
    writer: *std.Io.Writer,
    program: weft.Program,
    slab: []f64,
    names: []const []const u8,
    reads: []const Read,
    window: Window,
    lanes: ?[2]u32,
    gather: *Gather,
) !void {
    assert(names.len == reads.len);
    assert(gather.read == window.from);
    var at: usize = 0;
    while (at < reads.len) {
        // Each walk is a fresh reader from the window's start, and the first reads the events.
        var state = weft.State.init(program, slab);
        const first: ?*Gather = if (at == 0) gather else null;
        const end = batch_end(reads, at, window.count());
        if (end == at) {
            try write_head(writer, names[at], reads[at], lanes, at > 0);
            try walk_streamed(writer, reads[at], window, first, &state);
            at += 1;
        } else {
            walk_kept(reads[at..end], window, first, &state);
            try write_kept(writer, names[at..end], reads[at..end], window, lanes, at > 0);
            at = end;
        }
        if (first) |events_reader| events_reader.read_to(&state, window.to);
    }
    assert(at == reads.len);
    if (reads.len == 0) {
        var state = weft.State.init(program, slab);
        gather.read_to(&state, window.to);
    }
    assert(gather.read == window.to);
}

/// What a walk reads of one signal: its node, its lanes, the lanes it prints as `[first, end)`,
/// and the components of each lane.
const Read = struct {
    id: weft.Id,
    lanes: u32,
    kept: [2]u32,
    components: u32,
    /// The node's range, which the signal's head prints.
    range: weft.Range,

    /// The values one time of the signal keeps.
    fn size(read: Read) u64 {
        assert(read.kept[0] <= read.kept[1]);
        assert(read.components >= 1 and read.components <= weft.graph.components_max);
        return @as(u64, read.kept[1] - read.kept[0]) * read.components;
    }

    /// The values it prints of a read of its node, lane after lane and each lane's components.
    fn kept_of(read: Read, values: []const f64) []const f64 {
        assert(values.len == @as(u64, read.lanes) * read.components);
        assert(read.kept[1] <= read.lanes);
        return values[read.kept[0] * read.components .. read.kept[1] * read.components];
    }
};

/// The window's events, read along the first walk in pieces (section 3): before the `eval` at
/// each time t, the events of `[read, t)`, so a simulated reader only steps forwards, and after
/// the walk the last piece, up to `to`. The pieces are in order of time, so `events` ends up as
/// one query of the window would leave it: the earliest `events_max`, in the same order.
const Gather = struct {
    /// The sources `--events` keeps, or null for every source.
    sources: ?[]const weft.Id,
    /// The events of `[window.from, read)` are in `events[0..found]`.
    read: i64,
    found: u32,

    fn read_to(gather: *Gather, state: *weft.State, to: i64) void {
        assert(to >= gather.read);
        assert(gather.found <= events_max);
        defer gather.read = to;
        if (to == gather.read) return;
        // Full: every later event would only be counted, and `sample` prints the kept ones only.
        if (gather.found == events_max) return;
        const out = events[gather.found..];
        const t0: weft.Time = .{ .flicks = gather.read };
        const t1: weft.Time = .{ .flicks = to };
        const found = if (gather.sources) |list|
            state.events_of(list, t0, t1, out)
        else
            state.events(t0, t1, out);
        assert(found.count <= out.len);
        gather.found += found.count;
    }
};

/// The time of the window at `index`.
fn window_time(window: Window, index: usize) i64 {
    assert(index < window.count());
    const time = window.from + @as(i64, @intCast(index)) * window.step;
    assert(time <= window.to);
    return time;
}

/// The end of the batch of `reads` from `at` whose values fit in `kept_values` at `count` times,
/// taken greedily in order, or `at` when the read at `at` alone does not fit, which then streams.
fn batch_end(reads: []const Read, at: usize, count: usize) usize {
    assert(at < reads.len);
    assert(count >= 1 and count <= samples_max);
    var size: u64 = 0;
    var end = at;
    while (end < reads.len) : (end += 1) {
        const more = reads[end].size() * count;
        if (size + more > values_max) break;
        size += more;
    }
    assert(size <= values_max);
    return end;
}

/// One walk of a fresh reader over the window that keeps the values of `reads` at each time,
/// each signal's run of `kept_values` after the one before, time after time within it.
fn walk_kept(reads: []const Read, window: Window, gather: ?*Gather, state: *weft.State) void {
    assert(reads.len >= 1);
    const count = window.count();
    for (0..count) |index| {
        const time = window_time(window, index);
        // The events before the time first: an `eval` there would leave them behind the reader.
        if (gather) |events_reader| events_reader.read_to(state, time);
        state.eval(.{ .flicks = time });
        var base: u64 = 0;
        for (reads) |read| {
            const size = read.size();
            const into = kept_values[@intCast(base + index * size)..][0..@intCast(size)];
            @memcpy(into, read.kept_of(state.values(read.id)));
            base += size * count;
        }
        assert(base <= values_max);
    }
}

/// The signals a `walk_kept` read, one after another, from `kept_values`.
fn write_kept(
    writer: *std.Io.Writer,
    names: []const []const u8,
    reads: []const Read,
    window: Window,
    lanes: ?[2]u32,
    after_another: bool,
) !void {
    assert(names.len == reads.len);
    const count = window.count();
    var base: u64 = 0;
    for (names, reads, 0..) |name, read, at| {
        try write_head(writer, name, read, lanes, after_another or at > 0);
        const size = read.size();
        for (0..count) |index| {
            if (index > 0) try writer.writeAll(",");
            const values = kept_values[@intCast(base + index * size)..][0..@intCast(size)];
            try write_time(writer, read, values);
        }
        try writer.writeAll("]}");
        base += size * count;
    }
    assert(base <= values_max);
}

/// One walk of a fresh reader over the window for a signal too large for `kept_values`, writing
/// each time's values as it reads them, so it needs no buffer at all.
fn walk_streamed(
    writer: *std.Io.Writer,
    read: Read,
    window: Window,
    gather: ?*Gather,
    state: *weft.State,
) !void {
    const count = window.count();
    assert(read.size() * count > values_max);
    for (0..count) |index| {
        const time = window_time(window, index);
        if (gather) |events_reader| events_reader.read_to(state, time);
        state.eval(.{ .flicks = time });
        if (index > 0) try writer.writeAll(",");
        try write_time(writer, read, read.kept_of(state.values(read.id)));
    }
    try writer.writeAll("]}");
}

/// A signal's name, lanes, components, and range, up to the opening of its values.
fn write_head(
    writer: *std.Io.Writer,
    name: []const u8,
    read: Read,
    lanes: ?[2]u32,
    after_another: bool,
) !void {
    assert(read.kept[1] > read.kept[0] or (read.lanes > 1 and lanes != null));
    if (after_another) try writer.writeAll(",");
    try writer.writeAll("{\"name\":");
    try json_string(writer, name);
    if (read.lanes > 1) try writer.print(",\"lanes\":{d}", .{read.lanes});
    if (read.lanes > 1 and lanes != null) try writer.print(",\"lane_first\":{d}", .{read.kept[0]});
    if (read.components > 1) try writer.print(",\"components\":{d}", .{read.components});
    const range = read.range;
    try writer.writeAll(",\"range\":[");
    try json_number(writer, range.low);
    try writer.writeAll(",");
    try json_number(writer, range.high);
    try writer.print("],\"bounded\":{},\"values\":[", .{std.math.isFinite(range.low) and std.math.isFinite(range.high)});
}

/// One time of a signal: its kept lanes, an array of them when the node has more than one.
fn write_time(writer: *std.Io.Writer, read: Read, values: []const f64) !void {
    assert(values.len == read.size());
    const components: usize = read.components;
    if (read.lanes > 1) try writer.writeAll("[");
    var lane: usize = 0;
    while (lane * components < values.len) : (lane += 1) {
        if (lane > 0) try writer.writeAll(",");
        try json_value(writer, values[lane * components ..][0..components]);
    }
    if (read.lanes > 1) try writer.writeAll("]");
}

/// The events kept, each with the name of its source where it has one, from `names`, a name or
/// null for each node (section 3).
fn write_events(
    writer: *std.Io.Writer,
    program: weft.Program,
    found: []const weft.Event,
    names: []const ?[]const u8,
    lanes: ?[2]u32,
) !void {
    assert(found.len <= events_max);
    assert(names.len == program.nodes.len);
    var written: u32 = 0;
    for (found) |event| {
        assert(event.source.index < program.nodes.len);
        if (!event_kept(program, event, lanes)) continue;
        if (written > 0) try writer.writeAll(",");
        written += 1;
        try writer.print("{{\"t\":{d},\"source\":{d},\"instance\":{d}", .{
            event.time.flicks,
            event.source.index,
            event.instance,
        });
        if (names[event.source.index]) |name| {
            try writer.writeAll(",\"name\":");
            try json_string(writer, name);
        }
        try writer.writeAll(",\"value\":");
        try json_number(writer, event.value);
        try writer.writeAll("}");
    }
    assert(written <= found.len);
}

/// The lanes of a node of `lanes` that `sample` prints, as `[first, end)`. `--lanes` picks among
/// the lanes of a region, so a node of one lane keeps it.
fn kept_lanes(lanes: u32, wanted: ?[2]u32) [2]u32 {
    if (lanes == 1) return .{ 0, 1 };
    const range = wanted orelse return .{ 0, lanes };
    const first = @min(range[0], lanes);
    const end = @min(range[1] + 1, lanes);
    return .{ first, @max(first, end) };
}

/// Whether an event passes `--lanes`, which only picks among a region's lanes. `--events` is
/// applied by `events_of`.
fn event_kept(program: weft.Program, event: weft.Event, lanes: ?[2]u32) bool {
    const range = lanes orelse return true;
    const laned = program.nodes[event.source.index].extent.lanes > 1;
    return !laned or (event.instance >= range[0] and event.instance <= range[1]);
}

/// Puts `id` into the ascending `sources[0..count]` unless it is there, and returns the new count.
/// `sources` has room for one more.
fn insert_source(sources: []weft.Id, count: usize, id: weft.Id) usize {
    assert(sources.len == count + 1);
    var at = count;
    while (at > 0 and sources[at - 1].index > id.index) : (at -= 1) {}
    if (at > 0 and sources[at - 1].index == id.index) return count;
    std.mem.copyBackwards(weft.Id, sources[at + 1 ..], sources[at..count]);
    sources[at] = id;
    return count + 1;
}

/// One lane's value: a number, or an array of its components.
fn json_value(writer: *std.Io.Writer, components: []const f64) !void {
    assert(components.len >= 1 and components.len <= weft.graph.components_max);
    if (components.len == 1) return json_number(writer, components[0]);
    try writer.writeAll("[");
    for (components, 0..) |component, k| {
        if (k > 0) try writer.writeAll(",");
        try json_number(writer, component);
    }
    try writer.writeAll("]");
}

/// A JSON number, or `null` for an infinity or NaN (section 2).
fn json_number(writer: *std.Io.Writer, value: f64) !void {
    if (std.math.isFinite(value)) try writer.print("{d}", .{value}) else try writer.writeAll("null");
}

/// A JSON string: quotes, backslashes, and control bytes escaped.
pub fn json_string(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeAll("\"");
    for (text) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11...31 => try writer.print("\\u{x:0>4}", .{byte}),
        else => try writer.writeByte(byte),
    };
    try writer.writeAll("\"");
}
