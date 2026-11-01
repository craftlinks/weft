//! Weft: composable motion. Motion is an object of its own, apart from whatever it moves.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Contract
//! Every frame is a function of t: a reader supplies a `Time` and gets a value, and it cannot tell
//! how the value was computed. A `Wave` is the simplest case, and a graph of them is a `Program`
//! that each reader evaluates into a `State` of its own.
//!
//! ## 2. Rules That Hold From the First File
//! - Weft imports nothing but `std`, and links nothing. A client glues it to a destination.
//! - Everything here is realtime-safe: no allocation, no locks, no unbounded work.
//! - A sampled signal has the same bits on native and wasm, which `zig build regress` enforces.

pub const cue = @import("core/cue.zig");
pub const ease = @import("core/ease.zig");
pub const graph = @import("core/graph.zig");
pub const time = @import("core/time.zig");
pub const wave = @import("core/wave.zig");

pub const Cue = cue.Cue;
pub const Cues = cue.Cues;
pub const Ease = ease.Ease;
pub const Builder = graph.Builder;
pub const Extent = graph.Extent;
pub const Id = graph.Id;
pub const Node = graph.Node;
pub const Program = graph.Program;
pub const State = graph.State;
pub const Tween = graph.Tween;
pub const Rate = time.Rate;
pub const Time = time.Time;
pub const Shape = wave.Shape;
pub const Wave = wave.Wave;

test {
    _ = cue;
    _ = ease;
    _ = graph;
    _ = time;
    _ = wave;
}
