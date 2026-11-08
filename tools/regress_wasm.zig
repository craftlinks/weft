//! The regress catalog on `wasm32-freestanding`.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. The Second Target
//! `regress_wasm.mjs` loads this module, calls `regress_render`, and prints the text, which
//! `regress.zig` compares with the golden. A browser runs the same wasm, so this is the arithmetic
//! a web client gets.

const std = @import("std");
const assert = std.debug.assert;
const catalog = @import("catalog");

var text: [catalog.text_size_max]u8 = undefined;

/// Renders the catalog into `regress_text` and returns its size in bytes.
export fn regress_render() u32 {
    const rendered = catalog.render(&text);
    assert(rendered.len > 0);
    assert(rendered.len <= text.len);
    return @intCast(rendered.len);
}

export fn regress_text() [*]const u8 {
    return &text;
}
