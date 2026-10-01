//! A field number past 536,870,911, which does not fit in a key.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .id = 536_870_912 };
    id: u32 = 0,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
