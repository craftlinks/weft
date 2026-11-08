//! Colour: OKLab, the space Weft stores a colour in, and the sRGB a client draws with.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Why OKLab
//! A colour is three components, so a tween or a spring moves each on its own (`graph.zig`,
//! section 15). In OKLab that is a straight line through a space built so that equal steps look
//! equal: lightness moves evenly, and a path between two colours passes through no unrelated
//! hue. In sRGB the same line darkens and greys in the middle. So Weft stores OKLab, converts a
//! colour written in sRGB once, at compile time, and a client converts back when it draws.
//!
//! ## 2. The Conversion
//! Björn Ottosson's: encoded sRGB to linear by the sRGB transfer curve, linear to cone responses
//! by one matrix, a cube root, then to `L a b` by a second matrix. The two forward matrices are
//! his published numbers; their inverses are worked out from them at compile time, not copied,
//! since the published inverses have ten decimals and are inverses only to about 1e-7, which the
//! transfer curve multiplies by up to 13 in a dark channel. So a round trip is exact to rounding.
//! The cube root and the curve's power are `elementary.exp` and `elementary.log`, so a colour
//! literal gives the same bits on every target, as Weft's constants must.
//!
//! ## 3. The Gamut
//! Not every OKLab colour has an sRGB one: a spring that overshoots, or a straight line between
//! two saturated colours, can leave the sRGB gamut. `to_srgb` keeps the lightness, clamped into
//! [0, 1], and the hue, and lowers the chroma by bisection until the colour fits, so a client
//! always gets something it can draw, as close as the gamut allows.
//!
//! ## 4. TigerStyle Invariants
//! - Pure functions of their arguments; the bisection runs `gamut_rounds` rounds at most.

const std = @import("std");
const assert = std.debug.assert;
const elementary = @import("elementary.zig");

/// OKLab: lightness 0 to 1, then the two opponent axes, about -0.4 to 0.4.
pub const Lab = [3]f64;
/// Red, green, and blue, each 0 to 1, encoded with the sRGB transfer curve unless named linear.
pub const Rgb = [3]f64;

/// Rounds of the chroma bisection: 2^-40 of the chroma is far below what a client can show.
pub const gamut_rounds = 40;

/// OKLab of an encoded sRGB colour (section 2).
pub fn from_srgb(rgb: Rgb) Lab {
    var linear: Rgb = undefined;
    for (&linear, rgb) |*out, value| out.* = to_linear(value);
    return from_linear(linear);
}

/// An encoded sRGB colour of `lab`, in the gamut (section 3).
pub fn to_srgb(lab: Lab) Rgb {
    assert(std.math.isFinite(lab[0]) and std.math.isFinite(lab[1]) and std.math.isFinite(lab[2]));
    const lightness = std.math.clamp(lab[0], 0, 1);
    var linear = to_linear_rgb(.{ lightness, lab[1], lab[2] });
    if (!inside(linear)) {
        var low: f64 = 0;
        var high: f64 = 1;
        for (0..gamut_rounds) |_| {
            const middle = (low + high) / 2;
            if (inside(to_linear_rgb(.{ lightness, lab[1] * middle, lab[2] * middle }))) low = middle else high = middle;
        }
        linear = to_linear_rgb(.{ lightness, lab[1] * low, lab[2] * low });
    }
    var out: Rgb = undefined;
    for (&out, linear) |*value, channel| value.* = from_linear_channel(std.math.clamp(channel, 0, 1));
    return out;
}

const Matrix = [3][3]f64;

/// Linear sRGB to cone responses, as published.
const to_cones: Matrix = .{
    .{ 0.4122214708, 0.5363325363, 0.0514459929 },
    .{ 0.2119034982, 0.6806995451, 0.1073969566 },
    .{ 0.0883024619, 0.2817188376, 0.6299787005 },
};

/// Cube-rooted cone responses to `L a b`, as published.
const to_lab: Matrix = .{
    .{ 0.2104542553, 0.7936177850, -0.0040720468 },
    .{ 1.9779984951, -2.4285922050, 0.4505937099 },
    .{ 0.0259040371, 0.7827717662, -0.8086757660 },
};

const from_cones: Matrix = inverse(to_cones);
const from_lab: Matrix = inverse(to_lab);

/// OKLab of a linear sRGB colour.
pub fn from_linear(linear: Rgb) Lab {
    var cones = apply(to_cones, linear);
    for (&cones) |*cone| cone.* = cube_root(cone.*);
    return apply(to_lab, cones);
}

/// The linear sRGB colour of `lab`, which may be outside [0, 1].
pub fn to_linear_rgb(lab: Lab) Rgb {
    var cones = apply(from_lab, lab);
    for (&cones) |*cone| cone.* = cone.* * cone.* * cone.*;
    return apply(from_cones, cones);
}

fn apply(matrix: Matrix, vector: [3]f64) [3]f64 {
    var out: [3]f64 = undefined;
    for (&out, matrix) |*value, row| value.* = row[0] * vector[0] + row[1] * vector[1] + row[2] * vector[2];
    return out;
}

/// The inverse of a 3 by 3 matrix, by its adjugate, at compile time.
fn inverse(comptime matrix: Matrix) Matrix {
    @setEvalBranchQuota(10_000);
    const m = matrix;
    const cofactors: Matrix = .{
        .{ m[1][1] * m[2][2] - m[1][2] * m[2][1], m[1][2] * m[2][0] - m[1][0] * m[2][2], m[1][0] * m[2][1] - m[1][1] * m[2][0] },
        .{ m[0][2] * m[2][1] - m[0][1] * m[2][2], m[0][0] * m[2][2] - m[0][2] * m[2][0], m[0][1] * m[2][0] - m[0][0] * m[2][1] },
        .{ m[0][1] * m[1][2] - m[0][2] * m[1][1], m[0][2] * m[1][0] - m[0][0] * m[1][2], m[0][0] * m[1][1] - m[0][1] * m[1][0] },
    };
    const determinant = m[0][0] * cofactors[0][0] + m[0][1] * cofactors[0][1] + m[0][2] * cofactors[0][2];
    var result: Matrix = undefined;
    for (0..3) |row| for (0..3) |column| {
        result[row][column] = cofactors[column][row] / determinant;
    };
    return result;
}

/// A channel of encoded sRGB, as linear light.
pub fn to_linear(value: f64) f64 {
    if (value <= 0.04045) return value / 12.92;
    return power((value + 0.055) / 1.055, 2.4);
}

/// A channel of linear light in [0, 1], encoded for sRGB.
fn from_linear_channel(value: f64) f64 {
    assert(value >= 0 and value <= 1);
    if (value <= 0.0031308) return value * 12.92;
    return 1.055 * power(value, 1.0 / 2.4) - 0.055;
}

/// Whether a linear colour is inside the sRGB gamut, with room for the matrices' rounding.
fn inside(linear: Rgb) bool {
    const slack = 1e-6;
    for (linear) |channel| if (channel < -slack or channel > 1 + slack) return false;
    return true;
}

/// `x^y` for `x > 0` through Weft's own exponential and logarithm (section 2), 0 at 0.
fn power(x: f64, y: f64) f64 {
    assert(x >= 0);
    if (x == 0) return 0;
    return elementary.exp(y * elementary.log(x));
}

/// The real cube root, through `power`, keeping the sign.
fn cube_root(x: f64) f64 {
    if (x < 0) return -power(-x, 1.0 / 3.0);
    return power(x, 1.0 / 3.0);
}

const testing = std.testing;

fn expect_close(expected: [3]f64, found: [3]f64, tolerance: f64) !void {
    for (expected, found) |a, b| try testing.expectApproxEqAbs(a, b, tolerance);
}

// Locks section 2 against Ottosson's published values: white, black, and the sRGB primaries.
test "OKLab of white, black, and the primaries" {
    try expect_close(.{ 1, 0, 0 }, from_srgb(.{ 1, 1, 1 }), 1e-4);
    try expect_close(.{ 0, 0, 0 }, from_srgb(.{ 0, 0, 0 }), 1e-9);
    try expect_close(.{ 0.627955, 0.224863, 0.125846 }, from_srgb(.{ 1, 0, 0 }), 1e-4);
    try expect_close(.{ 0.866440, -0.233888, 0.179498 }, from_srgb(.{ 0, 1, 0 }), 1e-4);
    try expect_close(.{ 0.452014, -0.032457, -0.311528 }, from_srgb(.{ 0, 0, 1 }), 1e-4);
}

// Locks the round trip: 1,000 seeded colours inside the gamut come back to within 1e-9, since the
// inverses are worked out from the forward matrices (section 2).
test "sRGB to OKLab and back is exact to 1e-9" {
    var prng = std.Random.DefaultPrng.init(0xc0_10_0e);
    const random = prng.random();
    for (0..1000) |_| {
        const rgb: Rgb = .{ random.float(f64), random.float(f64), random.float(f64) };
        try expect_close(rgb, to_srgb(from_srgb(rgb)), 1e-9);
    }
}

// Locks section 3: a colour far outside the gamut lands inside it with its lightness, and a
// lightness above 1 or below 0 is clamped. The published matrices put sRGB white at L 0.99999997,
// so OKLab's L of 1 is white to 1e-7.
test "a colour outside the gamut keeps its lightness and fits" {
    const vivid: Lab = .{ 0.7, 0.4, 0.3 };
    const drawn = to_srgb(vivid);
    for (drawn) |channel| try testing.expect(channel >= 0 and channel <= 1);
    try testing.expectApproxEqAbs(@as(f64, 0.7), from_srgb(drawn)[0], 1e-6);
    try expect_close(.{ 1, 1, 1 }, to_srgb(.{ 1.3, 0, 0 }), 1e-7);
    try expect_close(.{ 0, 0, 0 }, to_srgb(.{ -0.2, 0, 0 }), 1e-9);
}

// Locks section 2's inverses against Ottosson's published ones, to their ten decimals.
test "the inverses agree with the published ones" {
    const published_lab: Matrix = .{
        .{ 1, 0.3963377774, 0.2158037573 },
        .{ 1, -0.1055613458, -0.0638541728 },
        .{ 1, -0.0894841775, -1.2914855480 },
    };
    const published_cones: Matrix = .{
        .{ 4.0767416621, -3.3077115913, 0.2309699292 },
        .{ -1.2684380046, 2.6097574011, -0.3413193965 },
        .{ -0.0041960863, -0.7034186147, 1.7076147010 },
    };
    for (from_lab, published_lab) |row, expected| try expect_close(expected, row, 1e-7);
    for (from_cones, published_cones) |row, expected| try expect_close(expected, row, 1e-7);
}
