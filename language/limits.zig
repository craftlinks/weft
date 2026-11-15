//! The language's own numbers: a file's limits, and the constants the front end shares with a
//! back end. A back end asserts the ones it also has (Weft's `table.zig`).
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! This file imports only `std`, like the rest of the module. Weft passes nothing in for these:
//! it asserts, at comptime in `src/lang/table.zig`, that its core's own numbers equal them, so a
//! drift fails the build. `FileLimits` is what a caller gives a check: how large a file may be.

const std = @import("std");

/// A second in flicks, the unit a time literal is read into.
pub const flicks_per_second: i64 = 705_600_000;
/// The most lanes a region has.
pub const lanes_max = 1 << 20;
/// The powers `pow(x, n)` takes.
pub const power_min = 2;
pub const power_max = 8;

/// How large a file may be, as far as the language's own tables go (step 57): the tokens, the
/// tree, the names, the checker's tables, the modules, the libraries, and the diagnostics. A back
/// end's tables (Weft's nodes and slab) are its own and sit beside these in its own `Limits`,
/// which hands the language this part.
pub const FileLimits = struct {
    /// Tokens, comments and newlines included.
    tokens: u32 = 4096,
    /// Items of the tree, and the checker's calls and expressions.
    tree: u32 = 4096,
    /// Declarations and names.
    names: u32 = 256,
    cues: u32 = 512,
    goals: u32 = 256,
    regions: u32 = 64,
    tracks: u32 = 8,
    /// Modules in the file and its libraries.
    modules: u32 = 32,
    /// Libraries a file may `use`, passed to `check_client`. None by default, so a client that
    /// never uses one pays for no library's tree.
    libraries: u32 = 0,
    /// Diagnostics kept; more are counted.
    errors: u32 = 16,
};
