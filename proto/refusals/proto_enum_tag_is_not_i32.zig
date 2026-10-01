//! A protobuf enum is an int32 on the wire, and `enum(u8)` would drop the top bits of a number it was sent.

const proto = @import("nilo_proto");

const Kind = enum(u8) { a, b, _ };
const Msg = struct {
    pub const wire = .{ .kind = 1 };
    kind: Kind = .a,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
