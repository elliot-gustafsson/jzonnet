const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Support filtering tests via `zig build test -Dtest-filter="parse number"`
    const test_filter = b.option([]const u8, "test-filter", "Skip tests that do not match filter");

    // 1. Core 'jzonnet' library module
    const mod = b.addModule("jzonnet", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // 2. Main CLI executable module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "jzonnet", .module = mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "jzonnet",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // 3. 'zig build run' step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // 4. 'zig build test' step
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    if (test_filter) |filter| {
        run_mod_tests.addArgs(&.{ "--test-filter", filter });
        run_exe_tests.addArgs(&.{ "--test-filter", filter });
    }

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // 5. 'zig build check' step (used by ZLS for fast LSP checking on save)
    const exe_check = b.addExecutable(.{
        .name = "jzonnet",
        .root_module = exe_mod,
    });

    const check_step = b.step("check", "Check if the app compiles");
    check_step.dependOn(&exe_check.step);
    check_step.dependOn(&mod_tests.step);
    check_step.dependOn(&exe_tests.step);
}
