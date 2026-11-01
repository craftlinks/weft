//! Weft: composable motion. Motion is an object of its own, apart from whatever it moves.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Contract
//! Every frame is a function of t: a reader supplies a `Time` and gets a value, and it cannot tell
//! how the value was computed. So far that is `Wave`; the signal graph comes next.
//!
//! ## 2. Rules That Hold From the First File
//! - Weft imports nothing but `std`, and links nothing. A client glues it to a destination.
//! - Everything here is realtime-safe: no allocation, no locks, no unbounded work.
//! - A sampled signal has the same bits on native and wasm, which `zig build regress` enforces.

pub const time = @import("core/time.zig");
pub const wave = @import("core/wave.zig");

pub const Rate = time.Rate;
pub const Time = time.Time;
pub const Shape = wave.Shape;
pub const Wave = wave.Wave;

test {
    _ = time;
    _ = wave;
}
