//! A group inside a group. Its variable names would be a convention nobody
//! could predict, so the inner one goes beside the outer (ADR 289).

const config = @import("nilo_config");

const Settings = struct {
    port: u16 = 8080,
    smtp: ?struct {
        host: []const u8,
        relay: ?struct { host: []const u8 } = null,
    } = null,
};

export fn refusal() void {
    const read = config.from(Settings, config.Fixed{ .pairs = &.{} });
    _ = read;
}
