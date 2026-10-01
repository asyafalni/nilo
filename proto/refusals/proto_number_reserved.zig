//! 19,000 to 19,999 are reserved for protobuf's own use.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .id = 19_500 };
    id: u32 = 0,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
