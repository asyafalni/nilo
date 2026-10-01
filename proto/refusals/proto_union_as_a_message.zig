//! A union handed to `decode` as if it were a message.

const proto = @import("nilo_proto");

const Choice = union(enum) {
    pub const wire = .{ .a = 1 };
    a: u32,
};

export fn refusal() void {
    _ = proto.decode(Choice, undefined, "") catch {};
}
