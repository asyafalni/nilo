//! A type that says it is exactly a `Payload` (`nilo_json_of`) and holds it
//! under some other name. A document is written as its `value`, so the field
//! has to be there and has to be that type (ADR 0202).

const nilo = @import("nilo_http");

const Payload = struct { theme: []const u8 };

const Settings = struct {
    pub const nilo_json_of = Payload;

    inner: Payload,

    pub fn jsonStringify(self: @This(), jw: anytype) !void {
        try jw.write(self.inner);
    }
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Settings);
}
