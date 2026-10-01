//! A u16: protobuf has int32, int64, uint32 and uint64, and no 16 bit number, so this field cannot be what its type says.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .port = 1 };
    port: u16 = 0,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
