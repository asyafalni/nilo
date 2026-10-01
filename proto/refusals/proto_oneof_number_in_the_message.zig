//! A oneof's numbers written in the message's table, where they would be read as the message's own.

const proto = @import("nilo_proto");

const Choice = union(enum) {
    pub const wire = .{ .a = 1, .b = 2 };
    a: u32,
    b: []const u8,
};
const Msg = struct {
    pub const wire = .{ .choice = 3 };
    choice: ?Choice = null,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
