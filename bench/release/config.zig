//! nilo_config: a settings struct of every kind a field may be (text, a
//! number, a bool, an enum, an optional) read from pairs and handed back,
//! which is the whole of what a program does with it at startup.

const std = @import("std");
const config = @import("nilo_config");
const harness = @import("harness");

pub fn main(init: std.process.Init.Minimal) !void {
    return harness.run(init, Program);
}

const Settings = struct {
    database_url: []const u8,
    port: u16 = 8080,
    debug: bool = false,
    log_level: enum { debug, info, warn } = .info,
    workers: ?u8 = null,
};

const Program = struct {
    pairs: []const config.Fixed.Pair,

    pub fn init(_: std.mem.Allocator) !Program {
        return .{ .pairs = &.{
            .{ "DATABASE_URL", "postgres://app@localhost:5432/app" },
            .{ "PORT", "9000" },
            .{ "DEBUG", "true" },
            .{ "LOG_LEVEL", "warn" },
            .{ "WORKERS", "8" },
        } };
    }

    pub fn deinit(_: *Program) void {}

    pub fn op(self: *Program, _: std.mem.Allocator, _: usize) !void {
        // Behind `keep`, so the optimiser cannot read the pairs while compiling.
        harness.keep(&self.pairs);
        const read = config.from(Settings, config.Fixed{ .pairs = self.pairs });
        const settings = read.value() orelse return error.SettingsFailed;
        harness.keep(&settings);
    }
};
