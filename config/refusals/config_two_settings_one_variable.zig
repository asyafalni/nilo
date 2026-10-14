//! A plain field and a group's field that spell one variable. `smtp_host`
//! and `smtp.host` both read `SMTP_HOST` (ADR 289).

const config = @import("nilo_config");

const Settings = struct {
    smtp_host: ?[]const u8 = null,
    smtp: ?struct { host: []const u8 } = null,
};

export fn refusal() void {
    const read = config.from(Settings, config.Fixed{ .pairs = &.{} });
    _ = read;
}
