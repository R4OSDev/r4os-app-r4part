const std = @import("std");
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const dependency = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, dependency, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));
    const model = b.createModule(.{ .root_source_file = b.path("src/command.zig"), .target = b.graph.host, .optimize = .Debug });
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = model }));
    const test_step = b.step("test", "Command validation and explicit target confirmation");
    test_step.dependOn(&tests.step);
    const host = sdk.createR4osModule(b.graph.host, .ReleaseSafe);
    const target_root = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    target_root.addImport("r4os", host);
    const target_tests = b.addRunArtifact(b.addTest(.{ .root_module = target_root, .filters = &.{"migration storage target"} }));
    test_step.dependOn(&target_tests.step);
}
