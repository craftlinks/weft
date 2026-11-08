//! The swarm page (the agent trial after Weft's step 17): forty-eight dots wandering a square, each
//! with a ghost a beat behind it, ringed while past a gate line, from plain numbers.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Draws
//! A `Page` is the program already read at t (`glue.zig`, section 9): each dot's place and its
//! ghost's in the program's -1..1 both ways, its colour in sRGB, and whether it is at or past the gate line.
//! This file does not know Weft, so it draws any numbers.
//! ```text
//! x 332..948, y 56..672   the arena: x and y in [-1.25, 1.25], y up, a faint cross at 0
//! x = gate                the gate line, vertical, past which a dot is ringed
//! y 680..704              the line under it: how many dots are past the gate
//! ```
//! A dot is a circle of 12 px in its colour with a thread to its ghost, a circle of 7 px at 40% in
//! the same colour: the thread is the lag, long when the dot moves fast. A lit dot has a ring of 26 px
//! in the page's ink, on the scope's `playhead_layer` above the dots.
//!
//! ## 2. TigerStyle Invariants
//! - At most one thread, two circles, and one ring a dot a frame, plus the arena and its lines;
//!   every append is checked by its pool, a refused one is dropped, and the tests assert none.

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

pub const count = 48;
pub const arena_rect: Rect = .{ .x = 332, .y = 56, .width = 616, .height = 616 };
const line_rect: Rect = .{ .x = 332, .y = 680, .width = 616, .height = 24 };
/// How far past [-1, 1] the arena reaches each way, so an overshoot stays in it.
pub const reach: f32 = 1.25;

const ink = theme.dark.colors.text;
const line_style: text.Style = .{ .face = .sans, .size = 13, .color = with_alpha(ink, 0.7) };
const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };

pub const Page = struct {
    places: []const [2]f32,
    ghosts: []const [2]f32,
    tints: []const [3]f32,
    /// 1 for a dot at or past the gate line, else 0.
    lit: []const f32,
    /// The gate line's x.
    gate: f32,
};

pub fn draw(cx: anytype, page: Page, clip: Clip) void {
    assert(page.places.len == count and page.ghosts.len == count);
    assert(page.tints.len == count and page.lit.len == count);
    const inside = within(clip, arena_rect) orelse return;
    box(cx, arena_rect, clip, theme.dark.colors.panel, 8, 0, ink);
    const centre = point(.{ 0, 0 });
    box(cx, .{ .x = centre[0] - 0.5, .y = arena_rect.y, .width = 1, .height = arena_rect.height }, inside, with_alpha(ink, 0.1), 0, 0, ink);
    box(cx, .{ .x = arena_rect.x, .y = centre[1] - 0.5, .width = arena_rect.width, .height = 1 }, inside, with_alpha(ink, 0.1), 0, 0, ink);
    const gate = point(.{ page.gate, 0 })[0];
    box(cx, .{ .x = gate - 0.75, .y = arena_rect.y, .width = 1.5, .height = arena_rect.height }, inside, with_alpha(ink, 0.35), 0, 0, ink);
    for (page.places, page.ghosts, page.tints) |place, ghost, tint| {
        const colour: [4]f32 = .{ tint[0], tint[1], tint[2], 1 };
        const thread: quads.path.Stroke = .{ .color = with_alpha(colour, 0.5), .width = 1.5, .hover = 0 };
        _ = quads.path.polyline(cx.drawing(), &.{ point(ghost), point(place) }, thread, inside);
        circle(cx, point(ghost), 7, with_alpha(colour, 0.4), inside);
        circle(cx, point(place), 12, colour, inside);
    }
    const previous = cx.drawing().layer(scope.playhead_layer);
    defer _ = cx.drawing().layer(previous);
    var past: u32 = 0;
    for (page.places, page.lit) |place, lit| {
        if (lit <= 0) continue;
        past += 1;
        const centred = point(place);
        const ring: Rect = .{ .x = centred[0] - 13, .y = centred[1] - 13, .width = 26, .height = 26 };
        box(cx, ring, inside, .{ 0, 0, 0, 0 }, 13, 2, with_alpha(ink, 0.9));
    }
    var buffer: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{d} wanderers of one program: {d} at or past the gate line", .{ count, past }) catch unreachable;
    text.place(cx.drawing(), line_style, line, line_rect, clip, left);
}

/// Where a program point (x right, y up, both in -1..1 and a little past) lands in the arena.
pub fn point(value: [2]f32) Point {
    const unit_x = (value[0] + reach) / (2 * reach);
    const unit_y = (value[1] + reach) / (2 * reach);
    return .{
        arena_rect.x + unit_x * arena_rect.width,
        arena_rect.y + arena_rect.height - unit_y * arena_rect.height,
    };
}

fn circle(cx: anytype, centre: Point, side: f32, fill: [4]f32, clip: Clip) void {
    const rect: Rect = .{ .x = centre[0] - side / 2, .y = centre[1] - side / 2, .width = side, .height = side };
    box(cx, rect, clip, fill, side / 2, 0, ink);
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

fn box(cx: anytype, rect: Rect, clip: Clip, fill: [4]f32, radius: f32, border: f32, border_color: [4]f32) void {
    const look: quads.BoxLook = .{ .fill = fill, .radius = radius, .border_width = border, .border_color = border_color };
    cx.append(quads.Box, null, .of(rect, clip, look)) catch {};
}

fn with_alpha(color: [4]f32, alpha: f32) [4]f32 {
    return .{ color[0], color[1], color[2], alpha };
}

const testing = std.testing;

// Locks section 1's layout: the origin is the arena's centre, +x goes right and +y goes up, and
// the reach lands on its edges.
test "the arena maps program points, y up" {
    const middle = point(.{ 0, 0 });
    try testing.expectEqual(arena_rect.x + arena_rect.width / 2, middle[0]);
    try testing.expectEqual(arena_rect.y + arena_rect.height / 2, middle[1]);
    try testing.expectEqual(arena_rect.x + arena_rect.width, point(.{ reach, 0 })[0]);
    try testing.expectEqual(arena_rect.y, point(.{ 0, reach })[1]);
}
