//! The explainer's score that `nouns.zig` and `cli.zig` share (step 32): four nouns shaped like
//! an explainer's, and a file that uses all four beside its signals.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why a File of Its Own
//! `nouns.zig` locks what the library gives a client for this score, and `cli.zig` what a
//! client's command prints for it. Each imports this file, which has no tests, so neither runs
//! the other's tests.
//!
//! ## 2. The Nouns
//! `axes` takes ranges, `plot` names an `axes` and takes two signals of many lanes and one of
//! one, `say` takes a cue and a string, and `label` names any noun and has a string default.

const weft = @import("weft");
const schema = weft.lang.schema;

pub const nouns = [_]schema.Entry{
    .{
        .name = "axes",
        .op = .noun,
        .role = .signal,
        .params = &.{
            .{ .name = "x", .kind = .number_range },
            .{ .name = "y", .kind = .number_range },
        },
        .summary = "a frame of coordinates",
    },
    .{
        .name = "plot",
        .op = .noun,
        .role = .signal,
        .params = &.{
            .{ .name = "on", .kind = .noun, .positional = true, .words = &.{"axes"} },
            .{ .name = "x", .kind = .signal, .positional = true },
            .{ .name = "y", .kind = .signal },
            .{ .name = "draw", .kind = .signal, .default = .{ .number = 1 } },
            .{ .name = "tint", .kind = .signal, .shaped = true, .default = .absent },
        },
        .summary = "a curve through the lanes of x and y",
    },
    .{
        .name = "say",
        .op = .noun,
        .role = .signal,
        .params = &.{
            .{ .name = "at", .kind = .cue, .positional = true },
            .{ .name = "text", .kind = .string, .positional = true },
            .{ .name = "voice", .kind = .word, .default = .{ .word = 0 }, .words = &.{ "plain", "aside" } },
        },
        .summary = "a line of narration that starts at a cue",
    },
    .{
        .name = "label",
        .op = .noun,
        .role = .signal,
        .params = &.{
            .{ .name = "of", .kind = .noun, .positional = true },
            .{ .name = "text", .kind = .string, .default = .{ .text = "?" } },
        },
        .summary = "a name beside any noun",
    },
};

pub const score =
    \\cue b1 = 0s
    \\cue b2 = 2s
    \\track a = 1 in 0..3
    \\xs = lanes(5, lane - 2)
    \\reveal = tween(from: 0, to: 1, at: b1, over: 1s)
    \\ax = axes(x: -3..3, y: -1..9)
    \\f = plot(ax, xs, y: a * xs * xs, draw: reveal, tint: srgb(1, 0.5, 0))
    \\n1 = say(b1, "Here is a parabola: f(x) = a x^2.")
    \\n2 = say(b2, "Its \frac{rise}{run} # is its slope.", voice: aside)
    \\name = label(f)
    \\
;
