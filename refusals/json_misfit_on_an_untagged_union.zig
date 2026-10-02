//! `.misfit` on a union with no `.tag`. `std.json` reads an externally tagged
//! union by itself and says nothing about why a body did not fit, so nilo
//! cannot tell JSON of the wrong shape from anything else it refuses.

const nilo = @import("nilo_http");

const Condition = union(enum) {
    pub const nilo_json = .{ .misfit = 422 };

    metrics: struct { threshold: f64 },
    logs: struct { query: []const u8 },
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Condition);
}
