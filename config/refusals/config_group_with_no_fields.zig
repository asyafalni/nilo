//! A group with no fields would read nothing, and never be switched on
//! (ADR 289).

const config = @import("nilo_config");

const Smtp = struct {};

const Settings = struct {
    port: u16 = 8080,
    smtp: ?Smtp = null,
};

export fn refusal() void {
    const read = config.from(Settings, config.Fixed{ .pairs = &.{} });
    _ = read;
}
