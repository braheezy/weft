const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const crdt_lib = b.dependency("crdt_zig", .{ .target = target, .optimize = optimize });
    const vaxis = b.lazyDependency("vaxis", .{ .target = target, .optimize = optimize }) orelse return;
    const exe = b.addExecutable(.{
        .name = "weft",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "crdt_zig", .module = crdt_lib.module("crdt_zig") },
                .{ .name = "vaxis", .module = vaxis.module("vaxis") },
            },
        }),
    });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.stdio = .inherit;
    run.addPassthruArgs();
    b.step("run", "Run weft").dependOn(&run.step);
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/network.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "crdt_zig", .module = crdt_lib.module("crdt_zig") }},
        }),
    });
    b.step("test", "Weft integration and session persistence").dependOn(&b.addRunArtifact(tests).step);
}
