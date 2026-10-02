//! `.misfit` on an enum. An enum is read from one string and is never a body
//! of its own; the entry belongs on the struct a body is read into.

const nilo = @import("nilo_http");

const Severity = enum {
    pub const nilo_json = .{ .misfit = 422 };

    low,
    high,
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Severity);
}
