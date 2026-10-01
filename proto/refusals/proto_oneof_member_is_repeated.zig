//! A repeated member in a oneof, which protobuf does not allow.

const proto = @import("nilo_proto");

const Choice = union(enum) {
    pub const wire = .{ .a = 1 };
    a: []const u32,
};
const Msg = struct {
    pub const wire = .{};
    choice: ?Choice = null,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
