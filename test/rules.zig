//! The rules the whole tree keeps, checked from its files (step 18), so a claim in the README
//! cannot rot while the tests pass.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Realtime by Construction
//! `eval` and `events` take no allocator and touch no clock, file, or thread, so they cannot
//! allocate, lock, or block, whatever they run on. That holds while no file of `src/core` names
//! one, which the first test checks word by word: an allocator, the heap, a thread, a lock, a
//! file, a process, or a clock, and no `std.Io` at all. The text package keeps the same line for
//! a compile in its own `test/rules.zig`.
//!
//! ## 2. A Guide in Every File
//! Every Zig file of the root package and of `play/` starts with its guide for reviewers,
//! `# Deep Architectural Guide for Reviewers:` within its first lines, except the build scripts
//! and the topic files of `src/core/graph_test/`, which open with `//! Tests of the graph:` and
//! point to `graph.zig`'s guide.
//!
//! ## 3. Weft Imports Nothing
//! Since step 58 the root package is the core only and depends on nothing (`build.zig.zon`).
//! The compiler refuses a file outside the module's root, but the build file could name a
//! second module, so the third test reads every file of `src` and allows an import of `std`, or
//! of a file of the package by its relative path, and fails by file name and import. The scan is
//! textual, so it also refuses an import written in a comment.
//!
//! ## 4. Where It Runs
//! The build runs this test from the root of the repository (`build.zig`), so the paths below are
//! relative to it, and it reads files into one static buffer, so a file larger than it fails here
//! by name.

const std = @import("std");
const testing = std.testing;

/// Names no file of the core may hold (section 1).
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

// Locks section 1: no file of `src/core` names an allocator, a thread, a lock, a file, a
// process, or a clock, or `std.Io` at all.
test "the core cannot allocate, lock, or block" {
    const io = testing.io;
    var checked: usize = 0;
    for ([_][]const u8{"src/core"}) |path| {
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
            if (std.mem.indexOf(u8, text, "std.Io") != null) {
                std.debug.print("rules: {s}/{s} names `std.Io`\n", .{ path, entry.name });
                return error.TestUnexpectedResult;
            }
        }
    }
    try testing.expectEqual(@as(usize, 15), checked);
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
    try testing.expectEqual(@as(usize, 42), checked);
}

/// The directories of section 3.
const rooted = [_][]const u8{ "src", "src/core", "src/core/graph_test" };

/// Whether `name`, the text between the quotes of an `@import`, is allowed: `std`, or a file of
/// the package named by a relative path that does not climb out of `src`.
fn import_allowed(name: []const u8) bool {
    if (std.mem.eql(u8, name, "std")) return true;
    if (!std.mem.endsWith(u8, name, ".zig")) return false;
    return std.mem.indexOf(u8, name, "../../") == null;
}

// Locks section 3: every file of `src` imports only `std` and the package's own files; a planted
// import of a module named in the build, or of `../../text/text.zig`, fails by file name.
test "the core imports only std and its own files" {
    const io = testing.io;
    const opener = "@import(\"";
    var files: usize = 0;
    var imports: usize = 0;
    for (rooted) |path| {
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var entries = dir.iterate();
        while (try entries.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
            const text = try read(io, dir, entry.name);
            files += 1;
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, text, from, opener)) |found| {
                const start = found + opener.len;
                const length = std.mem.indexOfScalar(u8, text[start..], '"') orelse
                    return error.TestUnexpectedResult;
                const name = text[start..][0..length];
                if (!import_allowed(name)) {
                    std.debug.print("rules: {s}/{s} imports \"{s}\"\n", .{ path, entry.name, name });
                    return error.TestUnexpectedResult;
                }
                imports += 1;
                from = start + length;
            }
        }
    }
    try testing.expectEqual(@as(usize, 27), files);
    try testing.expect(imports >= 20);
}
