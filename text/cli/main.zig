//! The `weft` command (step 14): reads the file and the arguments, runs one command from
//! `commands.zig`, and writes its output to standard output.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Usage
//! ```text
//! weft check FILE [--costs] [--use NAME=PATH]...
//! weft describe [--use NAME=PATH]...
//! weft sample FILE [--from S] [--to S] [--step S] [--signal NAME]... [--events NAME]...
//!                   [--lanes A..B] [--use NAME=PATH]...
//! weft parse FILE --json
//! ```
//! At most two `--use`. `--costs` lists what each declaration of the file costs, in tokens, nodes,
//! and slab, the most nodes first (step 49), and only `check` takes it. `--events NAME` keeps the
//! events of the signal bound to NAME, from the nodes `Compiled.event_sources` gives, and
//! `--lanes A..B` keeps lanes A to B of every signal and event, both included.
//! Times are seconds, read as decimals and turned into flicks, as the library's times are.
//! Exit 0 on success, 1 when the file has errors, and 2 on bad arguments or a file that cannot be
//! read. A file or a library larger than `file_bytes_max` is refused with its size, and exit 2,
//! since no check ran on the part of it that did not fit (step 60).
//!
//! ## 2. Memory
//! Each file is read into a buffer of its own, `file_buffers`, and the output is written into one
//! buffer, `out_buffer`, then printed in one write. `sample` allocates its reader's slab, sized to
//! the file, so a file of any slab can be sampled; nothing else allocates.

const std = @import("std");
const assert = std.debug.assert;
const weft = @import("weft");
const jig = @import("jig");
const commands = @import("commands");

const usage_text =
    \\usage: weft check FILE [--costs] [--use NAME=PATH]...
    \\       weft describe [--use NAME=PATH]...
    \\       weft sample FILE [--from S] [--to S] [--step S] [--signal NAME]... [--events NAME]...
    \\                         [--lanes A..B] [--use NAME=PATH]...
    \\       weft parse FILE --json
    \\
;
const file_bytes_max = 64 << 10;
const libraries_max = 2;
const names_max = commands.signals_max;

var file_buffers: [1 + libraries_max][file_bytes_max]u8 = undefined;
var out_buffer: [16 << 20]u8 = undefined;
var compiled: commands.Compiled = undefined;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const command = args.next() orelse return usage();

    var file: ?[]const u8 = null;
    var libraries: [libraries_max]jig.Source = undefined;
    var library_count: usize = 0;
    var names: [names_max][]const u8 = undefined;
    var name_count: usize = 0;
    var event_names: [names_max][]const u8 = undefined;
    var event_count: usize = 0;
    var lanes: ?[2]u32 = null;
    var costs = false;
    var window: commands.Window = .{ .from = 0, .to = 705_600_000, .step = 70_560_000 };
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) continue;
        if (std.mem.eql(u8, arg, "--costs")) {
            costs = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--use")) {
            const spec = args.next() orelse return usage();
            const equal = std.mem.indexOfScalar(u8, spec, '=') orelse return usage();
            if (library_count == libraries_max) {
                std.debug.print("error: at most {d} libraries, given {d}\n", .{ libraries_max, library_count + 1 });
                return 2;
            }
            const text = read(io, spec[equal + 1 ..], &file_buffers[1 + library_count]) orelse return 2;
            libraries[library_count] = .{ .name = spec[0..equal], .text = text };
            library_count += 1;
        } else if (std.mem.eql(u8, arg, "--from")) {
            window.from = flicks(args.next() orelse return usage()) orelse return usage();
        } else if (std.mem.eql(u8, arg, "--to")) {
            window.to = flicks(args.next() orelse return usage()) orelse return usage();
        } else if (std.mem.eql(u8, arg, "--step")) {
            window.step = flicks(args.next() orelse return usage()) orelse return usage();
        } else if (std.mem.eql(u8, arg, "--events")) {
            if (event_count == names_max) return usage();
            event_names[event_count] = args.next() orelse return usage();
            event_count += 1;
        } else if (std.mem.eql(u8, arg, "--lanes")) {
            lanes = lane_range(args.next() orelse return usage()) orelse return usage();
        } else if (std.mem.eql(u8, arg, "--signal")) {
            if (name_count == names_max) return usage();
            names[name_count] = args.next() orelse return usage();
            name_count += 1;
        } else if (file == null and !std.mem.startsWith(u8, arg, "--")) {
            file = arg;
        } else return usage();
    }

    // `--costs` is `check`'s alone.
    if (costs and !std.mem.eql(u8, command, "check")) return usage();
    var writer: std.Io.Writer = .fixed(&out_buffer);
    var status: u8 = 0;
    if (std.mem.eql(u8, command, "describe")) {
        commands.describe(&writer, libraries[0..library_count], &.{}) catch |err| {
            std.debug.print("weft: {s}\n", .{@errorName(err)});
            return 2;
        };
    } else {
        const path = file orelse return usage();
        const text = read(io, path, &file_buffers[0]) orelse return 2;
        const source: commands.Source = .{ .name = path, .text = text };
        if (std.mem.eql(u8, command, "check")) {
            const ok = if (costs)
                try commands.check_costs(&compiled, &writer, source, libraries[0..library_count], &.{})
            else
                try commands.check(&compiled, &writer, source, libraries[0..library_count], &.{});
            if (!ok) status = 1;
        } else if (std.mem.eql(u8, command, "sample")) {
            if (!window.valid()) {
                std.debug.print("weft: --step must be above 0, --to at or after --from, and at most {d} times\n", .{commands.samples_max});
                return 2;
            }
            const filter: commands.Filter = .{ .events = event_names[0..event_count], .lanes = lanes };
            const ok = try commands.sample(init.gpa, &compiled, &writer, source, libraries[0..library_count], &.{}, names[0..name_count], window, filter);
            if (!ok) status = 1;
        } else if (std.mem.eql(u8, command, "parse")) {
            const ok = try commands.parse(&writer, source);
            if (!ok) status = 1;
        } else return usage();
    }
    try std.Io.File.stdout().writeStreamingAll(io, writer.buffered());
    return status;
}

/// The whole file, or null after a line on stderr: a file it cannot open or read, or one larger
/// than `buffer`, which is refused rather than checked in part (step 60).
fn read(io: std.Io, path: []const u8, buffer: []u8) ?[]const u8 {
    assert(buffer.len == file_bytes_max);
    const text = commands.read_whole(io, std.Io.Dir.cwd(), path, buffer) catch |err| {
        if (err == error.TooLarge) {
            read_too_large(io, path);
        } else {
            std.debug.print("weft: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        }
        return null;
    };
    assert(text.len <= file_bytes_max);
    return text;
}

/// The size line: the file's size from its `stat`, or `more than` the cap when the size is not
/// to be had, as for a pipe, whose `stat` gives no size, or a file that shrank since the read.
fn read_too_large(io: std.Io, path: []const u8) void {
    // The file opened and read past the cap, so it has a name.
    assert(path.len > 0);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = true }) catch null;
    if (stat) |known| {
        if (known.size > file_bytes_max) {
            std.debug.print("weft: {s} is {d} bytes, and the command reads at most {d}\n", .{
                path, known.size, file_bytes_max,
            });
            return;
        }
    }
    std.debug.print("weft: {s} is more than {d} bytes, and the command reads at most {d}\n", .{
        path, file_bytes_max, file_bytes_max,
    });
}

/// A time in seconds, as flicks; null when it is not a number, or is beyond a day either way.
fn flicks(text: []const u8) ?i64 {
    const seconds = std.fmt.parseFloat(f64, text) catch return null;
    if (!(@abs(seconds) <= 86_400)) return null;
    return @intFromFloat(@round(seconds * @as(f64, @floatFromInt(weft.time.flicks_per_second))));
}

/// `A..B`, two lane indices with A at most B; null otherwise.
fn lane_range(text: []const u8) ?[2]u32 {
    const dots = std.mem.indexOf(u8, text, "..") orelse return null;
    const first = std.fmt.parseInt(u32, text[0..dots], 10) catch return null;
    const last = std.fmt.parseInt(u32, text[dots + 2 ..], 10) catch return null;
    if (first > last) return null;
    return .{ first, last };
}

fn usage() u8 {
    std.debug.print("{s}", .{usage_text});
    return 2;
}
