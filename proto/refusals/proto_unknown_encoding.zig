//! An encoding spelled wrong: `.sint` is not one of the nine.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .id = .{ 1, .sint } };
    id: i32 = 0,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
