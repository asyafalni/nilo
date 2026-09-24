const std = @import("std");

/// Out of the way of the repo's own `zig build`, the same way
/// `spike/mailbox/` is: a spike is a question asked once, not a thing the
/// test suite has to keep passing.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zio = b.dependency("zio", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "fiber-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zio", .module = zio.module("zio") }},
        }),
    });
    b.installArtifact(exe);
}
