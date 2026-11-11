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
//! `sample` reads each signal from a fresh reader at each time of the window, in order, and writes
//! its values as it goes, so a simulated program steps forwards and never seeks back, and a
//! signal of a thousand lanes needs no buffer. A reader cannot tell a fresh state from one that
//! read the other signals too, so the values are the ones one reader gives. Events in the window
//! come from one more fresh reader. A vector or a colour (step 16) has `"components"` and each
//! value is an array of them, OKLab for a colour; a signal of many lanes (step 17) has `"lanes"`
//! and each value is an array of its lanes. A number has none of these, so a file of numbers
//! samples as it did before vectors. Each event has its time in flicks, its source node, and its
//! instance, the lane, then the name bound to its source, where one is, and its value (step 18).
//!
//! ## 4. A Client's Command
//! `describe`, `check`, and `sample` take a client's entries (step 32), so a client with nouns
//! builds its own command on these functions; the `weft` command passes none, and its bytes do
//! not change. `check` counts the nouns on its `ok:` line when there are any. `sample` lists
//! signals only, as it skips cues and tracks: a noun is not a signal, and a signal a noun reads
//! inline has no name, so a file binds it on a line of its own to sample it, and naming a noun
//! says so. `check` stops after Weft's part: a client's own checks of its nouns run after the
//! compile, add their diagnostics to `compiled.syntax.diagnostics`, and are rendered by the
//! client. More libraries than `limits.libraries` is an error, not an assert.
//!
//! ## 5. TigerStyle Invariants
//! - No allocation: every buffer is a file-scope variable, sized by the constants below.
//! - Bounded: at most `samples_max` times, `signals_max` signals, and `events_max` events a run.

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

const flicks_per_second: f64 = @floatFromInt(weft.time.flicks_per_second);

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

var scratch: Syntax = undefined;
var ranges: [limits.nodes]weft.Range = undefined;
var events: [events_max]weft.Event = undefined;

/// `weft check`: the file's diagnostics, or a summary of its program. True when it compiles.
/// A client's command passes its entries as `clients` (section 4); the `weft` command none.
pub fn check(
    compiled: *Compiled,
    writer: *std.Io.Writer,
    source: Source,
    libraries: []const lang.Source,
    clients: []const schema.Entry,
) !bool {
    if (!try libraries_fit(writer, libraries)) return false;
    compiled.compile_client(clients, libraries, source.text) catch {
        try render_errors(compiled, writer, source, libraries);
        return false;
    };
    const program = compiled.program;
    const report = program.report();
    // The counts of step 18, then every field a client's `Limits` must hold.
    try writer.print("ok: {d} nodes, a slab of {d}, {d} cues, {d} goals, {d} regions, {d} tracks", .{
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
        if (comptime std.mem.eql(u8, name, "track_samples") or std.mem.eql(u8, name, "errors")) continue;
        try writer.print("{s} .{s} = {d}", .{ if (at == 0) "" else ",", name, @field(needs, name) });
    }
    try writer.writeAll(" }\n");
    const lane_cost = slab_per_lane(program);
    if (lane_cost > 0) try writer.print("a lane costs {d} of the slab\n", .{lane_cost});
    return true;
}

/// How many nouns the file declares (section 4).
fn nouns_of(compiled: *const Compiled) u32 {
    var count: u32 = 0;
    for (compiled.checked.declarations) |declaration| count += @intFromBool(declaration == .noun);
    return count;
}

/// Refuses more libraries than `limits` holds, which the library would otherwise assert on.
fn libraries_fit(writer: *std.Io.Writer, libraries: []const lang.Source) !bool {
    if (libraries.len <= limits.libraries) return true;
    try writer.print("error: at most {d} libraries, given {d}\n", .{ limits.libraries, libraries.len });
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

/// The diagnostics of a failed compile, against the text they are about: a library's own when
/// a library failed to parse.
fn render_errors(compiled: *const Compiled, writer: *std.Io.Writer, source: Source, libraries: []const lang.Source) !void {
    const failed: Source = if (compiled.failed_library) |at|
        .{ .name = libraries[at].name, .text = libraries[at].text }
    else
        source;
    for (compiled.errors()) |found| try found.render(failed.text, failed.name, writer);
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
        try writer.print(",\"kind\":\"{s}\",\"live\":{s},\"shaped\":{s},\"positional\":{s},\"default\":", .{
            @tagName(param.kind),
            if (param.live) "true" else "false",
            if (param.shaped) "true" else "false",
            if (param.positional) "true" else "false",
        });
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

/// `weft sample`: each named signal's range and its value at each time of `window`, then the
/// events in the window, as JSON (section 3). With no names, every top-level signal in text
/// order, up to `signals_max`. False, with a message, when the file or a name is wrong.
/// What `sample` keeps: the events of the sources bound to `events`, all when it is empty, and
/// lanes `lanes[0]` to `lanes[1]`, both included, all when it is null (step 22).
pub const Filter = struct {
    events: []const []const u8 = &.{},
    lanes: ?[2]u32 = null,
};

pub fn sample(
    gpa: std.mem.Allocator,
    compiled: *Compiled,
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
    assert(filter.events.len <= signals_max);
    if (filter.lanes) |lanes| assert(lanes[0] <= lanes[1]);
    if (!try libraries_fit(writer, libraries)) return false;
    compiled.compile_client(clients, libraries, source.text) catch {
        try render_errors(compiled, writer, source, libraries);
        return false;
    };
    var default_names: [signals_max][]const u8 = undefined;
    const list = if (names.len > 0) names else default_signals(compiled, &default_names);
    var ids: [signals_max]weft.Id = undefined;
    for (list, 0..) |name, at| {
        ids[at] = compiled.signal(name) orelse return not_a_signal(compiled, writer, name);
    }
    var event_ids: [signals_max]weft.Id = undefined;
    for (filter.events, 0..) |name, at| {
        event_ids[at] = compiled.signal(name) orelse return not_a_signal(compiled, writer, name);
    }
    const program = compiled.program;
    const slab = gpa.alloc(f64, @intCast(program.reader_slab_count())) catch {
        try writer.print("error: a slab of {d} values does not fit in memory\n", .{program.reader_slab_count()});
        return false;
    };
    defer gpa.free(slab);
    program.ranges(ranges[0..program.nodes.len]);
    const count = window.count();

    try writer.print("{{\"from\":{d},\"to\":{d},\"step\":{d},\"signals\":[", .{ window.from, window.to, window.step });
    for (list, ids[0..list.len], 0..) |name, id, at| {
        if (at > 0) try writer.writeAll(",");
        try writer.writeAll("{\"name\":");
        try json_string(writer, name);
        const extent = program.nodes[id.index].extent;
        const kept = kept_lanes(extent.lanes, filter.lanes);
        if (extent.lanes > 1) try writer.print(",\"lanes\":{d}", .{extent.lanes});
        if (extent.lanes > 1 and filter.lanes != null) try writer.print(",\"lane_first\":{d}", .{kept[0]});
        assert(kept[1] > kept[0] or (extent.lanes > 1 and filter.lanes != null));
        if (extent.components > 1) try writer.print(",\"components\":{d}", .{extent.components});
        const range = ranges[id.index];
        try writer.writeAll(",\"range\":[");
        try json_number(writer, range.low);
        try writer.writeAll(",");
        try json_number(writer, range.high);
        try writer.print("],\"bounded\":{},\"values\":[", .{std.math.isFinite(range.low) and std.math.isFinite(range.high)});
        // Each signal reads the window from a fresh state, which a read cannot tell apart from one
        // that read the others too, so no lane array needs keeping.
        var state = weft.State.init(program, slab);
        for (0..count) |index| {
            if (index > 0) try writer.writeAll(",");
            state.eval(.{ .flicks = window.from + @as(i64, @intCast(index)) * window.step });
            const read = state.values(id);
            if (extent.lanes > 1) try writer.writeAll("[");
            for (kept[0]..kept[1]) |lane| {
                if (lane > kept[0]) try writer.writeAll(",");
                try json_value(writer, read[lane * extent.components ..][0..extent.components]);
            }
            if (extent.lanes > 1) try writer.writeAll("]");
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("],\"events\":[");
    var state = weft.State.init(program, slab);
    const found = state.events(.{ .flicks = window.from }, .{ .flicks = window.to }, &events);
    var written: u32 = 0;
    for (events[0..found.count]) |event| {
        if (!event_kept(program, event, event_ids[0..filter.events.len], filter.lanes)) continue;
        if (written > 0) try writer.writeAll(",");
        written += 1;
        try writer.print("{{\"t\":{d},\"source\":{d},\"instance\":{d}", .{
            event.time.flicks,
            event.source.index,
            event.instance,
        });
        if (source_name(compiled, event.source)) |name| {
            try writer.writeAll(",\"name\":");
            try json_string(writer, name);
        }
        try writer.writeAll(",\"value\":");
        try json_number(writer, event.value);
        try writer.writeAll("}");
    }
    try writer.writeAll("]}\n");
    return true;
}

/// The refusal of a name `sample` cannot read. A noun's says what to do instead (section 4).
fn not_a_signal(compiled: *const Compiled, writer: *std.Io.Writer, name: []const u8) !bool {
    try writer.writeAll("error: ");
    try json_string(writer, name);
    if (compiled.noun(name)) |found| {
        try writer.print(" is a noun, `{s}`, not a signal; bind a signal it reads on a line of its own to sample it\n", .{found.entry.name});
        return false;
    }
    try writer.writeAll(" is not a signal of the file\n");
    return false;
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

/// Whether an event passes `--events` and `--lanes`, which only picks among a region's lanes.
fn event_kept(program: weft.Program, event: weft.Event, sources: []const weft.Id, lanes: ?[2]u32) bool {
    if (lanes) |range| {
        const laned = program.nodes[event.source.index].extent.lanes > 1;
        if (laned and (event.instance < range[0] or event.instance > range[1])) return false;
    }
    if (sources.len == 0) return true;
    for (sources) |source| if (source.index == event.source.index) return true;
    return false;
}

/// The name of the signal whose node fired an event, if a name is bound to it (step 18).
fn source_name(compiled: *const Compiled, source: weft.Id) ?[]const u8 {
    for (compiled.checked.bindings, 0..) |binding, index| {
        if (binding.kind != .signal) continue;
        if (compiled.ids[index].first.index == source.index) return binding.name;
    }
    return null;
}

/// The top-level signals of the file, in text order.
fn default_signals(compiled: *const Compiled, buffer: *[signals_max][]const u8) []const []const u8 {
    var count: usize = 0;
    for (compiled.checked.bindings) |binding| {
        if (binding.kind != .signal or count == signals_max) continue;
        buffer[count] = binding.name;
        count += 1;
    }
    return buffer[0..count];
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
