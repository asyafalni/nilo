//! `[]const ?u32`: the wire has no way to write a hole in a list.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .ids = 1 };
    ids: []const ?u32 = &.{},
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
