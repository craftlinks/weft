//! The patch: the shapes page's destinations, and how a source's value reaches one.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Sources Apart From Destinations
//! A destination is a parameter of a figure: a name, an output range, and the source it reads by
//! default. A source is any row of the signal table. The app holds which row each destination
//! reads, so re-pointing one is an index change: the program, its readers, and their checkpoints
//! do not change. This file does not know Weft; it maps plain numbers.
//!
//! ## 2. Through the Declared Range
//! A source's value v reaches a destination through the source's declared range `[low, high]`:
//! ```text
//! u    = (v - low) / (high - low)        in [0, 1]
//! dest = lo + u * (hi - lo)              clamped to [lo, hi]
//! ```
//! The declared range is never left, so u is in `[0, 1]` for any source at any time, which
//! `fraction` asserts. That holds in f32 too: the cast to f32 rounds to nearest, which is
//! monotone, so a value inside the range stays inside the cast range, and so do the subtraction
//! and the division. Only `lo + u * (hi - lo)` can round past `hi`, by an ulp, which the clamp
//! takes back. A source needs a finite range, which every row has (a test checks).
//!
//! ## 3. TigerStyle Invariants
//! - The table is comptime and checked: every range has a width, and every default source names
//!   a row the app resolves at init.

const std = @import("std");
const assert = std.debug.assert;

pub const Destination = struct {
    name: []const u8,
    low: f32,
    high: f32,
    /// The name of the row it reads by default.
    source: []const u8,
};

pub const Dest = enum(u8) {
    lines_angle,
    lines_width,
    star_size,
    star_angle,
    star_depth,
    penta_size,
    penta_angle,
    penta_hue,
    curve_p1,
    curve_p2,
    curve_width,
};

pub const count = @typeInfo(Dest).@"enum".field_names.len;

/// The curve's control points move in this band of the canvas's lower right quarter.
pub const curve_low: f32 = 404;
pub const curve_high: f32 = 692;

const third_turn = std.math.pi / 3.0;

pub const destinations = [count]Destination{
    .{ .name = "lines.angle", .low = -third_turn, .high = third_turn, .source = "sway" },
    .{ .name = "lines.width", .low = 2, .high = 24, .source = "pulse" },
    .{ .name = "star.size", .low = 60, .high = 140, .source = "soft" },
    .{ .name = "star.angle", .low = -third_turn, .high = third_turn, .source = "sway" },
    .{ .name = "star.depth", .low = 0.35, .high = 1, .source = "snappy" },
    .{ .name = "penta.size", .low = 50, .high = 140, .source = "pulse" },
    .{ .name = "penta.angle", .low = -std.math.pi, .high = std.math.pi, .source = "drift" },
    .{ .name = "penta.hue", .low = 0, .high = 1, .source = "bouncy" },
    .{ .name = "curve.p1", .low = curve_low, .high = curve_high, .source = "glide_a" },
    .{ .name = "curve.p2", .low = curve_low, .high = curve_high, .source = "glide_b" },
    .{ .name = "curve.width", .low = 2, .high = 20, .source = "snappy" },
};

comptime {
    for (destinations) |destination| assert(destination.low < destination.high);
}

/// Where `value` sits in `range`, in [0, 1] (section 2).
pub fn fraction(value: f32, range: [2]f32) f32 {
    assert(std.math.isFinite(range[0]) and std.math.isFinite(range[1]));
    assert(range[0] < range[1]);
    const result = (value - range[0]) / (range[1] - range[0]);
    assert(result >= 0);
    assert(result <= 1);
    return result;
}

/// The value `destination` takes from a source whose value is `value` in `range` (section 2).
pub fn map(destination: Destination, value: f32, range: [2]f32) f32 {
    const at = fraction(value, range);
    const result = destination.low + at * (destination.high - destination.low);
    return std.math.clamp(result, destination.low, destination.high);
}

const testing = std.testing;

// Locks the map's ends: a source at its low end gives the destination's low, at its high end the
// destination's high, and the middle the middle.
test "a source's range maps onto a destination's" {
    const width = destinations[@backingInt(Dest.lines_width)];
    try testing.expectEqual(@as(f32, 2), map(width, -1, .{ -1, 1 }));
    try testing.expectEqual(@as(f32, 24), map(width, 1, .{ -1, 1 }));
    try testing.expectEqual(@as(f32, 13), map(width, 0, .{ -1, 1 }));
    try testing.expectEqual(@as(f32, 0.5), fraction(0.5, .{ 0, 1 }));
}
