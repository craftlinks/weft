//! The language against the builder: every graph of the regress catalog, written as text,
//! compiles to the catalog's own nodes.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why the Catalog
//! The catalog's graphs (`catalog.zig`) are built by hand with the builder, and their samples are
//! locked by the regress golden. If a graph's text compiles to the same nodes, field for field,
//! the text gives the same samples, with no second golden. Fourteen of the fifteen are here: the
//! recorded one plays a client's samples, which the language does not have.
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
