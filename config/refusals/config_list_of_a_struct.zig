//! A list of something one entry of a variable cannot become. An entry is
//! text, a number, a bool or an enum (ADR 289).

const config = @import("nilo_config");

const Broker = struct { host: []const u8, port: u16 };

const Settings = struct {
    brokers: config.List(Broker, 4),
};

export fn refusal() void {
    const read = config.from(Settings, config.Fixed{ .pairs = &.{} });
    _ = read;
}
