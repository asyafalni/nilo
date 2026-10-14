//! A default longer than the list has room for (ADR 289).

const config = @import("nilo_config");

const Settings = struct {
    hosts: config.List([]const u8, 1) = .of(&.{ "a", "b" }),
};

export fn refusal() void {
    const read = config.from(Settings, config.Fixed{ .pairs = &.{} });
    _ = read;
}
