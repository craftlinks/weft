//! The lanes page (Weft's step 17): a field of a thousand dots, one a lane of one program, each
//! its own size and colour, flashing at its own hits, from plain numbers.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Draws
//! A `Page` is the program already read at t (`glue.zig`, section 8): each lane's size in [0, 1],
//! its colour in sRGB, and how much it still flashes. This file does not know Weft, so it draws
//! any numbers. Lane l sits at column `l % columns` and row `l / columns`.
//! ```text
//! x 140..1140, y 56..681   the field: 40 columns and 25 rows of 25 px on a face
//! y 688..712               the line under it: the lanes, and the flash window's events and drops
//! ```
//! A dot is a circle of up to 90% of its cell, its size times that, in its colour. A flash is a
//! ring the full 90% of the cell, its ink's alpha the flash, on the scope's `playhead_layer` above
//! the dots.
//!
//! ## 2. TigerStyle Invariants
//! - One Box a dot and one a flashing ring, at most `2 * count + 1` a frame; every append is
//!   checked by its pool, a refused one is dropped, and the tests assert none.

const std = @import("std");
const assert = std.debug.assert;
const patchwork = @import("patchwork");
const scope = @import("scope.zig");
const quads = patchwork.draw;
const text = patchwork.text;
const theme = patchwork.theme;
const Rect = quads.Rect;
const Clip = quads.Clip;

pub const count = 1000;
pub const columns = 40;
pub const rows = count / columns;
pub const cell: f32 = 25;
pub const field_rect: Rect = .{ .x = 140, .y = 56, .width = columns * cell, .height = rows * cell };
const line_rect: Rect = .{ .x = 140, .y = 688, .width = columns * cell, .height = 24 };

const ink = theme.dark.colors.text;
const line_style: text.Style = .{ .face = .sans, .size = 13, .color = with_alpha(ink, 0.7) };
const left: text.Options = .{ .align_x = .start, .align_y = .center, .ellipsis = true };

comptime {
    assert(rows * columns == count);
}

pub const Page = struct {
    sizes: []const f32,
    tints: []const [3]f32,
    flashes: []const f32,
    /// Events in the flash window, every lane's, and the ones its buffer dropped.
    events: u32,
    dropped: u64,
    flash_ms: u32,
};

pub fn draw(cx: anytype, page: Page, clip: Clip) void {
    assert(page.sizes.len == count);
    assert(page.tints.len == count and page.flashes.len == count);
    const inside = within(clip, field_rect) orelse return;
    box(cx, field_rect, clip, theme.dark.colors.panel, 8, 0, ink);
    for (page.sizes, page.tints, 0..) |size, tint, lane| {
        const side = cell * 0.9 * std.math.clamp(size, 0, 1);
        if (side < 0.5) continue;
        box(cx, square(lane, side), inside, .{ tint[0], tint[1], tint[2], 1 }, side / 2, 0, ink);
    }
    const previous = cx.drawing().layer(scope.playhead_layer);
    defer _ = cx.drawing().layer(previous);
    for (page.flashes, 0..) |flash, lane| {
        if (flash <= 0) continue;
        const side = cell * 0.9;
        box(cx, square(lane, side), inside, .{ 0, 0, 0, 0 }, side / 2, 2, with_alpha(ink, std.math.clamp(flash, 0, 1)));
    }
    var buffer: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "1,000 lanes of one program: {d} events in the last {d} ms, {d} dropped", .{
        page.events,
        page.flash_ms,
        page.dropped,
    }) catch unreachable;
    text.place(cx.drawing(), line_style, line, line_rect, clip, left);
}

/// The square of side `side` centred in lane `lane`'s cell (section 1).
pub fn square(lane: usize, side: f32) Rect {
    assert(lane < count);
    const column: f32 = @floatFromInt(lane % columns);
    const row: f32 = @floatFromInt(lane / columns);
    return .{
        .x = field_rect.x + (column + 0.5) * cell - side / 2,
        .y = field_rect.y + (row + 0.5) * cell - side / 2,
        .width = side,
        .height = side,
    };
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

// Locks section 1's layout: lane 0 is the top left cell, lane 39 the top right, lane 40 the
// second row's first, and the last lane the bottom right, all inside the field.
test "lanes fill the field row by row" {
    const first = square(0, cell);
    try testing.expectEqual(field_rect.x, first.x);
    try testing.expectEqual(field_rect.y, first.y);
    try testing.expectEqual(field_rect.x + 39 * cell, square(39, cell).x);
    try testing.expectEqual(field_rect.y + cell, square(40, cell).y);
    const last = square(count - 1, cell);
    try testing.expectEqual(field_rect.x + field_rect.width, last.x + last.width);
    try testing.expectEqual(field_rect.y + field_rect.height, last.y + last.height);
}
