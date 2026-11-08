//! The `weft` command (step 14): reads the file and the arguments, runs one command from
//! `commands.zig`, and writes its output to standard output.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. Usage
//! ```text
//! weft check FILE [--use NAME=PATH]...
//! weft describe [--use NAME=PATH]...
//! weft sample FILE [--from S] [--to S] [--step S] [--signal NAME]... [--use NAME=PATH]...
//! weft parse FILE --json
//! ```
//! Times are seconds, read as decimals and turned into flicks, as the library's times are.
//! Exit 0 on success, 1 when the file has errors, and 2 on bad arguments or a file that cannot be
//! read.
//!
//! ## 2. Memory
//! Each file is read into a buffer of its own, `file_buffers`, and the output is written into one
//! buffer, `out_buffer`, then printed in one write. The CLI allocates nothing.

const std = @import("std");
const weft = @import("weft");
const commands = @import("commands");

const usage_text =
    \\usage: weft check FILE [--use NAME=PATH]...
    \\       weft describe [--use NAME=PATH]...
    \\       weft sample FILE [--from S] [--to S] [--step S] [--signal NAME]... [--use NAME=PATH]...
    \\       weft parse FILE --json
    \\
;
const file_bytes_max = 64 << 10;
const libraries_max = 2;
const names_max = commands.signals_max;

var file_buffers: [1 + libraries_max][file_bytes_max]u8 = undefined;
var out_buffer: [1 << 20]u8 = undefined;
var compiled: commands.Compiled = undefined;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const command = args.next() orelse return usage();

    var file: ?[]const u8 = null;
    var libraries: [libraries_max]weft.lang.Source = undefined;
    var library_count: usize = 0;
    var names: [names_max][]const u8 = undefined;
    var name_count: usize = 0;
    var window: commands.Window = .{ .from = 0, .to = 705_600_000, .step = 70_560_000 };
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) continue;
        if (std.mem.eql(u8, arg, "--use")) {
            const spec = args.next() orelse return usage();
            const equal = std.mem.indexOfScalar(u8, spec, '=') orelse return usage();
            if (library_count == libraries_max) return usage();
            const text = read(io, spec[equal + 1 ..], &file_buffers[1 + library_count]) orelse return 2;
            libraries[library_count] = .{ .name = spec[0..equal], .text = text };
            library_count += 1;
        } else if (std.mem.eql(u8, arg, "--from")) {
            window.from = flicks(args.next() orelse return usage()) orelse return usage();
        } else if (std.mem.eql(u8, arg, "--to")) {
            window.to = flicks(args.next() orelse return usage()) orelse return usage();
        } else if (std.mem.eql(u8, arg, "--step")) {
            window.step = flicks(args.next() orelse return usage()) orelse return usage();
        } else if (std.mem.eql(u8, arg, "--signal")) {
            if (name_count == names_max) return usage();
            names[name_count] = args.next() orelse return usage();
            name_count += 1;
        } else if (file == null and !std.mem.startsWith(u8, arg, "--")) {
            file = arg;
        } else return usage();
    }

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
            const ok = try commands.check(&compiled, &writer, source, libraries[0..library_count]);
            if (!ok) status = 1;
        } else if (std.mem.eql(u8, command, "sample")) {
            if (!window.valid()) {
                std.debug.print("weft: --step must be above 0, --to at or after --from, and at most {d} times\n", .{commands.samples_max});
                return 2;
            }
            const ok = try commands.sample(&compiled, &writer, source, libraries[0..library_count], names[0..name_count], window);
            if (!ok) status = 1;
        } else if (std.mem.eql(u8, command, "parse")) {
            const ok = try commands.parse(&writer, source);
            if (!ok) status = 1;
        } else return usage();
    }
    try std.Io.File.stdout().writeStreamingAll(io, writer.buffered());
    return status;
}

fn read(io: std.Io, path: []const u8, buffer: []u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFile(io, path, buffer) catch |err| {
        std.debug.print("weft: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return null;
    };
}

/// A time in seconds, as flicks; null when it is not a number, or is beyond a day either way.
fn flicks(text: []const u8) ?i64 {
    const seconds = std.fmt.parseFloat(f64, text) catch return null;
    if (!(@abs(seconds) <= 86_400)) return null;
    return @intFromFloat(@round(seconds * @as(f64, @floatFromInt(weft.time.flicks_per_second))));
}

fn usage() u8 {
    std.debug.print("{s}", .{usage_text});
    return 2;
}
