const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library itself. This is what consumers import as `loom`.
    const mod = b.addModule("loom", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // A runnable echo server, so `zig build run-example` proves the
    // library works end to end and the README has something real to
    // point at.
    const example = b.addExecutable(.{
        .name = "echo-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/echo_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "loom", .module = mod },
            },
        }),
    });
    b.installArtifact(example);

    const run_example = b.addRunArtifact(example);
    run_example.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_example.addArgs(args);

    const run_example_step = b.step("run-example", "Run the example echo server");
    run_example_step.dependOn(&run_example.step);

    const cluster_example = b.addExecutable(.{
        .name = "cluster-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/cluster_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "loom", .module = mod },
            },
        }),
    });
    b.installArtifact(cluster_example);

    const run_cluster = b.addRunArtifact(cluster_example);
    run_cluster.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cluster.addArgs(args);

    const run_cluster_step = b.step("run-cluster", "Run the multi-worker example server");
    run_cluster_step.dependOn(&run_cluster.step);

    // Unit tests: whatever `test` blocks the library's own sources declare.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const unit_step = b.step("test-unit", "Run library unit tests");
    unit_step.dependOn(&run_mod_tests.step);

    // End-to-end tests. These stand up real Loom servers on ephemeral
    // ports and drive them over real sockets, so they catch the failures
    // unit tests structurally can't: use-after-free in the event batch, a
    // listener that never re-arms, a loop that spins instead of parking,
    // a timeout that fires on active connections. Kept as its own step
    // because they are slower and bind sockets, which not every
    // environment allows.
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "loom", .module = mod },
            },
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);
    // Servers bind sockets, so results aren't a pure function of the
    // inputs; never serve these from the build cache.
    run_integration_tests.has_side_effects = true;

    const integration_step = b.step("test-integration", "Run end-to-end server tests");
    integration_step.dependOn(&run_integration_tests.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
