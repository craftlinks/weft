//! The language's own numbers: a file's limits, and the constants the front end shares with a
//! back end. A back end asserts the ones it also has (Weft's `table.zig`).
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! This file imports only `std`, like the rest of the module. Weft passes nothing in for these:
//! it asserts, at comptime in `src/lang/table.zig`, that its core's own numbers equal them, so a
//! drift fails the build. `Limits` is what a caller gives a compile: how large a file may be.

const std = @import("std");

/// A second in flicks, the unit a time literal is read into.
pub const flicks_per_second: i64 = 705_600_000;
/// The most lanes a region has.
pub const lanes_max = 1 << 20;
/// The powers `pow(x, n)` takes.
pub const power_min = 2;
pub const power_max = 8;

pub const Limits = struct {
    /// Tokens, comments and newlines included.
    tokens: u32 = 4096,
    /// Items of the tree, and the checker's calls and expressions.
    tree: u32 = 4096,
    /// Declarations and names.
    names: u32 = 256,
    nodes: u32 = 256,
    /// The f64 of the program's slab.
    slab: u32 = 4096,
    cues: u32 = 512,
    goals: u32 = 256,
    regions: u32 = 64,
    tracks: u32 = 8,
    /// Each track's samples: the writes it can hold.
    track_samples: u32 = 1024,
    /// Modules in the file and its libraries.
    modules: u32 = 32,
    /// Libraries a file may `use`, passed to `compile_with`. None by default, so a client that
    /// never uses one pays for no library's tree.
    libraries: u32 = 0,
    /// Diagnostics kept; more are counted.
    errors: u32 = 16,
};
