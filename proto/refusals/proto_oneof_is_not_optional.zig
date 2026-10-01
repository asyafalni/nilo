//! A oneof that is not optional, which cannot say none of its members was on the wire.

const proto = @import("nilo_proto");

const Choice = union(enum) {
    pub const wire = .{ .a = 1, .b = 2 };
    a: u32,
    b: []const u8,
};
const Msg = struct {
    pub const wire = .{};
    choice: Choice = .{ .a = 0 },
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
