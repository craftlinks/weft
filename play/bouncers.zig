//! The bouncers page: seven lanes, each a bouncer over the scope's window, and a log of hits,
//! from plain numbers.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Draws
//! A `Lane` is one bouncer already read at t: its polyline over the window, the bars, the playhead
//! and its value there, and how much its last wall still flashes. This file does not know Weft, so
//! it draws any numbers; the glue (`glue.zig`, section 6) says where they come from.
//! ```text
//! | name     wall  |  plot face, bar lines, the triangle, a dot at each corner, the playhead  |
//! | note     ball  |                                                                          |
//! |          wall  |                                                                          |
//!   label_width                    the rest of the row, inset as the scope's
//! ```
//! A lane's polyline runs from its value at the window's start through a corner at each hit, on
//! the wall it hit, to its value at the end, as fractions of the window and values in [0, 1]. A
//! bounce is linear between hits, so the stroke is the signal; every point but the two ends is a
//! hit, and gets a dot. The small bouncer beside it is the ball at the playhead between two walls.
//!
//! ## 2. Back to Front
//! As in the scope: the face and the bar lines are Boxes, the triangle and the walls are Paths,
//! on the base layer; the dots, the playhead, and the ball are Boxes on the scope's
//! `playhead_layer`, above them.
//!
//! ## 3. The Flash
//! A flash is `1 - since / flash_s`, clamped to [0, 1], from the seconds since the lane's last hit
//! at or before t. It thickens and brightens the wall it hit and grows the ball, so it is a
//! function of t like everything else: paused, scrubbed, or at any frame rate, a time shows the
//! same flash.
//!
//! ## 4. TigerStyle Invariants
//! - Points live in fixed stack arrays of `points_max`; a lane asserts it fits.
//! - Every append is checked by its pool; a refused one is counted, and the tests assert none.

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

pub const lane_height: f32 = 80;
pub const log_y: f32 = 616;
pub const log_lines = 6;
pub const log_pitch: f32 = 16;
/// Seconds a wall flashes after a hit.
pub const flash_s: f32 = 0.25;
/// The most points of a lane's polyline: its two ends and up to 22 hits in a window of 4 s.
pub const points_max = 24;
/// A lane's axis: [0, 1] padded as the scope pads a finite range.
pub const axis: [2]f32 = .{ -scope.axis_pad, 1 + scope.axis_pad };
/// The small bouncer's column in the label column, and its walls' heights in the row.
const column_x: f32 = 148;
const column_width: f32 = 40;
const wall_top: f32 = 12;
const wall_bottom: f32 = 68;
const ball_size: f32 = 14;

const ink = theme.dark.colors.text;
const name_style: text.Style = .{ .face = .sans_bold, .size = 14, .color = ink };
const note_style: text.Style = .{ .face = .sans, .size = 12, .color = with_alpha(ink, 0.45) };
const log_style: text.Style = .{ .face = .mono, .size = 13, .color = ink };
const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };

pub const Lane = struct {
    name: []const u8,
    note: []const u8,
    color: [4]f32,
    /// Fractions of the window and values in [0, 1] (section 1).
    points: []const [2]f32,
    /// Fractions of the window.
    bars: []const f32,
    head_at: f32,
    head: f32,
    /// How much the last hit still flashes (section 3), and whether it was the top wall.
    flash: f32,
    high: bool,
};

/// The flash `since` seconds after a hit (section 3).
pub fn flash(since: f32) f32 {
    assert(since >= 0);
    return std.math.clamp(1 - since / flash_s, 0, 1);
}

/// Lane `lane`'s polyline (section 1): `start`, a corner at each of its hits on the wall it hit,
/// then `end`. `hits` are the window's, in order, each with `lane`, `at`, and `high`.
pub fn polyline(
    start: f32,
    end: f32,
    hits: anytype,
    lane: usize,
    out: *[points_max][2]f32,
) []const [2]f32 {
    assert(start >= 0 and start <= 1);
    assert(end >= 0 and end <= 1);
    out[0] = .{ 0, start };
    var count: usize = 1;
    for (hits) |hit| {
        if (hit.lane != lane) continue;
        assert(count < points_max - 1);
        assert(hit.at >= out[count - 1][0]);
        out[count] = .{ hit.at, if (hit.high) 1 else 0 };
        count += 1;
    }
    out[count] = .{ 1, end };
    return out[0 .. count + 1];
}

/// The rect of lane `index`, below the transport.
pub fn lane_rect(top: f32, width: f32, index: usize) Rect {
    const y = top + lane_height * @as(f32, @floatFromInt(index));
    return .{ .x = 0, .y = y, .width = width, .height = lane_height };
}

pub fn draw(cx: anytype, lane: Lane, rect: Rect, clip: Clip) void {
    assert(lane.points.len >= 2);
    assert(lane.points.len <= points_max);
    assert(lane.flash >= 0 and lane.flash <= 1);
    draw_labels(cx, lane, rect, clip);
    draw_ball(cx, lane, rect, clip);
    const plot = scope.plot_rect(rect);
    const inside = within(clip, plot) orelse return;
    box(cx, plot, clip, theme.dark.colors.panel, 4);
    for (lane.bars) |at| {
        assert(at >= 0 and at <= 1);
        const x = plot.x + at * plot.width;
        const line: Rect = .{ .x = x - 0.5, .y = plot.y, .width = 1, .height = plot.height };
        box(cx, line, inside, with_alpha(ink, 0.3), 0);
    }
    var points: [points_max]Point = undefined;
    var count: usize = 0;
    for (lane.points) |point| {
        assert(point[0] >= 0 and point[0] <= 1);
        const at: Point = .{ plot.x + point[0] * plot.width, scope.y_of(point[1], plot, axis) };
        // A hit exactly at the window's end is also its end point; keep one.
        if (count > 0 and std.meta.eql(points[count - 1], at)) continue;
        points[count] = at;
        count += 1;
    }
    const stroke: quads.path.Stroke = .{ .color = lane.color, .width = 2, .hover = 0 };
    if (count >= 2) _ = quads.path.polyline(cx.drawing(), points[0..count], stroke, inside);
    const previous = cx.drawing().layer(scope.playhead_layer);
    defer _ = cx.drawing().layer(previous);
    for (lane.points[1 .. lane.points.len - 1]) |point| {
        const x = plot.x + point[0] * plot.width;
        const y = scope.y_of(point[1], plot, axis);
        const size = scope.dot_size;
        const dot: Rect = .{ .x = x - size / 2, .y = y - size / 2, .width = size, .height = size };
        box(cx, dot, inside, with_alpha(ink, 0.9), size / 2);
    }
    const x = plot.x + lane.head_at * plot.width;
    const line: Rect = .{ .x = x - 0.75, .y = plot.y, .width = 1.5, .height = plot.height };
    box(cx, line, inside, with_alpha(ink, 0.6), 0);
}

/// The small bouncer: two walls, the one last hit flashing, and the ball between them.
fn draw_ball(cx: anytype, lane: Lane, rect: Rect, clip: Clip) void {
    assert(lane.head >= 0 and lane.head <= 1);
    for ([2]bool{ true, false }) |high| {
        const lit = if (high == lane.high) lane.flash else 0;
        const y = rect.y + if (high) wall_top else wall_bottom;
        const x = rect.x + column_x;
        const wall = [2]Point{ .{ x, y }, .{ x + column_width, y } };
        const stroke: quads.path.Stroke = .{
            .color = with_alpha(lane.color, 0.35 + 0.65 * lit),
            .width = 2 + 4 * lit,
            .hover = 0,
        };
        _ = quads.path.polyline(cx.drawing(), &wall, stroke, clip);
    }
    const previous = cx.drawing().layer(scope.playhead_layer);
    defer _ = cx.drawing().layer(previous);
    const size = ball_size * (1 + 0.4 * lane.flash);
    const centre_y = rect.y + wall_bottom + (wall_top - wall_bottom) * lane.head;
    const ball: Rect = .{
        .x = rect.x + column_x + column_width / 2 - size / 2,
        .y = centre_y - size / 2,
        .width = size,
        .height = size,
    };
    box(cx, ball, clip, lane.color, size / 2);
}

fn draw_labels(cx: anytype, lane: Lane, rect: Rect, clip: Clip) void {
    const draw_cx = cx.drawing();
    var line: Rect = .{ .x = rect.x + 12, .y = rect.y + 8, .width = 128, .height = 20 };
    text.place(draw_cx, name_style, lane.name, line, clip, left);
    line.y += 22;
    line.height = 18;
    text.place(draw_cx, note_style, lane.note, line, clip, left);
}

/// The log: one line of text each, from `log_y`.
pub fn draw_log(cx: anytype, lines: []const []const u8, width: f32, clip: Clip) void {
    assert(lines.len <= log_lines);
    for (lines, 0..) |line, index| {
        const y = log_y + log_pitch * @as(f32, @floatFromInt(index));
        const rect: Rect = .{ .x = 16, .y = y, .width = width - 32, .height = log_pitch };
        text.place(cx.drawing(), log_style, line, rect, clip, left);
    }
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

// Locks the flash: full at the hit, half at 125 ms, gone at 250 ms and after.
test "a flash fades over a quarter second" {
    try testing.expectEqual(@as(f32, 1), flash(0));
    try testing.expectEqual(@as(f32, 0.5), flash(0.125));
    try testing.expectEqual(@as(f32, 0), flash(0.25));
    try testing.expectEqual(@as(f32, 0), flash(std.math.inf(f32)));
}
