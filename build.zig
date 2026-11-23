const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("signals", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const example = b.addExecutable(.{
        .name = "basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "signals", .module = mod },
            },
        }),
    });

    const run_step = b.step("run", "Run the blocking basic example");
    const run_cmd = b.addRunArtifact(example);
    run_step.dependOn(&run_cmd.step);
    run_cmd.addPassthruArgs();

    const callback_example = b.addExecutable(.{
        .name = "callback",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/callback.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "signals", .module = mod },
            },
        }),
    });

    const run_callback_step = b.step("run-callback", "Run the callback example");
    const run_callback_cmd = b.addRunArtifact(callback_example);
    run_callback_step.dependOn(&run_callback_cmd.step);
    run_callback_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const example_tests = b.addTest(.{
        .root_module = example.root_module,
    });
    const run_example_tests = b.addRunArtifact(example_tests);

    const callback_example_tests = b.addTest(.{
        .root_module = callback_example.root_module,
    });
    const run_callback_example_tests = b.addRunArtifact(callback_example_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_example_tests.step);
    test_step.dependOn(&run_callback_example_tests.step);
}
