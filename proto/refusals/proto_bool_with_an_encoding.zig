//! A bool is a varint and has no other way to travel.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .on = .{ 1, .fixed32 } };
    on: bool = false,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
