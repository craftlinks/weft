//! The regress catalog: signals sampled on a fixed grid, written as text of hex floats.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. One Renderer, Two Targets
//! `render` is the same code on native (`tools/regress.zig`) and on wasm
//! (`tools/regress_wasm.zig`), and both of its outputs must equal `test/golden/signals.txt` byte
//! for byte. A hex float prints every bit of a value, so text equality is bit equality.
//!
//! ## 2. The Format
//! One sample per line: shape, frequency, epoch, sample index, hex float. So a golden diff is a
//! list of named samples, and `compare` can report the first sample that changed by its line.
//!
//! ## 3. The Grid
//! Each signal runs on a clock it would really meet, and at each epoch: at zero, an hour and a day
//! later, where a float of seconds would have lost bits, and an hour before zero. The stride makes
//! a run cover about a cycle at the slow frequencies and a few cycles at the fast ones.
//!
//! ## 4. Graphs
//! Waves alone cannot notice a change in how a `Program` evaluates, so the catalog also samples
//! whole graphs through a `State`, on the same epochs. They come after the waves in the text, so a
//! change to either shows up on its own lines.
//!
//! ## 5. TigerStyle Invariants
//! - The text fits in `text_size_max` by construction, so `render` cannot fail.

const std = @import("std");
const assert = std.debug.assert;
const weft = @import("weft");

const Signal = struct {
    name: []const u8,
    hz: f64,
    rate_hz: u32,
    stride_ticks: u32,
};

const Epoch = struct {
    name: []const u8,
    seconds: i64,
};

const signals = [_]Signal{
    .{ .name = "1hz", .hz = 1, .rate_hz = 60, .stride_ticks = 3 },
    .{ .name = "0.7hz", .hz = 0.7, .rate_hz = 60, .stride_ticks = 3 },
    .{ .name = "261.63hz", .hz = 261.63, .rate_hz = 44_100, .stride_ticks = 8 },
    .{ .name = "440hz", .hz = 440, .rate_hz = 48_000, .stride_ticks = 8 },
};

const epochs = [_]Epoch{
    .{ .name = "zero", .seconds = 0 },
    .{ .name = "hour", .seconds = 3600 },
    .{ .name = "day", .seconds = 86_400 },
    .{ .name = "before", .seconds = -3600 },
};

const shapes = std.enums.values(weft.Shape);

/// Each graph's nodes are built by `graph_build`.
const Graph = enum {
    tremolo,
    drift,

    const nodes_count_max = 8;
};

const graphs = std.enums.values(Graph);

const samples_per_run = 24;

const wave_sample_count = shapes.len * signals.len * epochs.len * samples_per_run;
const graph_sample_count = graphs.len * epochs.len * samples_per_run;

pub const sample_count = wave_sample_count + graph_sample_count;

const line_size_max = 64;

pub const text_size_max = sample_count * line_size_max;

comptime {
    assert(wave_sample_count == 1536);
    assert(graph_sample_count == 192);
    assert(text_size_max < 1 << 20);
    for (signals) |signal| assert(weft.Rate.from_hz(signal.rate_hz) != null);
}

/// Writes the catalog into `text` and returns the part written.
pub fn render(text: *[text_size_max]u8) []const u8 {
    var writer: std.Io.Writer = .fixed(text);
    for (shapes) |shape| {
        for (&signals) |*signal| {
            for (&epochs) |*epoch| render_run(&writer, shape, signal, epoch);
        }
    }
    for (graphs) |graph| {
        for (&epochs) |*epoch| render_graph_run(&writer, graph, epoch);
    }
    assert(writer.buffered().len > sample_count);
    assert(writer.buffered()[writer.buffered().len - 1] == '\n');
    return writer.buffered();
}

fn render_run(
    writer: *std.Io.Writer,
    shape: weft.Shape,
    signal: *const Signal,
    epoch: *const Epoch,
) void {
    assert(signal.stride_ticks > 0);
    assert(signal.hz > 0);
    const wave = weft.Wave{ .shape = shape, .hz = signal.hz };
    const rate = weft.Rate.from_hz(signal.rate_hz).?;
    const tick_first = epoch.seconds * signal.rate_hz;
    for (0..samples_per_run) |index| {
        const tick = tick_first + @as(i64, @intCast(index * signal.stride_ticks));
        const value = wave.sample(weft.Time.from_ticks(tick, rate).?);
        const size_before = writer.buffered().len;
        writer.print("{t} {s} {s} {d} {x}\n", .{
            shape, signal.name, epoch.name, index, value,
        }) catch unreachable;
        assert(writer.buffered().len - size_before <= line_size_max);
    }
}

fn render_graph_run(writer: *std.Io.Writer, graph: Graph, epoch: *const Epoch) void {
    var nodes: [Graph.nodes_count_max]weft.Node = undefined;
    var slab: [Graph.nodes_count_max]f64 = undefined;
    var builder = weft.Builder.init(&nodes, .{ .slab_count_max = slab.len });
    const output = graph_build(graph, &builder) catch unreachable;
    var state = weft.State.init(builder.finish(), &slab);

    const rate = weft.Rate.from_hz(48_000).?;
    const tick_first = epoch.seconds * 48_000;
    for (0..samples_per_run) |index| {
        const tick = tick_first + @as(i64, @intCast(index)) * graph_stride_ticks;
        state.eval(weft.Time.from_ticks(tick, rate).?);
        const size_before = writer.buffered().len;
        writer.print("graph {t} {s} {d} {x}\n", .{
            graph, epoch.name, index, state.value(output),
        }) catch unreachable;
        assert(writer.buffered().len - size_before <= line_size_max);
    }
}

/// Spreads a run over about four seconds, nearly three cycles of the slowest wave.
const graph_stride_ticks = 8192;

fn graph_build(graph: Graph, builder: *weft.Builder) weft.Builder.Error!weft.Id {
    switch (graph) {
        // 440 Hz scaled by a slower wave moved into [0.25, 1].
        .tremolo => {
            const fast = try builder.wave(.{ .shape = .sine, .hz = 440 });
            const slow = try builder.wave(.{ .shape = .triangle, .hz = 0.7 });
            const depth = try builder.map_range(.{
                .input = slow,
                .input_low = -1,
                .input_high = 1,
                .output_low = 0.25,
                .output_high = 1,
            });
            return builder.multiply(fast, depth);
        },
        // Two slow waves added, with an offset, as a position would be.
        .drift => {
            const first = try builder.wave(.{ .shape = .sine, .hz = 0.7 });
            const second = try builder.wave(.{ .shape = .saw, .hz = 1 });
            const half = try builder.constant(0.5);
            const scaled = try builder.multiply(second, half);
            return builder.add(first, scaled);
        },
    }
}

pub const Mismatch = struct {
    /// 1-based, as an editor counts lines.
    line: u32,
    expected: []const u8,
    actual: []const u8,
};

const text_end = "(end of text)";

/// The first line where two texts differ, or null if they are equal.
pub fn compare(expected: []const u8, actual: []const u8) ?Mismatch {
    if (std.mem.eql(u8, expected, actual)) return null;
    var expected_lines = std.mem.splitScalar(u8, expected, '\n');
    var actual_lines = std.mem.splitScalar(u8, actual, '\n');
    // A text of n bytes has at most n + 1 lines, and the texts differ within the shorter one + 1.
    for (0..expected.len + actual.len + 1) |index| {
        const expected_line = expected_lines.next();
        const actual_line = actual_lines.next();
        const same = if (expected_line != null and actual_line != null)
            std.mem.eql(u8, expected_line.?, actual_line.?)
        else
            false;
        if (same) continue;
        assert(expected_line != null or actual_line != null);
        return .{
            .line = @intCast(index + 1),
            .expected = expected_line orelse text_end,
            .actual = actual_line orelse text_end,
        };
    }
    unreachable;
}

const testing = std.testing;

var text_a: [text_size_max]u8 = undefined;
var text_b: [text_size_max]u8 = undefined;

// Locks the size of the catalog and that rendering twice gives the same bytes.
test "the catalog renders one line per sample, the same each time" {
    const first = render(&text_a);
    const second = render(&text_b);
    try testing.expectEqualStrings(first, second);
    try testing.expectEqual(@as(usize, sample_count), std.mem.count(u8, first, "\n"));
    try testing.expect(std.mem.startsWith(u8, first, "sine 1hz zero 0 0x0.0p0\n"));
}

// Locks that a hex float keeps every bit: each value in the catalog parses back to a value that
// prints as the same text.
test "every sample round-trips through its text" {
    const text = render(&text_a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const hex = line[std.mem.lastIndexOfScalar(u8, line, ' ').? + 1 ..];
        const value = try std.fmt.parseFloat(f64, hex);
        var buffer: [line_size_max]u8 = undefined;
        const again = try std.fmt.bufPrint(&buffer, "{x}", .{value});
        try testing.expectEqualStrings(hex, again);
    }
}

// Locks the promise of regress: flipping the lowest bit of one sample fails the comparison, and
// the mismatch gives that sample's line and names its signal.
test "a one-bit change is found and names the signal" {
    const golden = render(&text_a);
    const line_target = 700;
    var lines = std.mem.splitScalar(u8, golden, '\n');
    for (0..line_target - 1) |_| _ = lines.next();
    const line = lines.next().?;

    const hex_start = std.mem.lastIndexOfScalar(u8, line, ' ').? + 1;
    const value = try std.fmt.parseFloat(f64, line[hex_start..]);
    const value_flipped: f64 = @bitCast(@as(u64, @bitCast(value)) ^ 1);
    var buffer: [line_size_max]u8 = undefined;
    const hex_flipped = try std.fmt.bufPrint(&buffer, "{x}", .{value_flipped});

    const line_start = line.ptr - golden.ptr;
    const head = golden[0 .. line_start + hex_start];
    const tail = golden[line_start + line.len ..];
    @memcpy(text_b[0..head.len], head);
    @memcpy(text_b[head.len..][0..hex_flipped.len], hex_flipped);
    const tail_start = head.len + hex_flipped.len;
    @memcpy(text_b[tail_start..][0..tail.len], tail);
    const changed = text_b[0 .. tail_start + tail.len];

    const mismatch = compare(golden, changed).?;
    try testing.expectEqual(@as(u32, line_target), mismatch.line);
    try testing.expectEqualStrings(line, mismatch.expected);
    try testing.expect(std.mem.startsWith(u8, mismatch.actual, line[0..hex_start]));
    try testing.expect(!std.mem.eql(u8, mismatch.expected, mismatch.actual));
}

// Locks the answers of `compare` for equal texts, a missing line, and an extra blank line, the
// last of which two splitting iterators see only at their ends.
test "compare finds the end of a shorter text" {
    try testing.expectEqual(@as(?Mismatch, null), compare("a\nb\n", "a\nb\n"));
    const short = compare("a\nb\n", "a\n").?;
    try testing.expectEqual(@as(u32, 2), short.line);
    try testing.expectEqualStrings("b", short.expected);
    const long = compare("a\n", "a\n\n").?;
    try testing.expectEqual(@as(u32, 3), long.line);
    try testing.expectEqualStrings(text_end, long.expected);
}
