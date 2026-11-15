//! The rules the whole tree keeps, checked from its files (step 18), so a claim in the README
//! cannot rot while the tests pass.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Realtime by Construction
//! `eval`, `events`, and a compile take no allocator and touch no clock, file, or thread, so
//! they cannot allocate, lock, or block, whatever they run on. That holds while no file of
//! `src/core`, `src/lang`, or `language` names one, which the first test checks word by word: an
//! allocator, the heap, a thread, a lock, a file, a process, or a clock. A caller's
//! `std.Io.Writer`, which the language formats into, is the one `std.Io` name allowed in
//! `src/lang` and `language`, and none in `src/core`. `zig build bench` measures the same claim
//! on a thread at audio pace.
//!
//! ## 2. A Guide in Every File
//! Every Zig file of the root package (`language/` beside `src/lang` among them) and of `play/`
//! starts with its guide for reviewers, `# Deep Architectural Guide for Reviewers:` within its
//! first lines, except the build scripts and the topic files of `src/core/graph_test/`, which
//! open with `//! Tests of the graph:` and point to `graph.zig`'s guide.
//!
//! ## 3. The Language Imports Only Itself
//! `language/` is a module of its own (step 53). The compiler refuses a file outside its root, but
//! not a second module named in `build.zig`, so the second test reads every `language/*.zig` and
//! allows `@import("std")` and `@import("<name>.zig")` of a file in `language/` only, and fails by
//! file name and import. The scan is textual, so it also refuses an import written in a comment.
//!
//! ## 4. Where It Runs
//! The build runs this test from the root of the repository (`build.zig`), so the paths below are
//! relative to it, and it reads files into one static buffer, so a file larger than it fails here
//! by name.

const std = @import("std");
const testing = std.testing;

/// Names no file of the core or the language may hold (section 1).
const forbidden = [_][]const u8{
    "Allocator",
    "allocator(",
    "std.heap",
    "std.Thread",
    "Mutex",
    "std.fs",
    "std.process",
    "std.posix",
    "std.os.",
    "std.Io.File",
    "std.Io.Dir",
    "std.Io.Clock",
    "std.Io.Threaded",
};

/// The directories of section 2, and whether each holds graph tests.
const guided = [_]struct { path: []const u8, graph_tests: bool = false }{
    .{ .path = "src" },
    .{ .path = "src/core" },
    .{ .path = "src/core/graph_test", .graph_tests = true },
    .{ .path = "src/lang" },
    .{ .path = "language" },
    .{ .path = "cli" },
    .{ .path = "tools" },
    .{ .path = "test" },
    .{ .path = "play" },
};

var buffer: [1 << 18]u8 = undefined;

fn read(io: std.Io, dir: std.Io.Dir, name: []const u8) ![]const u8 {
    return dir.readFile(io, name, &buffer) catch |err| {
        std.debug.print("rules: cannot read {s}: {t}\n", .{ name, err });
        return err;
    };
}

// Locks section 1: no file of `src/core` or `src/lang` names an allocator, a thread, a lock, a
// file, a process, or a clock, and `src/core` names no `std.Io` at all.
test "the core and the language cannot allocate, lock, or block" {
    const io = testing.io;
    var checked: usize = 0;
    for ([_][]const u8{ "src/core", "src/lang", "language" }) |path| {
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var entries = dir.iterate();
        while (try entries.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
            const text = try read(io, dir, entry.name);
            checked += 1;
            for (forbidden) |word| {
                if (std.mem.indexOf(u8, text, word) != null) {
                    std.debug.print("rules: {s}/{s} names `{s}`\n", .{ path, entry.name, word });
                    return error.TestUnexpectedResult;
                }
            }
            if (std.mem.eql(u8, path, "src/core") and std.mem.indexOf(u8, text, "std.Io") != null) {
                std.debug.print("rules: {s}/{s} names `std.Io`\n", .{ path, entry.name });
                return error.TestUnexpectedResult;
            }
        }
    }
    try testing.expect(checked >= 20);
}

// Locks section 2: every Zig file but the build scripts opens with its guide, and the graph's
// topic files with their one-line header.
test "every file opens with its guide" {
    const io = testing.io;
    var checked: usize = 0;
    for (guided) |place| {
        var dir = try std.Io.Dir.cwd().openDir(io, place.path, .{ .iterate = true });
        defer dir.close(io);
        var entries = dir.iterate();
        while (try entries.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
            if (std.mem.eql(u8, entry.name, "build.zig")) continue;
            const text = try read(io, dir, entry.name);
            const head = text[0..@min(text.len, 1200)];
            const mark = if (place.graph_tests) "//! Tests of the graph:" else "# Deep Architectural Guide for Reviewers:";
            if (std.mem.indexOf(u8, head, mark) == null) {
                std.debug.print("rules: {s}/{s} has no `{s}` at its top\n", .{ place.path, entry.name, mark });
                return error.TestUnexpectedResult;
            }
            checked += 1;
        }
    }
    try testing.expect(checked >= 50);
}

/// The one import a file of `language/` may name besides its own files.
const language_import_std = "std";

/// Whether `name`, the text between the quotes of an `@import`, is allowed in `language/`: `std`,
/// or a bare file name that exists beside the importer.
fn language_import_allowed(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    if (std.mem.eql(u8, name, language_import_std)) return true;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    if (!std.mem.endsWith(u8, name, ".zig")) return false;
    dir.access(io, name, .{}) catch return false;
    return true;
}

// Locks section 3: every file of `language/` (the six, the root, `file`, and `limits`) imports
// only `std` and its own files; a planted `@import("../src/core/time.zig")` fails by file name
// and import.
test "the language imports only std and its own files" {
    const io = testing.io;
    const opener = "@import(\"";
    var dir = try std.Io.Dir.cwd().openDir(io, "language", .{ .iterate = true });
    defer dir.close(io);
    var files: usize = 0;
    var imports: usize = 0;
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        const text = try read(io, dir, entry.name);
        files += 1;
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, opener)) |found| {
            const start = found + opener.len;
            const length = std.mem.indexOfScalar(u8, text[start..], '"') orelse return error.TestUnexpectedResult;
            const name = text[start..][0..length];
            if (!language_import_allowed(io, dir, name)) {
                std.debug.print("rules: language/{s} imports \"{s}\"\n", .{ entry.name, name });
                return error.TestUnexpectedResult;
            }
            imports += 1;
            from = start + length;
        }
    }
    try testing.expectEqual(@as(usize, 10), files);
    try testing.expect(imports >= 8);
}
