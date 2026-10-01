//! A `wire` entry that is a string, from writing the field's name where its number goes.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .id = "1" };
    id: u32 = 0,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
