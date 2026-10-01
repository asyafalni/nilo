//! A oneof member added to the union and not to its table.

const proto = @import("nilo_proto");

const Choice = union(enum) {
    pub const wire = .{ .a = 1 };
    a: u32,
    b: []const u8,
};
const Msg = struct {
    pub const wire = .{};
    choice: ?Choice = null,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
