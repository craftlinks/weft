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
//! samples as it did before vectors.
//!
//! ## 4. TigerStyle Invariants
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
    .slab = 1 << 18,
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
var slab: [limits.slab]f64 = undefined;
var ranges: [limits.nodes]weft.Range = undefined;
var events: [events_max]weft.Event = undefined;

/// `weft check`: the file's diagnostics, or a summary of its program. True when it compiles.
pub fn check(compiled: *Compiled, writer: *std.Io.Writer, source: Source, libraries: []const lang.Source) !bool {
    compiled.compile_with(libraries, source.text) catch {
        try render_errors(compiled, writer, source, libraries);
        return false;
    };
    const program = compiled.program;
    const report = program.report();
    try writer.print("ok: {d} nodes, {d} cues, {d} tracks, {s}, {s}\n", .{
        program.nodes.len,
        compiled.checked.cue_times.len,
        compiled.checked.tracks.len,
        if (report.seekable) "seekable" else "live",
        if (report.stepped) "stepped" else "closed form",
    });
    return true;
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
            .absent, .unbounded, .seed, .whole => try json_string(writer, @tagName(param.default)),
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
pub fn sample(
    compiled: *Compiled,
    writer: *std.Io.Writer,
    source: Source,
    libraries: []const lang.Source,
    names: []const []const u8,
    window: Window,
) !bool {
    assert(window.valid());
    assert(names.len <= signals_max);
    compiled.compile_with(libraries, source.text) catch {
        try render_errors(compiled, writer, source, libraries);
        return false;
    };
    var default_names: [signals_max][]const u8 = undefined;
    const list = if (names.len > 0) names else default_signals(compiled, &default_names);
    var ids: [signals_max]weft.Id = undefined;
    for (list, 0..) |name, at| {
        ids[at] = compiled.signal(name) orelse {
            try writer.writeAll("error: ");
            try json_string(writer, name);
            try writer.writeAll(" is not a signal of the file\n");
            return false;
        };
    }
    const program = compiled.program;
    program.ranges(ranges[0..program.nodes.len]);
    const count = window.count();

    try writer.print("{{\"from\":{d},\"to\":{d},\"step\":{d},\"signals\":[", .{ window.from, window.to, window.step });
    for (list, ids[0..list.len], 0..) |name, id, at| {
        if (at > 0) try writer.writeAll(",");
        try writer.writeAll("{\"name\":");
        try json_string(writer, name);
        const extent = program.nodes[id.index].extent;
        if (extent.lanes > 1) try writer.print(",\"lanes\":{d}", .{extent.lanes});
        if (extent.components > 1) try writer.print(",\"components\":{d}", .{extent.components});
        try writer.writeAll(",\"range\":[");
        try json_number(writer, ranges[id.index].low);
        try writer.writeAll(",");
        try json_number(writer, ranges[id.index].high);
        try writer.writeAll("],\"values\":[");
        // Each signal reads the window from a fresh state, which a read cannot tell apart from one
        // that read the others too, so no lane array needs keeping.
        var state = weft.State.init(program, slab[0..program.slab_count]);
        for (0..count) |index| {
            if (index > 0) try writer.writeAll(",");
            state.eval(.{ .flicks = window.from + @as(i64, @intCast(index)) * window.step });
            const read = state.values(id);
            if (extent.lanes > 1) try writer.writeAll("[");
            for (0..extent.lanes) |lane| {
                if (lane > 0) try writer.writeAll(",");
                try json_value(writer, read[lane * extent.components ..][0..extent.components]);
            }
            if (extent.lanes > 1) try writer.writeAll("]");
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("],\"events\":[");
    var state = weft.State.init(program, slab[0..program.slab_count]);
    const found = state.events(.{ .flicks = window.from }, .{ .flicks = window.to }, &events);
    for (events[0..found.count], 0..) |event, at| {
        if (at > 0) try writer.writeAll(",");
        try writer.print("{{\"t\":{d},\"source\":{d},\"instance\":{d}}}", .{
            event.time.flicks,
            event.source.index,
            event.instance,
        });
    }
    try writer.writeAll("]}\n");
    return true;
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
