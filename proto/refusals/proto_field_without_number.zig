//! One field forgotten in the `wire` table. The decoder would have no number to look for, so it is refused instead of read as always zero.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .id = 1 };
    id: u32 = 0,
    name: []const u8 = "",
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
