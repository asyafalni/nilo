//! Field numbers start at 1: key 0 is how the wire says the input is damaged.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .id = 0 };
    id: u32 = 0,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
