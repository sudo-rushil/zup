const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zup",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Copy to zig-out/bin/
    b.installArtifact(exe);

    // Run the app
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    // Add tests for module and executable
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    const lint = b.addExecutable(.{ .name = "lint", .root_module = b.createModule(.{
        .root_source_file = b.path("lint.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const run_lint = b.addRunArtifact(lint);
    run_lint.addFileArg(b.path("src/main.zig"));
    const lint_step = b.step("lint", "Check style limits");
    lint_step.dependOn(&run_lint.step);
}
