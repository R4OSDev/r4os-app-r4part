const std = @import("std");
pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const dependency = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, dependency, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));
    const model = b.createModule(.{ .root_source_file = b.path("src/command.zig"), .target = b.graph.host, .optimize = .Debug });
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = model }));
    b.step("test", "Command validation and explicit target confirmation").dependOn(&tests.step);
}
