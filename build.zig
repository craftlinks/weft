const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });

    // No target of its own, so one module serves a client on any target, and links nothing. The
    // package is the core only and depends on nothing: the text front end is `text/`, a package
    // of its own (step 58).
    const weft = b.addModule("weft", .{ .root_source_file = b.path("src/weft.zig") });
    // The core's graphs, which the text package's tests compile from text and compare with.
    const catalog = b.addModule("catalog", .{
        .root_source_file = b.path("test/catalog.zig"),
        .imports = &.{.{ .name = "weft", .module = weft }},
    });

    const test_step = b.step("test", "Run the unit tests");
    const test_roots = [_]*std.Build.Module{
        b.createModule(.{
            .root_source_file = b.path("src/weft.zig"),
            .target = target,
            .optimize = optimize,
        }),
        b.createModule(.{
            .root_source_file = b.path("test/catalog.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "weft", .module = weft }},
        }),
    };
    for (test_roots) |root| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = root })).step);
    }
    // The tree's rules read its files from the root of the repository, at every run, since a
    // file can change without changing the test (`test/rules.zig`).
    const rules = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/rules.zig"),
        .target = target,
        .optimize = optimize,
    }) }));
    rules.setCwd(b.path("."));
    rules.has_side_effects = true;
    test_step.dependOn(&rules.step);

    const wasm = b.addExecutable(.{
        .name = "weft-regress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/regress_wasm.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "catalog", .module = catalog }},
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.export_memory = true;
    const wasm_install = b.addInstallArtifact(wasm, .{});
    b.step("wasm", "Build the wasm32-freestanding regress module").dependOn(&wasm_install.step);
    b.getInstallStep().dependOn(&wasm_install.step);

    const regress = b.addExecutable(.{
        .name = "weft-regress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/regress.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "catalog", .module = catalog }},
        }),
    });
    const wasm_run = b.addSystemCommand(&.{ "node", "tools/regress_wasm.mjs" });
    wasm_run.addFileInput(b.path("tools/regress_wasm.mjs"));
    wasm_run.addArtifactArg(wasm);
    const regress_run = b.addRunArtifact(regress);
    regress_run.addFileArg(b.path("test/golden/signals.txt"));
    regress_run.addFileArg(wasm_run.captureStdOut(.{}));
    regress_run.addPassthruArgs();
    regress_run.has_side_effects = true;
    b.step("regress", "Compare sampled signals with the golden").dependOn(&regress_run.step);
}
