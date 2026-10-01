//! `[]u8` where a decoded string would have to be copied out of the input to be written to.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .name = 1 };
    name: []u8 = &.{},
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
