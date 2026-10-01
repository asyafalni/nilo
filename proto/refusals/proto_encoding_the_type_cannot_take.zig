//! `.sint64` on a u32: zigzag is for signed numbers, and the type says which a field is.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .id = .{ 1, .sint64 } };
    id: u32 = 0,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
