//! A message field with an encoding, from putting `.bytes` on a nested struct.

const proto = @import("nilo_proto");

const Inner = struct {
    pub const wire = .{ .id = 1 };
    id: u32 = 0,
};
const Msg = struct {
    pub const wire = .{ .inner = .{ 1, .bytes } };
    inner: ?Inner = null,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
