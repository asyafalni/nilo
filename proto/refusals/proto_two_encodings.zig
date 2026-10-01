//! A field cannot travel two ways.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .id = .{ 1, .sint32, .sfixed32 } };
    id: i32 = 0,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
