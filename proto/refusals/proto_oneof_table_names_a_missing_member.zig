//! A oneof table that numbers a member the union does not have.

const proto = @import("nilo_proto");

const Choice = union(enum) {
    pub const wire = .{ .a = 1, .c = 3 };
    a: u32,
};
const Msg = struct {
    pub const wire = .{};
    choice: ?Choice = null,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
