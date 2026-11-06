//! The shapes page's canvas: four figures drawn from the patch's eleven destination values.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Draws
//! The canvas is split in quarters, one figure each, and every figure reads only the values it is
//! handed, so this file does not know Weft or which source drives what:
//! ```text
//! lines     three strokes through the centre, 60 degrees apart, turned and widened
//! star      a closed path of 12 points, alternately at size and size * depth
//! pentagon  a filled pentagon in a hue blended through the accents, with an outline
//! curve     a cubic from the left middle to the right middle, control points at p1 and p2
//! ```
//!
//! ## 2. Geometry
//! Logical pixels, +y down; an angle of 0 points along +x and a positive angle turns toward +y.
//! The figures use `@sin` and `@cos`, which can round differently on native and wasm, within the
//! browser check's tolerance.
//!
//! ## 3. TigerStyle Invariants
//! - No allocation: points live in fixed stack arrays and the fill builder is static.
//! - Every append is checked by its pool; a refused one is counted, and the tests assert none.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const patch = @import("patch.zig");
const quads = patchwork.draw;
const text = patchwork.text;
const theme = patchwork.theme;
const fill = quads.fill;
const Rect = quads.Rect;
const Clip = quads.Clip;
const Point = quads.path.Point;
const Dest = patch.Dest;

pub const canvas: Rect = .{ .x = 368, .y = 56, .width = 904, .height = 656 };
const half_line: f32 = 160;
const star_width: f32 = 6;
const star_points = 12;
const ink = theme.dark.colors.text;
const caption_style: text.Style = .{ .face = .sans, .size = 12, .color = dim(ink) };
const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };

/// Static, so a frame's fill is not on the stack.
var shape: fill.Builder = undefined;

/// The quarter of the canvas at column `column` and row `row`.
pub fn quarter(column: u32, row: u32) Rect {
    assert(column < 2 and row < 2);
    const width = canvas.width / 2;
    const height = canvas.height / 2;
    return .{
        .x = canvas.x + width * @as(f32, @floatFromInt(column)),
        .y = canvas.y + height * @as(f32, @floatFromInt(row)),
        .width = width,
        .height = height,
    };
}

fn centre(rect: Rect) Point {
    return .{ rect.x + rect.width / 2, rect.y + rect.height / 2 };
}

/// The point at `radius` from `at` in the direction `angle`.
fn polar(at: Point, radius: f32, angle: f32) Point {
    return .{ at[0] + radius * @cos(angle), at[1] + radius * @sin(angle) };
}

/// Draws the four figures; `accents` are the four accent colours.
pub fn draw(cx: anytype, values: *const [patch.count]f32, accents: [4][4]f32, clip: Clip) void {
    for (0..2) |row| for (0..2) |column| {
        const rect = quarter(@intCast(column), @intCast(row));
        const inner: Rect = .{
            .x = rect.x + 4,
            .y = rect.y + 4,
            .width = rect.width - 8,
            .height = rect.height - 8,
        };
        const look: quads.BoxLook = .{ .fill = theme.dark.colors.panel, .radius = 8 };
        cx.append(quads.Box, null, .of(inner, clip, look)) catch {};
    };
    draw_lines(cx, quarter(0, 0), values, accents, clip);
    draw_star(cx, quarter(1, 0), values, accents[1], clip);
    draw_penta(cx, quarter(0, 1), values, accents, clip);
    draw_curve(cx, quarter(1, 1), values, accents[3], clip);
    const captions = [4][]const u8{ "lines", "star", "pentagon", "curve" };
    for (captions, 0..) |caption, index| {
        const rect = quarter(@intCast(index % 2), @intCast(index / 2));
        const at: Rect = .{ .x = rect.x + 16, .y = rect.y + 10, .width = 160, .height = 18 };
        text.place(cx.drawing(), caption_style, caption, at, clip, left);
    }
}

/// The value of destination `dest`.
fn value(values: *const [patch.count]f32, dest: Dest) f32 {
    return values[@backingInt(dest)];
}

/// The angle of point `index` of `count` round a circle, from straight up, turned by `angle`.
fn spoke(angle: f32, index: usize, count: usize) f32 {
    const share = @as(f32, @floatFromInt(index)) / @as(f32, @floatFromInt(count));
    return angle - std.math.pi / 2.0 + 2.0 * std.math.pi * share;
}

fn draw_lines(
    cx: anytype,
    rect: Rect,
    values: *const [patch.count]f32,
    accents: [4][4]f32,
    clip: Clip,
) void {
    const at = centre(rect);
    const angle = value(values, .lines_angle);
    for (0..3) |index| {
        const turn = angle + std.math.pi / 3.0 * @as(f32, @floatFromInt(index));
        const points = [2]Point{ polar(at, -half_line, turn), polar(at, half_line, turn) };
        const stroke: quads.path.Stroke = .{
            .color = with_alpha(accents[index], 0.85),
            .width = value(values, .lines_width),
            .hover = 0,
        };
        _ = quads.path.polyline(cx.drawing(), &points, stroke, clip);
    }
}

fn draw_star(
    cx: anytype,
    rect: Rect,
    values: *const [patch.count]f32,
    color: [4]f32,
    clip: Clip,
) void {
    const at = centre(rect);
    const size = value(values, .star_size);
    const inner = size * value(values, .star_depth);
    var points: [star_points]Point = undefined;
    for (&points, 0..) |*point, index| {
        const turn = spoke(value(values, .star_angle), index, star_points);
        point.* = polar(at, if (index % 2 == 0) size else inner, turn);
    }
    const stroke: quads.path.Stroke = .{ .color = color, .width = star_width, .hover = 0 };
    _ = quads.path.polygon(cx.drawing(), &points, stroke, clip);
}

fn draw_penta(
    cx: anytype,
    rect: Rect,
    values: *const [patch.count]f32,
    accents: [4][4]f32,
    clip: Clip,
) void {
    const at = centre(rect);
    var points: [5]Point = undefined;
    for (&points, 0..) |*point, index| {
        const turn = spoke(value(values, .penta_angle), index, points.len);
        point.* = polar(at, value(values, .penta_size), turn);
    }
    shape = .init(cx.drawing().text.device_scale());
    shape.move_to(points[0]);
    for (points[1..]) |point| shape.line_to(point);
    shape.close();
    const color = with_alpha(blend(accents, value(values, .penta_hue)), 0.85);
    _ = fill.append(cx.drawing(), &shape, .{ .color = color }, clip);
    shape.reset();
    const outline: quads.path.Stroke = .{ .color = ink, .width = 2, .hover = 0 };
    _ = quads.path.polygon(cx.drawing(), &points, outline, clip);
}

fn draw_curve(
    cx: anytype,
    rect: Rect,
    values: *const [patch.count]f32,
    color: [4]f32,
    clip: Clip,
) void {
    const y = rect.y + rect.height / 2;
    const x0 = rect.x + 28;
    const span = rect.width - 56;
    const control = [4]Point{
        .{ x0, y },
        .{ x0 + span / 3, value(values, .curve_p1) },
        .{ x0 + 2 * span / 3, value(values, .curve_p2) },
        .{ x0 + span, y },
    };
    const handles: quads.path.Stroke = .{ .color = dim(ink), .width = 1, .hover = 0 };
    _ = quads.path.polyline(cx.drawing(), &control, handles, clip);
    const stroke: quads.path.Stroke = .{
        .color = color,
        .width = value(values, .curve_width),
        .hover = 0,
    };
    _ = quads.path.cubic(cx.drawing(), control, stroke, clip);
    for (control[1..3]) |point| {
        const dot: Rect = .{ .x = point[0] - 4, .y = point[1] - 4, .width = 8, .height = 8 };
        cx.append(quads.Box, null, .of(dot, clip, .{ .fill = ink, .radius = 4 })) catch {};
    }
}

/// The colour at `hue` in [0, 1] on a cycle through the four accents.
pub fn blend(accents: [4][4]f32, hue: f32) [4]f32 {
    assert(hue >= 0 and hue <= 1);
    const at = hue * 4;
    const whole: u32 = @min(@as(u32, @intFromFloat(@floor(at))), 3);
    const part = at - @as(f32, @floatFromInt(whole));
    const from = accents[whole];
    const to = accents[(whole + 1) % 4];
    var result: [4]f32 = undefined;
    for (&result, from, to) |*channel, a, b| channel.* = a + (b - a) * part;
    return result;
}

fn with_alpha(color: [4]f32, alpha: f32) [4]f32 {
    return .{ color[0], color[1], color[2], alpha };
}

fn dim(color: [4]f32) [4]f32 {
    return with_alpha(color, 0.45);
}

const testing = std.testing;

// Locks the hue cycle: 0 is the first accent, a quarter the second, 1 the first again.
test "a hue blends through the accents and wraps" {
    const accents = [4][4]f32{ .{ 1, 0, 0, 1 }, .{ 0, 1, 0, 1 }, .{ 0, 0, 1, 1 }, .{ 1, 1, 1, 1 } };
    try testing.expectEqual(accents[0], blend(accents, 0));
    try testing.expectEqual(accents[1], blend(accents, 0.25));
    try testing.expectEqual(accents[0], blend(accents, 1));
    try testing.expectEqual([4]f32{ 0, 0.5, 0.5, 1 }, blend(accents, 0.375));
}
