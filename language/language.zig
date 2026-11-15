//! The language: tokens, the parser, the formatter, diagnostics, the checker, and the schema's
//! types. It imports nothing but `std`. A back end gives it a `schema.Vocabulary`: the table of
//! calls it knows and the few functions whose bits are the back end's.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Is
//! A module of its own, with its root here. It imports only `std` and its own files, so the
//! compiler refuses any import of a back end's code, and a test in `test/rules.zig` holds the
//! same line against a second module named in `build.zig`. The files are `token`, `parse`,
//! `error` (re-exported as `diagnostic`), `schema`, `format`, `check`, and `limits`.
//!
//! ## 2. What a Back End Passes In
//! The language never names a back end's table. The back end gives `check.Memory` a
//! `schema.Vocabulary`: its entries, and three functions whose bits are its own (a folding
//! call's value, a constructor's conversion, and the seed hash). Weft's is `src/lang/table.zig`.
//! The functions are function pointers for now, a decided exception to the style that step 56
//! removes with comptime vocabularies.

pub const token = @import("token.zig");
pub const parse = @import("parse.zig");
pub const diagnostic = @import("error.zig");
pub const schema = @import("schema.zig");
pub const format = @import("format.zig");
pub const check = @import("check.zig");
pub const limits = @import("limits.zig");
pub const Limits = limits.Limits;

test {
    _ = token;
    _ = parse;
    _ = diagnostic;
    _ = schema;
    _ = format;
    _ = check;
    _ = @import("check_test.zig");
}
