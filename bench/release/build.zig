//! One program a module, each running that module's everyday operation, for
//! `bench/release.py` (ADR 242). Its own package, depending on nilo by path,
//! so `release.py` can copy it into a tree exported from any tag and build it
//! against that tag's modules: an old tag's `build.zig` has never heard of it.
//!
//! One step a program, `zig build <module>`, so a program that a ref's API
//! cannot compile fails alone. A module the ref does not export is no program
//! at all rather than a failed configure, which would take every step with it.

const std = @import("std");

const Program = struct {
    /// The file, the step, and the module the numbers are filed under.
    name: []const u8,
    /// What it imports from nilo.
    imports: []const []const u8,
    /// Built with `.sql = true`, the flag that brings pg.zig and SQLite.
    sql: bool = false,
    /// Built with `.fetch_gzip = true`, and only when the package is given
    /// `-Dfetch_gzip`: a ref older than the flag refuses the option, so
    /// nothing that names it is configured by default (ADR 292).
    fetch_gzip: bool = false,
};

pub const programs = [_]Program{
    .{ .name = "core", .imports = &.{"nilo_core"} },
    .{ .name = "id", .imports = &.{"nilo_id"} },
    .{ .name = "config", .imports = &.{"nilo_config"} },
    .{ .name = "pw", .imports = &.{"nilo_pw"} },
    .{ .name = "cache", .imports = &.{"nilo_cache"} },
    .{ .name = "jwt", .imports = &.{"nilo_jwt"} },
    .{ .name = "proto", .imports = &.{"nilo_proto"} },
    .{ .name = "fetch", .imports = &.{ "nilo_fetch", "nilo_core" } },
    .{ .name = "fetch_ws", .imports = &.{ "nilo_fetch", "nilo_core" } },
    .{ .name = "fetch_gzip", .imports = &.{ "nilo_fetch", "nilo_core" }, .fetch_gzip = true },
    .{ .name = "job", .imports = &.{ "nilo_job", "nilo_core" } },
    .{ .name = "job_zoned", .imports = &.{"nilo_job"} },
    .{ .name = "sql", .imports = &.{ "nilo_sql", "nilo_core" }, .sql = true },
    .{ .name = "s3", .imports = &.{ "nilo_s3", "nilo_core" } },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Leave debug info out, as every size here is measured") orelse true;
    // Every program that names nilo_fetch is built with the flag when this is
    // given, so `fetch` and `fetch_gzip` can be compared on one binary size.
    const fetch_gzip = b.option(bool, "fetch_gzip", "Build against nilo with `.fetch_gzip = true` (ADR 292)") orelse false;

    const harness = b.createModule(.{
        .root_source_file = b.path("harness.zig"),
        .target = target,
        .optimize = optimize,
    });

    for (programs) |p| {
        const step = b.step(p.name, b.fmt("Build the program that measures nilo_{s}", .{p.name}));
        if (p.fetch_gzip and !fetch_gzip) {
            step.dependOn(&b.addFail("this program needs -Dfetch_gzip").step);
            continue;
        }
        const nilo = if (p.sql)
            b.dependency("nilo", .{ .target = target, .optimize = optimize, .sql = true })
        else if (fetch_gzip)
            b.dependency("nilo", .{ .target = target, .optimize = optimize, .fetch_gzip = true })
        else
            b.dependency("nilo", .{ .target = target, .optimize = optimize });

        const module = b.createModule(.{
            .root_source_file = b.path(b.fmt("{s}.zig", .{p.name})),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{.{ .name = "harness", .module = harness }},
        });
        const exported = for (p.imports) |name| {
            const found = nilo.builder.modules.get(name) orelse break false;
            module.addImport(name, found);
        } else true;
        if (!exported) {
            step.dependOn(&b.addFail(b.fmt("this ref exports no {s}", .{p.imports[0]})).step);
            continue;
        }

        const exe = b.addExecutable(.{
            .name = b.fmt("nilo-release-{s}", .{p.name}),
            .root_module = module,
        });
        step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    }
}
