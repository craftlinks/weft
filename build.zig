const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });

    // No target of its own, so one module serves a client on any target, and links nothing.
    const weft = b.addModule("weft", .{ .root_source_file = b.path("src/weft.zig") });
    const catalog = b.createModule(.{
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
        b.createModule(.{
            .root_source_file = b.path("test/carry.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "weft", .module = weft }},
        }),
        b.createModule(.{
            .root_source_file = b.path("test/modules.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "weft", .module = weft }},
        }),
        b.createModule(.{
            .root_source_file = b.path("test/lang.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "weft", .module = weft },
                .{ .name = "catalog", .module = catalog },
            },
        }),
    };
    for (test_roots) |root| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = root })).step);
    }

    // The `weft` command (step 14): its commands are a module of their own, so the tests call
    // the same functions and compare the bytes with the goldens in test/golden/cli.
    const commands = b.createModule(.{
        .root_source_file = b.path("cli/commands.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "weft", .module = weft }},
    });
    const cli = b.addExecutable(.{
        .name = "weft",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "weft", .module = weft },
                .{ .name = "commands", .module = commands },
            },
        }),
    });
    b.installArtifact(cli);
    const cli_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "weft", .module = weft },
                .{ .name = "commands", .module = commands },
            },
        }),
    });
    const cli_run = b.addRunArtifact(cli_tests);
    b.step("test-cli", "Compare the weft command's output with its goldens").dependOn(&cli_run.step);
    test_step.dependOn(&cli_run.step);

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

    // Native only, with no thresholds: its numbers depend on the machine (`tools/bench.zig`).
    const bench = b.addExecutable(.{
        .name = "weft-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "weft", .module = weft }},
        }),
    });
    bench.root_module.addAnonymousImport("play_signals", .{
        .root_source_file = b.path("play/signals.weft"),
    });
    const bench_run = b.addRunArtifact(bench);
    bench_run.has_side_effects = true;
    const bench_step = b.step("bench", "Time reads on this machine (use -Doptimize=ReleaseFast)");
    bench_step.dependOn(&bench_run.step);
}
