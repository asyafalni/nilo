//! `.unknown_fields` on an enum. An enum is read from one string and has no
//! keys to skip; the marker belongs on the struct a body is read into.

const nilo = @import("nilo_http");

const Severity = enum {
    pub const nilo_json = .{ .unknown_fields = .ignore };

    low,
    high,
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Severity);
}
