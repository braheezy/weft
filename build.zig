const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const library = b.dependency("collab", .{ .target = target, .optimize = optimize });
    const vaxis = b.lazyDependency("vaxis", .{ .target = target, .optimize = optimize }) orelse return;
    const exe = b.addExecutable(.{
        .name = "weft",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "collab", .module = library.module("collab") },
                .{ .name = "vaxis", .module = vaxis.module("vaxis") },
            },
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.stdio = .inherit;
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run weft").dependOn(&run.step);
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/network.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "collab", .module = library.module("collab") }},
        }),
    });
    b.step("test", "Weft integration and session persistence").dependOn(&b.addRunArtifact(tests).step);
}
