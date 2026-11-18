//! The rules the text package keeps, checked from its files, so a claim in the README cannot rot
//! while the tests pass. The core's own are in Weft's `test/rules.zig`, and the language's in
//! Jig's `rules.zig`.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Realtime by Construction
//! A compile takes no allocator and touches no clock, file, or thread, so it cannot allocate,
//! lock, or block, whatever it runs on. That holds while no file of the root or of `src` names
//! one, which the first test checks word by word: an allocator, the heap, a thread, a lock, a
//! file, a process, or a clock. A caller's `std.Io.Writer`, which the language formats into, is
//! the one `std.Io` name allowed. The command (`cli`) is a client and reads files, so it is not
//! scanned.
//!
//! ## 2. A Guide in Every File
//! Every Zig file of the package, but the build script, starts with its guide for reviewers,
//! `# Deep Architectural Guide for Reviewers:` within its first lines.
//!
//! ## 3. Where It Runs
//! The build runs this test from the root of the package (`build.zig`), so the paths below are
//! relative to it, and it reads files into one static buffer, so a file larger than it fails
//! here by name.

const std = @import("std");
const testing = std.testing;

/// Names no file of section 1 may hold.
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

/// The directories of section 1.
const realtime = [_][]const u8{ ".", "src" };

/// The directories of section 2.
const guided = [_][]const u8{ ".", "src", "cli", "tools", "test" };

var buffer: [1 << 18]u8 = undefined;

fn read(io: std.Io, dir: std.Io.Dir, name: []const u8) ![]const u8 {
    return dir.readFile(io, name, &buffer) catch |err| {
        std.debug.print("rules: cannot read {s}: {t}\n", .{ name, err });
        return err;
    };
}

// Locks section 1: no file of the root or of `src` names an allocator, a
// thread, a lock, a file, a process, or a clock.
test "the text package cannot allocate, lock, or block" {
    const io = testing.io;
    var checked: usize = 0;
    for (realtime) |path| {
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var entries = dir.iterate();
        while (try entries.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
            if (std.mem.eql(u8, entry.name, "build.zig")) continue;
            const text = try read(io, dir, entry.name);
            checked += 1;
            for (forbidden) |word| {
                if (std.mem.indexOf(u8, text, word) != null) {
                    std.debug.print("rules: {s}/{s} names `{s}`\n", .{ path, entry.name, word });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
    try testing.expectEqual(@as(usize, 3), checked);
}

// Locks section 2: every Zig file but the build scripts opens with its guide.
test "every file opens with its guide" {
    const io = testing.io;
    const mark = "# Deep Architectural Guide for Reviewers:";
    var checked: usize = 0;
    for (guided) |path| {
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        var entries = dir.iterate();
        while (try entries.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
            if (std.mem.eql(u8, entry.name, "build.zig")) continue;
            const text = try read(io, dir, entry.name);
            const head = text[0..@min(text.len, 1200)];
            if (std.mem.indexOf(u8, head, mark) == null) {
                std.debug.print("rules: {s}/{s} has no `{s}` at its top\n", .{ path, entry.name, mark });
                return error.TestUnexpectedResult;
            }
            checked += 1;
        }
    }
    try testing.expectEqual(@as(usize, 25), checked);
}
