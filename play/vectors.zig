//! The vectors page (Weft's step 16): a plane where a 2D spring's place moves through four goals,
//! with its trail over the scope's window, and three colours as strips over the same window, from
//! plain numbers.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Draws
//! A `Page` is the program already read at t (`glue.zig`, section 7): the place at each sample of
//! the window and at t, the four goals and the one last reached, and each colour in sRGB at each
//! sample and at t. This file does not know Weft, so it draws any numbers.
//! ```text
//! x 16..656     the plane, [0, 1] both ways padded by `pad`, y up: grid lines at 0, 0.5, and 1,
//!               the goals as rings, the trail, and the place at t in the glow's colour
//! x 672..1272   three rows of 112 px from y 56: the name and a swatch of the colour at t, then
//!               the strip, one box a sample, with the playhead's line
//! ```
//! The trail is two polylines that meet at the place at t: the window's past, bright, and its
//! future, faint, so the playhead is where they meet, a quarter of the way along, as on the scope.
//!
//! ## 2. Back to Front
//! The faces, the grid, the strips, and the trail on the base layer; the goals, the place, and
//! the playhead lines on the scope's `playhead_layer`, above them.
//!
//! ## 3. TigerStyle Invariants
//! - Points live in fixed stack arrays of `glue.vector_samples + 1`.
//! - Every append is checked by its pool; a refused one is dropped, and the tests assert none.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const scope = @import("scope.zig");
const quads = patchwork.draw;
const text = patchwork.text;
const theme = patchwork.theme;
const Rect = quads.Rect;
const Clip = quads.Clip;
const Point = quads.path.Point;

pub const samples_max = 128;
pub const colour_count = 3;
pub const goal_count = 4;
pub const plane_rect: Rect = .{ .x = 16, .y = 56, .width = 640, .height = 656 };
pub const strip_x: f32 = 672;
pub const strip_y: f32 = 56;
pub const strip_pitch: f32 = 112;
const label_width: f32 = 128;
const strip_height: f32 = 64;
const swatch_size: f32 = 40;
/// The plane's padding beyond [0, 1] on each side, so an overshoot stays on it.
pub const pad: f32 = 0.2;
const goal_size: f32 = 12;
const place_size: f32 = 20;

const ink = theme.dark.colors.text;
const name_style: text.Style = .{ .face = .sans_bold, .size = 14, .color = ink };
const note_style: text.Style = .{ .face = .sans, .size = 12, .color = with_alpha(ink, 0.55) };
const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };

pub const Page = struct {
    /// The place over the window, and at t.
    trail: []const [2]f32,
    head: [2]f32,
    /// Where t sits in the window.
    head_at: f32,
    goals: []const [2]f32,
    /// The goal last reached, or null before the first.
    goal: ?usize,
    /// Each colour's sRGB over the window, and at t.
    colours: []const []const [3]f32,
    swatches: []const [3]f32,
    /// The place's colour.
    dot: [3]f32,
    names: []const []const u8,
    notes: []const []const u8,
    accent: [4]f32,
};

pub fn draw(cx: anytype, page: Page, clip: Clip) void {
    assert(page.trail.len >= 2 and page.trail.len <= samples_max);
    assert(page.head_at >= 0 and page.head_at <= 1);
    assert(page.colours.len == page.swatches.len);
    assert(page.colours.len == page.names.len and page.names.len == page.notes.len);
    draw_plane(cx, page, clip);
    for (page.colours, page.swatches, page.names, page.notes, 0..) |strip, swatch, name, note, index| {
        draw_strip(cx, strip, swatch, name, note, page.head_at, strip_rect(index), clip);
    }
}

/// The rect of colour row `index`: its label column and its strip.
pub fn strip_rect(index: usize) Rect {
    const y = strip_y + strip_pitch * @as(f32, @floatFromInt(index));
    return .{ .x = strip_x, .y = y, .width = 600, .height = strip_pitch - 16 };
}

/// A point of the plane at `value`, padded and with y up (section 1).
pub fn plane_point(value: [2]f32) Point {
    const square = plane_square();
    const span = 1 + 2 * pad;
    return .{
        square.x + (value[0] + pad) / span * square.width,
        square.y + square.height - (value[1] + pad) / span * square.height,
    };
}

/// The plane's square, centred in `plane_rect`.
fn plane_square() Rect {
    const side = @min(plane_rect.width, plane_rect.height);
    return .{
        .x = plane_rect.x + (plane_rect.width - side) / 2,
        .y = plane_rect.y + (plane_rect.height - side) / 2,
        .width = side,
        .height = side,
    };
}

fn draw_plane(cx: anytype, page: Page, clip: Clip) void {
    const square = plane_square();
    const inside = within(clip, square) orelse return;
    box(cx, square, clip, theme.dark.colors.panel, 6);
    for ([_]f32{ 0, 0.5, 1 }) |at| {
        const a = plane_point(.{ at, 0 });
        const b = plane_point(.{ 0, at });
        const alpha: f32 = if (at == 0.5) 0.12 else 0.25;
        box(cx, .{ .x = a[0] - 0.5, .y = square.y, .width = 1, .height = square.height }, inside, with_alpha(ink, alpha), 0);
        box(cx, .{ .x = square.x, .y = b[1] - 0.5, .width = square.width, .height = 1 }, inside, with_alpha(ink, alpha), 0);
    }
    // The past ends at the place at t, and the future starts there.
    const last = page.trail.len - 1;
    const split = @min(last, @as(usize, @intFromFloat(@floor(page.head_at * @as(f32, @floatFromInt(last))))) + 1);
    var points: [samples_max + 1]Point = undefined;
    for (page.trail[0..split], points[0..split]) |value, *point| point.* = plane_point(value);
    points[split] = plane_point(page.head);
    const past: quads.path.Stroke = .{ .color = page.accent, .width = 2.5, .hover = 0 };
    _ = quads.path.polyline(cx.drawing(), points[0 .. split + 1], past, inside);
    points[0] = plane_point(page.head);
    for (page.trail[split..], points[1..][0 .. page.trail.len - split]) |value, *point| point.* = plane_point(value);
    const future: quads.path.Stroke = .{ .color = with_alpha(page.accent, 0.3), .width = 1.5, .hover = 0 };
    _ = quads.path.polyline(cx.drawing(), points[0 .. page.trail.len - split + 1], future, inside);

    const previous = cx.drawing().layer(scope.playhead_layer);
    defer _ = cx.drawing().layer(previous);
    for (page.goals, 0..) |goal, index| {
        const reached = if (page.goal) |at| at == index else false;
        const at = plane_point(goal);
        const size = if (reached) goal_size * 1.4 else goal_size;
        const ring: Rect = .{ .x = at[0] - size / 2, .y = at[1] - size / 2, .width = size, .height = size };
        const look: quads.BoxLook = .{
            .fill = with_alpha(ink, if (reached) 0.35 else 0.1),
            .border_color = with_alpha(ink, if (reached) 0.95 else 0.5),
            .border_width = 1.5,
            .radius = size / 2,
        };
        cx.append(quads.Box, null, .of(ring, inside, look)) catch {};
    }
    const head = plane_point(page.head);
    const dot: Rect = .{ .x = head[0] - place_size / 2, .y = head[1] - place_size / 2, .width = place_size, .height = place_size };
    const swatch = page.dot;
    const look: quads.BoxLook = .{
        .fill = .{ swatch[0], swatch[1], swatch[2], 1 },
        .border_color = ink,
        .border_width = 2,
        .radius = place_size / 2,
    };
    cx.append(quads.Box, null, .of(dot, inside, look)) catch {};
}

fn draw_strip(
    cx: anytype,
    strip: []const [3]f32,
    swatch: [3]f32,
    name: []const u8,
    note: []const u8,
    head_at: f32,
    rect: Rect,
    clip: Clip,
) void {
    assert(strip.len >= 2 and strip.len <= samples_max);
    const draw_cx = cx.drawing();
    text.place(draw_cx, name_style, name, .{ .x = rect.x, .y = rect.y, .width = label_width, .height = 20 }, clip, left);
    text.place(draw_cx, note_style, note, .{ .x = rect.x, .y = rect.y + 20, .width = label_width, .height = 18 }, clip, left);
    const swatch_rect: Rect = .{ .x = rect.x, .y = rect.y + 42, .width = swatch_size, .height = swatch_size };
    box(cx, swatch_rect, clip, .{ swatch[0], swatch[1], swatch[2], 1 }, 6);
    const plot: Rect = .{ .x = rect.x + label_width, .y = rect.y + 18, .width = rect.width - label_width, .height = strip_height };
    const inside = within(clip, plot) orelse return;
    box(cx, plot, clip, theme.dark.colors.panel, 4);
    const width = plot.width / @as(f32, @floatFromInt(strip.len));
    for (strip, 0..) |colour, index| {
        // Whole-pixel edges: two anti-aliased edges sharing a pixel would let the face show
        // through as a dark seam. Each cell runs past the plot and the clip cuts it square, so
        // no anti-aliased corner shows either.
        const x0 = @round(plot.x + width * @as(f32, @floatFromInt(index)));
        const x1 = @round(plot.x + width * @as(f32, @floatFromInt(index + 1)));
        const cell: Rect = .{ .x = x0, .y = plot.y - 4, .width = x1 - x0 + 1, .height = plot.height + 8 };
        box(cx, cell, inside, .{ colour[0], colour[1], colour[2], 1 }, 0);
    }
    const previous = cx.drawing().layer(scope.playhead_layer);
    defer _ = cx.drawing().layer(previous);
    const x = plot.x + head_at * plot.width;
    box(cx, .{ .x = x - 1, .y = plot.y - 4, .width = 2, .height = plot.height + 8 }, clip, ink, 0);
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

const testing = std.testing;

// Locks the plane's mapping: [0, 1] sits inside the padded square, with y up.
test "the plane maps the unit square inside its padding, y up" {
    const square = plane_square();
    const origin = plane_point(.{ 0, 0 });
    const corner = plane_point(.{ 1, 1 });
    try testing.expect(origin[0] > square.x and origin[1] < square.y + square.height);
    try testing.expect(corner[0] < square.x + square.width and corner[1] > square.y);
    try testing.expect(corner[1] < origin[1]);
    try testing.expectApproxEqAbs(square.x + square.width / 2, plane_point(.{ 0.5, 0.5 })[0], 1e-3);
}
