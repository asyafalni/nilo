//! `.unpacked` on a field that is not repeated, from copying a repeated field's line.

const proto = @import("nilo_proto");

const Msg = struct {
    pub const wire = .{ .id = .{ 1, .unpacked } };
    id: u32 = 0,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
