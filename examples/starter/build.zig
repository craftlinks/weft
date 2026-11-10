//! A Patchwork app that reads a Weft program: the smallest client. Weft and Patchwork never see
//! each other; this package depends on both by path.

const std = @import("std");
const patchwork = @import("patchwork");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("patchwork", .{ .target = target, .optimize = optimize });
    const weft = b.dependency("weft", .{}).module("weft");
    const steps = patchwork.addApp(b, dep.builder, .{
        .name = "starter",
        .root_source_file = b.path("app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "weft", .module = weft }},
    });
    b.getInstallStep().dependOn(steps.install);
    b.step("run", "Run natively (opens a window)").dependOn(steps.run);
    b.step("wasm", "Build for the browser").dependOn(steps.wasm);
    b.step("serve", "Serve on localhost").dependOn(steps.serve);
    b.step("test", "Run the app's tests, with no GPU").dependOn(steps.tests);
    b.step("regress", "Render the scenarios against test/golden").dependOn(steps.regress);
    b.step("bench", "Time a scenario's frames").dependOn(steps.bench);
}
