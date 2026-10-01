//! Repeated strings are never packed, so `.unpacked` on them says nothing true.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .tags = .{ 1, .unpacked } };
    tags: []const []const u8 = &.{},
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
