//! Two groups whose names run together: `a.b_c` and `a_b.c` both read
//! `A_B_C` (ADR 289).

const config = @import("nilo_config");

const Settings = struct {
    a: ?struct { b_c: []const u8 } = null,
    a_b: ?struct { c: []const u8 } = null,
};

export fn refusal() void {
    const read = config.from(Settings, config.Fixed{ .pairs = &.{} });
    _ = read;
}
