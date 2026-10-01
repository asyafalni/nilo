//! A struct handed to `decode` with no `wire` table: nothing says which number is which field.

const proto = @import("nilo_proto");

const Msg = struct {
    id: u32 = 0,
};

export fn refusal() void {
    _ = proto.decode(Msg, undefined, "") catch {};
}
