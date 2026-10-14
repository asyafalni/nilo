//! A list that can hold nothing. The capacity is the type's, so zero is a
//! list that could never be what it was read from (ADR 289).

const config = @import("nilo_config");

const Settings = struct {
    hosts: config.List([]const u8, 0),
};

export fn refusal() void {
    const read = config.from(Settings, config.Fixed{ .pairs = &.{} });
    _ = read;
}
