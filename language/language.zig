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
//! `error` (re-exported as `diagnostic`), `schema`, `format`, `check`, `file`, and `limits`.
//!
//! ## 1a. Checking Without a Back End
//! `file.File(FileLimits, vocabulary)` is a file parsed and checked, with no program (step 57):
//! its `check_client` runs the front end alone, so a file of a client's own signals, which a
//! back end refuses, ends with no diagnostic. A back end that builds a program holds the same fields beside
//! its own, and calls the one function, `file.check_fields`, that `File` calls. `FileLimits` is the
//! language's own tables; a back end's tables sit in its own `Limits`, which hands this part over.
//!
//! ## 2. What a Back End Passes In
//! The language never names a back end's table. The back end gives `check.Memory` a
//! `schema.Vocabulary`: its entries, and three functions whose bits are its own (a folding
//! call's value, a constructor's conversion, and the seed hash). Weft's is `src/lang/table.zig`.
//! The vocabulary exists at compile time only (step 56): the functions are plain calls, never
//! pointers, and `check.check` takes the vocabulary and a client's entries as comptime
//! parameters, joined into one list by `schema.join`.

pub const token = @import("token.zig");
pub const parse = @import("parse.zig");
pub const diagnostic = @import("error.zig");
pub const schema = @import("schema.zig");
pub const format = @import("format.zig");
pub const check = @import("check.zig");
pub const limits = @import("limits.zig");
pub const FileLimits = limits.FileLimits;
pub const file = @import("file.zig");
pub const File = file.File;
pub const Syntax = file.Syntax;
pub const Source = file.Source;

test {
    _ = token;
    _ = parse;
    _ = diagnostic;
    _ = schema;
    _ = format;
    _ = check;
    _ = file;
    _ = @import("check_test.zig");
}
