//! Play: Weft's first client, a Patchwork app in a package of its own. Weft never sees Patchwork:
//! this package depends on both, through `.path` dependencies, so neither enters the other's
//! `build.zig.zon`. `addApp` (Patchwork's `build.zig`, section 7) hands the target-less `weft`
//! module to the native and the wasm app modules alike.
//!
//! The serve step is `serve-play`, the name Patchwork's `tools/browser_check.py --root` runs.

const std = @import("std");
const patchwork = @import("patchwork");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("patchwork", .{ .target = target, .optimize = optimize });
    const weft = b.dependency("weft", .{}).module("weft");
    const steps = patchwork.addApp(b, dep.builder, .{
        .name = "play",
        .root_source_file = b.path("app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "weft", .module = weft }},
    });
    b.getInstallStep().dependOn(steps.install);
    b.step("run", "Run natively").dependOn(steps.run);
    b.step("wasm", "Build for the browser").dependOn(steps.wasm);
    b.step("serve-play", "Serve on localhost").dependOn(steps.serve);
    b.step("regress", "Render the scenarios against test/golden").dependOn(steps.regress);
    b.step("test", "Run the app's tests").dependOn(steps.tests);
    b.step("bench", "Time a scenario's frames (use -Doptimize=ReleaseFast)").dependOn(steps.bench);
}
