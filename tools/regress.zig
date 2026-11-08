//! `zig build regress [-- --bless]`: the sampled signals against the committed golden.
//!
//! # Deep Architectural Guide for Reviewers:
//!
//! ## 1. What It Compares
//! Renders the catalog natively and compares that text and the wasm build's text with
//! `test/golden/signals.txt`, reporting the first sample that differs. `--bless` rewrites the
//! golden from the native text, and refuses if native and wasm disagree, since a golden that one
//! target cannot meet locks nothing. Exits 0 when everything matches or was blessed, 1 on a
//! mismatch, and 2 on a usage error.

const std = @import("std");
const assert = std.debug.assert;
const catalog = @import("catalog");

const exit_match: u8 = 0;
const exit_mismatch: u8 = 1;
const exit_usage: u8 = 2;

// One byte over the largest text, so a file too large to be the catalog reads as a mismatch.
var buffer_native: [catalog.text_size_max]u8 = undefined;
var buffer_wasm: [catalog.text_size_max + 1]u8 = undefined;
var buffer_golden: [catalog.text_size_max + 1]u8 = undefined;

const Options = struct {
    golden_path: []const u8,
    wasm_path: []const u8,
    bless: bool,
};

pub fn main(init: std.process.Init) !u8 {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const options = parse(&args) orelse return usage();

    const dir = std.Io.Dir.cwd();
    const native = catalog.render(&buffer_native);
    const wasm = try dir.readFile(init.io, options.wasm_path, &buffer_wasm);
    if (options.bless) {
        if (catalog.compare(native, wasm)) |mismatch| return report("wasm", "native", mismatch);
        try dir.writeFile(init.io, .{ .sub_path = options.golden_path, .data = native });
        std.debug.print("regress: blessed {d} samples and {d} events\n", .{
            catalog.sample_count,
            catalog.event_count,
        });
        return exit_match;
    }

    const golden = try dir.readFile(init.io, options.golden_path, &buffer_golden);
    if (catalog.compare(golden, native)) |mismatch| return report("native", "golden", mismatch);
    if (catalog.compare(golden, wasm)) |mismatch| return report("wasm", "golden", mismatch);
    std.debug.print("regress: {d} samples and {d} events match the golden on native and wasm\n", .{
        catalog.sample_count,
        catalog.event_count,
    });
    return exit_match;
}

fn parse(args: *std.process.Args.Iterator) ?Options {
    const golden_path = args.next() orelse return null;
    const wasm_path = args.next() orelse return null;
    assert(golden_path.len > 0);
    assert(wasm_path.len > 0);
    const flag = args.next() orelse return .{
        .golden_path = golden_path,
        .wasm_path = wasm_path,
        .bless = false,
    };
    if (!std.mem.eql(u8, flag, "--bless")) return null;
    if (args.next() != null) return null;
    return .{ .golden_path = golden_path, .wasm_path = wasm_path, .bless = true };
}

fn usage() u8 {
    std.debug.print("usage: zig build regress [-- --bless]\n", .{});
    return exit_usage;
}

fn report(actual_name: []const u8, expected_name: []const u8, mismatch: catalog.Mismatch) u8 {
    assert(mismatch.line > 0);
    std.debug.print("regress: {s} differs from {s} at line {d}\n  {s}: {s}\n  {s}: {s}\n", .{
        actual_name,     expected_name,     mismatch.line,
        expected_name,   mismatch.expected, actual_name,
        mismatch.actual,
    });
    return exit_mismatch;
}
