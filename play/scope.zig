//! The scope: one signal as a plot over a window of time, from plain numbers.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Draws
//! A `Row` is everything one line of the scope shows, already sampled: names, the range's ends,
//! the axis, the samples, an optional goal trace, the cues and the playhead as fractions of the
//! window, and the playhead reader's value. This file does not know Weft, so it draws any numbers.
//!
//! A goal trace is either samples, plotted like the signal, or steps: a fraction of the window
//! and a value each, from the first at 0. Steps draw as a line held flat to each step's x, then
//! straight up or down to its value, and on to the window's end, so a jump stays on its cue line
//! however the window moves.
//!
//! ```text
//! | name        |  plot face                                                          |
//! | class       |  range band, cue lines, goal trace (dim), signal trace, playhead    |
//! | [low, high] |                                                                     |
//!   label_width                    the rest of the row, inset by `inset`
//! ```
//!
//! A row's dots are its events in the window, each a fraction of the window and a value on the
//! row's axis: where a spring or a Newtonian move reached its goal, a follower arrived, or a shift
//! register entered a bucket, at the bucket's value.
//!
//! ## 2. Back to Front
//! The plot face, the range band, and the cue lines are Boxes, the two traces are Paths, both on
//! the base layer, whose batches draw in the registered order Box, Path, Glyph. The dots and the
//! playhead's line and dot are Boxes on `playhead_layer`, above the traces.
//!
//! ## 3. The Axis
//! `axis` is the range padded by `axis_pad` of its width when both ends are finite, and the hull of
//! the samples and the goal trace, sampled or in steps, padded the same way otherwise. A width of
//! zero pads by 1, so the axis always has a width.
//!
//! ## 4. TigerStyle Invariants
//! - Every append is checked by its pool; a refused one is counted by the context, and the tests
//!   assert no refusal at 1280 x 720.
//! - Text lines go through fixed stack buffers of `line_cap` bytes.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const quads = patchwork.draw;
const text = patchwork.text;
const theme = patchwork.theme;
const Rect = quads.Rect;
const Clip = quads.Clip;

pub const label_width: f32 = 200;
/// Space around the plot inside its row.
pub const inset: f32 = 6;
pub const axis_pad: f32 = 0.1;
pub const playhead_layer: quads.Layer = @fromBackingInt(@intCast(2));
const line_cap = 64;
/// The most steps a goal trace takes.
pub const steps_max = 17;

const ink = theme.dark.colors.text;
const name_style: text.Style = .{ .face = .sans_bold, .size = 14, .color = ink };
const note_style: text.Style = .{ .face = .sans, .size = 12, .color = dim(ink) };
const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };

pub const Row = struct {
    name: []const u8,
    class: []const u8,
    range: [2]f32,
    axis: [2]f32,
    samples: []const f32,
    /// A goal trace as samples, or as steps of a fraction and a value (section 1), or neither.
    goal: ?[]const f32,
    steps: ?[]const [2]f32,
    /// Fractions of the window; one outside `[0, 1]` is not drawn.
    cues: []const f32,
    /// The playhead's place in the window, as a fraction, and the playhead reader's value.
    head_at: f32,
    head: f32,
    color: [4]f32,
    /// Events as a fraction of the window and a value (section 1).
    dots: []const [2]f32,
};

/// A dot's side, in logical pixels.
pub const dot_size: f32 = 7;

/// The vertical axis of a row (section 3).
pub fn axis(
    range: [2]f32,
    samples: []const f32,
    goal: ?[]const f32,
    steps: ?[]const [2]f32,
) [2]f32 {
    var low = range[0];
    var high = range[1];
    if (!std.math.isFinite(low) or !std.math.isFinite(high)) {
        low = std.math.inf(f32);
        high = -std.math.inf(f32);
        for (samples) |value| {
            low = @min(low, value);
            high = @max(high, value);
        }
        for (goal orelse &.{}) |value| {
            low = @min(low, value);
            high = @max(high, value);
        }
        for (steps orelse &.{}) |step| {
            low = @min(low, step[1]);
            high = @max(high, step[1]);
        }
    }
    assert(low <= high);
    const pad = if (high > low) axis_pad * (high - low) else 1;
    return .{ low - pad, high + pad };
}

/// The rect a row's plot fills inside the row's rect.
pub fn plot_rect(rect: Rect) Rect {
    return .{
        .x = rect.x + label_width,
        .y = rect.y + inset,
        .width = rect.width - label_width - 2 * inset,
        .height = rect.height - 2 * inset,
    };
}

/// The y of `value` in `plot` over `range`, clamped to the plot, as `draw.path.plot` maps it.
pub fn y_of(value: f32, plot: Rect, range: [2]f32) f32 {
    const level = std.math.clamp((value - range[0]) / (range[1] - range[0]), 0, 1);
    return plot.y + plot.height * (1 - level);
}

pub fn draw(cx: anytype, row: Row, rect: Rect, clip: Clip) void {
    assert(row.axis[1] > row.axis[0]);
    assert(row.samples.len >= 2);
    assert(row.samples.len <= quads.path.plot_samples_max);
    draw_labels(cx, row, rect, clip);
    const plot = plot_rect(rect);
    const inside = within(clip, plot) orelse return;
    box(cx, plot, clip, theme.dark.colors.panel, 4);
    if (std.math.isFinite(row.range[0]) and std.math.isFinite(row.range[1])) {
        const top = y_of(row.range[1], plot, row.axis);
        const bottom = y_of(row.range[0], plot, row.axis);
        const band: Rect = .{ .x = plot.x, .y = top, .width = plot.width, .height = bottom - top };
        box(cx, band, inside, with_alpha(row.color, 0.12), 0);
    }
    for (row.cues) |at| {
        if (at < 0 or at > 1) continue;
        const x = plot.x + at * plot.width;
        const line: Rect = .{ .x = x - 0.5, .y = plot.y, .width = 1, .height = plot.height };
        box(cx, line, inside, dim(ink), 0);
    }
    const goal_stroke: quads.path.Stroke = .{
        .color = with_alpha(row.color, 0.4),
        .width = 1.5,
        .hover = 0,
    };
    if (row.goal) |goal| {
        _ = quads.path.plot(cx.drawing(), goal, plot, row.axis, goal_stroke, inside);
    }
    if (row.steps) |steps| draw_steps(cx, steps, plot, row.axis, goal_stroke, inside);
    const stroke: quads.path.Stroke = .{ .color = row.color, .width = 2, .hover = 0 };
    _ = quads.path.plot(cx.drawing(), row.samples, plot, row.axis, stroke, inside);
    const previous = cx.drawing().layer(playhead_layer);
    defer _ = cx.drawing().layer(previous);
    for (row.dots) |dot| {
        assert(dot[0] >= 0 and dot[0] <= 1);
        const at: Rect = .{
            .x = plot.x + dot[0] * plot.width - dot_size / 2,
            .y = y_of(dot[1], plot, row.axis) - dot_size / 2,
            .width = dot_size,
            .height = dot_size,
        };
        box(cx, at, inside, with_alpha(ink, 0.9), dot_size / 2);
    }
    const x = plot.x + row.head_at * plot.width;
    const line: Rect = .{ .x = x - 0.75, .y = plot.y, .width = 1.5, .height = plot.height };
    box(cx, line, inside, with_alpha(ink, 0.6), 0);
    const y = y_of(row.head, plot, row.axis);
    box(cx, .{ .x = x - 4, .y = y - 4, .width = 8, .height = 8 }, clip, row.color, 4);
}

/// Steps as a line: flat to each step's x, then to its value, then flat to the window's end. A
/// point equal to the one before it is left out, so no segment has zero length.
fn draw_steps(
    cx: anytype,
    steps: []const [2]f32,
    plot: Rect,
    range: [2]f32,
    stroke: quads.path.Stroke,
    clip: Clip,
) void {
    assert(steps.len >= 1);
    assert(steps.len <= steps_max);
    assert(steps[0][0] == 0);
    var points: [2 * steps_max + 1]quads.path.Point = undefined;
    var count: usize = 0;
    var y = y_of(steps[0][1], plot, range);
    for (steps) |step| {
        assert(step[0] >= 0 and step[0] <= 1);
        const x = plot.x + step[0] * plot.width;
        for ([2]f32{ y, y_of(step[1], plot, range) }) |at_y| {
            const point: quads.path.Point = .{ x, at_y };
            if (count > 0 and std.meta.eql(points[count - 1], point)) continue;
            points[count] = point;
            count += 1;
        }
        y = y_of(step[1], plot, range);
    }
    const end: quads.path.Point = .{ plot.x + plot.width, y };
    if (!std.meta.eql(points[count - 1], end)) {
        points[count] = end;
        count += 1;
    }
    assert(count >= 2);
    _ = quads.path.polyline(cx.drawing(), points[0..count], stroke, clip);
}

fn draw_labels(cx: anytype, row: Row, rect: Rect, clip: Clip) void {
    const draw_cx = cx.drawing();
    const width = label_width - 24;
    var line: Rect = .{ .x = rect.x + 12, .y = rect.y + 8, .width = width, .height = 20 };
    text.place(draw_cx, name_style, row.name, line, clip, left);
    line.y += 22;
    line.height = 18;
    text.place(draw_cx, note_style, row.class, line, clip, left);
    var buffer: [line_cap]u8 = undefined;
    const ends = .{ row.range[0], row.range[1] };
    const range = std.fmt.bufPrint(&buffer, "[{d:.2}, {d:.2}]", ends) catch unreachable;
    line.y += 20;
    text.place(draw_cx, note_style, range, line, clip, left);
}

/// The part of `clip` inside `rect`, or null when they do not overlap.
fn within(clip: Clip, rect: Rect) ?Clip {
    const result: Clip = .{
        .x0 = @max(clip.x0, rect.x),
        .y0 = @max(clip.y0, rect.y),
        .x1 = @min(clip.x1, rect.x + rect.width),
        .y1 = @min(clip.y1, rect.y + rect.height),
    };
    if (result.x1 <= result.x0 or result.y1 <= result.y0) return null;
    return result;
}

fn box(cx: anytype, rect: Rect, clip: Clip, color: [4]f32, radius: f32) void {
    cx.append(quads.Box, null, .of(rect, clip, .{ .fill = color, .radius = radius })) catch {};
}

fn with_alpha(color: [4]f32, alpha: f32) [4]f32 {
    return .{ color[0], color[1], color[2], alpha };
}

fn dim(color: [4]f32) [4]f32 {
    return with_alpha(color, 0.45);
}
