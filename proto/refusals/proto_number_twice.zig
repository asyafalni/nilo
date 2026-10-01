//! Two fields given one number, which would make one of them unreachable.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .id = 1, .name = 1 };
    id: u32 = 0,
    name: []const u8 = "",
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
