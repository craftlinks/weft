//! Weft's text package: Weft's table of calls, its back end, `Compiled`, `std`, and the `weft`
//! command, over Jig (the language) and Weft's core. A package of its own, as `play/` is, so
//! Weft's root package is the core only and imports nothing.
//!
//! One instance of each module in a client's build: this package exposes the `weft` and `jig`
//! modules it was given beside its own `weft_text` and `commands`, and a client declares the one
//! dependency `weft_text` and takes all four from it. If a client took Jig from a dependency of
//! its own, the two `jig.schema.Entry` could be two types, and a client's entries would not pass
//! to `Compiled`.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const weft_dep = b.dependency("weft", .{});
    const weft = weft_dep.module("weft");
    const catalog = weft_dep.module("catalog");
    const jig = b.dependency("jig", .{}).module("jig");
    b.modules.put(b.allocator, "weft", weft) catch @panic("out of memory");
    b.modules.put(b.allocator, "jig", jig) catch @panic("out of memory");

    // No target of its own, so one module serves a client on any target, and links nothing.
    const weft_text = b.addModule("weft_text", .{
        .root_source_file = b.path("text.zig"),
        .imports = &.{
            .{ .name = "weft", .module = weft },
            .{ .name = "jig", .module = jig },
        },
    });
    const commands = b.addModule("commands", .{
        .root_source_file = b.path("cli/commands.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "weft", .module = weft },
            .{ .name = "jig", .module = jig },
            .{ .name = "weft_text", .module = weft_text },
        },
    });
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "weft", .module = weft },
        .{ .name = "jig", .module = jig },
        .{ .name = "weft_text", .module = weft_text },
        .{ .name = "catalog", .module = catalog },
    };

    const test_step = b.step("test", "Run the unit tests");
    const test_roots = [_][]const u8{
        "text.zig",
        "test/by_lane.zig",
        "test/carry.zig",
        "test/chains.zig",
        "test/client_entries.zig",
        "test/constants.zig",
        "test/division.zig",
        "test/forms.zig",
        "test/functions.zig",
        "test/lanes.zig",
        "test/lang.zig",
        "test/modules.zig",
        "test/motion_by_lane.zig",
        "test/nouns.zig",
        "test/sharing.zig",
        "test/sources.zig",
        "test/vectors.zig",
    };
    for (test_roots) |root| {
        const module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    }
    // The package's rules read its files from its root, at every run, since a file can change
    // without changing the test (`test/rules.zig`).
    const rules = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/rules.zig"),
        .target = target,
        .optimize = optimize,
    }) }));
    rules.setCwd(b.path("."));
    rules.has_side_effects = true;
    test_step.dependOn(&rules.step);

    // The `weft` command (step 14): its commands are a module of their own, so the tests call
    // the same functions and compare the bytes with the goldens in test/golden/cli.
    const cli = b.addExecutable(.{
        .name = "weft",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "weft", .module = weft },
                .{ .name = "jig", .module = jig },
                .{ .name = "weft_text", .module = weft_text },
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
                .{ .name = "jig", .module = jig },
                .{ .name = "weft_text", .module = weft_text },
                .{ .name = "commands", .module = commands },
            },
        }),
    });
    // Play's files and the starter's, whose tables `check --costs` sums (step 49).
    const real_files = [_][2][]const u8{
        .{ "play_bouncers", "../play/bouncers.jig" },
        .{ "play_lanes", "../play/lanes.jig" },
        .{ "play_signals", "../play/signals.jig" },
        .{ "play_swarm", "../play/swarm.jig" },
        .{ "play_vectors", "../play/vectors.jig" },
        .{ "starter_motion", "examples/starter/motion.jig" },
    };
    for (real_files) |file| {
        cli_tests.root_module.addAnonymousImport(file[0], .{ .root_source_file = b.path(file[1]) });
    }
    const cli_run = b.addRunArtifact(cli_tests);
    b.step("test-cli", "Compare the weft command's output with its goldens").dependOn(&cli_run.step);
    test_step.dependOn(&cli_run.step);

    // Native only, with no thresholds: its numbers depend on the machine (`tools/bench.zig`).
    const bench = b.addExecutable(.{
        .name = "weft-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "weft", .module = weft },
                .{ .name = "jig", .module = jig },
                .{ .name = "weft_text", .module = weft_text },
            },
        }),
    });
    bench.root_module.addAnonymousImport("play_signals", .{
        .root_source_file = b.path("../play/signals.jig"),
    });
    bench.root_module.addAnonymousImport("play_lanes", .{
        .root_source_file = b.path("../play/lanes.jig"),
    });
    const bench_run = b.addRunArtifact(bench);
    bench_run.has_side_effects = true;
    const bench_step = b.step("bench", "Time reads on this machine (use -Doptimize=ReleaseFast)");
    bench_step.dependOn(&bench_run.step);
}
