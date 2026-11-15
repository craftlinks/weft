//! The language against the builder: every graph of the regress catalog, written as text,
//! compiles to the catalog's own nodes.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why the Catalog
//! The catalog's graphs (`catalog.zig`) are built by hand with the builder, and their samples are
//! locked by the regress golden. If a graph's text compiles to the same nodes, field for field,
//! the text gives the same samples, with no second golden. Fourteen of the fifteen are here: the
//! recorded one plays a client's samples, which the language does not have. So are the four
//! graphs of `abs`, `min`, and `max` (step 26), and the eight of step 33, named `fn_NAME`.
//!
//! ## 2. One Preamble
//! Every graph reads the catalog's tables, so each text starts with the same preamble: its three
//! cues, its four tracks, its two paths, and its regions, declared in the catalog's order, so
//! each table holds the same runs at the same indices. The cue times are those of epoch zero;
//! nodes refer to cues by index, so the times do not change a node.
//!
//! ## 3. Equality
//! Nodes are compared with `std.meta.eql`, field by field: a node's padding has no defined value,
//! so bytes would differ where fields do not.
//!
//! ## 4. A Call's Class
//! `describe` gives each call the class of the nodes it builds itself, from `table.core_op` and
//! the core's `Op.class` (step 35). So that the table of core ops cannot drift from the back end,
//! each entry's call is compiled once, with its signal arguments bound to an `input` on a line of
//! their own, and the nodes of its own line are read: one is of its core op, and the highest of
//! their classes is the entry's. A call of class `inputs` builds only pure nodes, and its value
//! then has its input's class, live.

const std = @import("std");
const weft = @import("weft");
const catalog = @import("catalog");

const preamble =
    \\seed 24301
    \\
    \\cue c0 = 0.5s
    \\cue c1 = 1.5s
    \\cue c2 = 2.5s
    \\
    \\track rate = 1 in 0.25..3
    \\track chase_s = 0.5 in 0.125..1
    \\track sway_os = 0.2 in 0..0.9
    \\track glide_v = 1 in 0.25..4
    \\
    \\spring_goals = [c0: 1, c1: -0.5, c2: 0.25]
    \\glide_goals = [c0: 1, c1: -1, c2: 0.5]
    \\pair = [-1..-0.5, 0.25..1]
    \\
;

const sequence =
    \\rise = tween(from: 0, to: 1, at: c0, over: 1s, ease: in_out)
    \\overshoot = tween(from: 1, to: 3, at: c1, over: 1s, ease: [0.34, 1.56, 0.64, 1], after: rise)
    \\sequence = tween(from: 3, to: -0.1, at: c2, over: 1s, ease: out, after: overshoot)
    \\
;

const Case = struct { name: []const u8, text: []const u8 };

const cases = [_]Case{
    .{ .name = "tremolo", .text = "out = wave(sine, 440hz) * map(wave(triangle, 0.7hz), -1..1, to: 0.25..1)\n" },
    .{ .name = "drift", .text = "out = wave(sine, 0.7hz) + wave(saw, 1hz) * 0.5\n" },
    .{ .name = "sequence", .text = sequence ++ "out = sequence\n" },
    .{ .name = "wander", .text = "out = noise(smooth, 0.7hz, seed: 1) + noise(steps, 3hz, seed: 2) * 0.25\n" },
    .{ .name = "spring", .text = "out = spring(spring_goals, time: 0.6s, overshoot: 0.2)\n" },
    .{ .name = "glide", .text = "out = newtonian(glide_goals, speed: 1.5, accel: 6, decel: 4)\n" },
    .{ .name = "chase", .text = sequence ++ "out = chase(sequence, from: -0.5, time: 0.4s, overshoot: 0.15)\n" },
    .{ .name = "follow", .text = "out = follow(pair, by: spring(time: 0.3s), tolerance: 0.02, pause: 100ms..400ms, seed: 5)\n" },
    .{ .name = "shift", .text = "out = shift(-1..1, buckets: 8, period: 2s, odds: 0.5, shape: smooth, seed: 6)\n" },
    .{ .name = "feedback", .text =
    \\echo = delay(0)
    \\scaled = echo * -0.8
    \\target = 1 + scaled
    \\out = chase(target, time: 0.5s, overshoot: 0.2)
    \\echo <- out
    \\
    },
    .{ .name = "oscillator", .text = "out = oscillator(triangle, rate: rate, phase: 0.25)\n" },
    .{ .name = "live_chase", .text = sequence ++ "out = chase(sequence, time: chase_s, overshoot: 0.15)\n" },
    .{ .name = "live_sway", .text = "out = follow(pair, by: spring(time: 0.4s, overshoot: sway_os), tolerance: 0.02, pause: 100ms..400ms, seed: 7)\n" },
    .{ .name = "live_glide", .text =
    \\limit = glide_v * 4
    \\out = follow(pair, by: newtonian(speed: glide_v, accel: limit, decel: limit), tolerance: 0.02, pause: 0s..300ms, seed: 8)
    \\
    },
    .{ .name = "abs", .text = "out = abs(wave(sine, 0.7hz) + wave(saw, 1hz) * 0.5)\n" },
    .{ .name = "min", .text = "out = min(wave(sine, 0.7hz), wave(triangle, 1hz))\n" },
    .{ .name = "max", .text = sequence ++ "out = max(sequence, wave(sine, 0.7hz) * 0.5)\n" },
    .{ .name = "clamp", .text = "out = min(max(wave(sine, 0.7hz) * 2, -0.5), 1)\n" },
    .{ .name = "fn_sin", .text = "out = sin(wave(sine, 0.7hz) * 4)\n" },
    .{ .name = "fn_cos", .text = "out = cos(wave(sine, 0.7hz) * 4)\n" },
    .{ .name = "fn_exp", .text = "out = exp(wave(sine, 0.7hz) * 3)\n" },
    .{ .name = "fn_ln", .text = "out = ln(wave(sine, 0.7hz))\n" },
    .{ .name = "fn_sqrt", .text = "out = sqrt(wave(sine, 0.7hz))\n" },
    .{ .name = "fn_floor", .text = "out = floor(wave(sine, 0.7hz) * 3)\n" },
    .{ .name = "fn_round", .text = "out = round(wave(sine, 0.7hz) * 2.5)\n" },
    .{ .name = "fn_pow", .text = "out = pow(wave(sine, 0.7hz) * 1.5, 3)\n" },
};

var compiled: weft.lang.Compiled(.{ .tokens = 1024, .tree = 512, .names = 64, .nodes = 64, .slab = 256, .cues = 8, .goals = 16, .regions = 8, .tracks = 4, .track_samples = 4 }) = undefined;

// Locks section 1: each catalog graph's text compiles to the catalog's nodes and output.
test "the catalog's graphs as text compile to the catalog's nodes" {
    inline for (cases) |case| {
        const source = preamble ++ case.text;
        compiled.compile(source) catch {
            var buffer: [1024]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            for (compiled.errors()) |found| found.render(source, case.name, &writer) catch {};
            std.debug.print("{s}", .{writer.buffered()});
            return error.TestUnexpectedResult;
        };
        var nodes: [catalog.graph_nodes_max]weft.Node = undefined;
        const expected = catalog.graph_nodes(case.name, &nodes).?;
        const program = compiled.program;
        errdefer std.debug.print("graph {s}\n", .{case.name});
        try std.testing.expectEqual(expected.count, program.nodes.len);
        for (nodes[0..expected.count], program.nodes, 0..) |want, got, index| {
            if (!std.meta.eql(want, got)) {
                std.debug.print("node {d}:\n  {any}\n  {any}\n", .{ index, want, got });
                return error.TestUnexpectedResult;
            }
        }
        try std.testing.expectEqual(expected.output, compiled.signal("out").?);
    }
}

/// A file whose last line, `out = …`, is a call of `entry`, its signal arguments `x`, an input
/// (section 4).
fn class_sample(entry: *const weft.lang.schema.Entry, writer: *std.Io.Writer) !void {
    try writer.writeAll("cue c0 = 0s\ncue c1 = 1s\nx = input()\n");
    switch (weft.lang.table.op_of(entry)) {
        .wave => try writer.writeAll("out = wave(sine, 1hz)\n"),
        .noise => try writer.writeAll("out = noise(smooth, 1hz)\n"),
        .tween => try writer.writeAll("out = tween(from: 0, to: 1, at: c0, over: 1s)\n"),
        .spring => try writer.writeAll("out = spring([c1: 1], time: 1s)\n"),
        .newtonian => try writer.writeAll("out = newtonian([c1: 1], speed: 1, accel: 1, decel: 1)\n"),
        .chase => try writer.writeAll("out = chase(x, time: 1s)\n"),
        .oscillator => try writer.writeAll("out = oscillator(sine, rate: x)\n"),
        .follow => try writer.writeAll("out = follow([0..1], by: spring(time: 1s))\n"),
        .shift => try writer.writeAll("out = shift(0..1, buckets: 4, period: 1s, odds: 0.5, shape: steps)\n"),
        .delay => try writer.writeAll("out = delay(0)\nout <- x\n"),
        .bounce => try writer.writeAll("out = bounce(0..1, speed: 1, at: c0)\n"),
        .crossing => try writer.writeAll("out = crossing(x, level: 0.5)\n"),
        .cues => try writer.writeAll("out = cues(c0)\n"),
        .input => try writer.writeAll("out = input()\n"),
        .map => try writer.writeAll("out = map(x, 0..1, to: 0..2)\n"),
        .function => try writer.print("out = {s}(x{s})\n", .{ entry.name, if (entry.params.len == 2) ", 2" else "" }),
        .minimum, .maximum => try writer.print("out = {s}(x, x)\n", .{entry.name}),
        .pack => try writer.print("out = {s}(x, x{s})\n", .{ entry.name, if (entry.params.len == 3) ", x" else "" }),
        .srgb => try writer.writeAll("out = srgb(0.5, 0.5, 0.5)\n"),
        .lanes => try writer.writeAll("out = lanes(3, x)\n"),
        .spring_mover, .newtonian_mover, .client, .noun => unreachable,
    }
}

// Locks section 4: every entry's class is the class of the nodes its call builds, for each of
// the table's calls that builds any; `map(x, …)`, `abs(x)`, `vec2(x, x)`, and `lanes(3, x)` of an
// input are live, as their `inputs` says.
test "describe's class of a call is the class of the nodes it builds" {
    for (&weft.lang.table.entries) |*entry| {
        const tag = weft.lang.table.core_op(weft.lang.table.op_of(entry)) orelse {
            try std.testing.expectEqual(null, entry.class());
            continue;
        };
        var text: [256]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&text);
        try class_sample(entry, &writer);
        errdefer std.debug.print("entry {s}: {s}\n", .{ entry.name, writer.buffered() });
        try compiled.compile(writer.buffered());
        const program = compiled.program;
        const nodes = compiled.node_ranges[binding_of(compiled.checked.bindings, "out")];
        try std.testing.expect(nodes.end > nodes.first);
        var own: weft.Class = .pure;
        var built = false;
        for (program.nodes[nodes.first..nodes.end]) |node| {
            own = own.max(node.op.class());
            built = built or std.meta.activeTag(node.op) == tag;
        }
        try std.testing.expect(built);
        var classes: [64]weft.Class = undefined;
        program.classes(&classes);
        const out = compiled.signal("out").?;
        switch (entry.class().?) {
            .inputs => {
                try std.testing.expectEqual(weft.Class.pure, own);
                try std.testing.expectEqual(weft.Class.live, classes[out.index]);
            },
            .pure => try std.testing.expectEqual(weft.Class.pure, own),
            .exact => try std.testing.expectEqual(weft.Class.exact, own),
            .simulated => try std.testing.expectEqual(weft.Class.simulated, own),
            .live => try std.testing.expectEqual(weft.Class.live, own),
        }
    }
}

/// The index of the binding called `name`.
fn binding_of(bindings: []const weft.lang.check.Binding, name: []const u8) usize {
    for (bindings, 0..) |binding, at| {
        if (std.mem.eql(u8, binding.name, name)) return at;
    }
    unreachable;
}
