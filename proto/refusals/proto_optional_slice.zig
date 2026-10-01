//! `?[]const u32`: a repeated field is never absent, only empty.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .ids = 1 };
    ids: ?[]const u32 = null,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
