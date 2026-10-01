//! A `wire` entry for a field that was renamed away: a stale number that would never be read.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .id = 1, .nmae = 2 };
    id: u32 = 0,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
