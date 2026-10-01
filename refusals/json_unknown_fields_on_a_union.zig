//! `.unknown_fields` on a tagged union. A union has no keys of its own: the
//! keys are the ones the variant's struct has, so that struct is where the
//! marker goes.

const nilo = @import("nilo_http");

const Condition = union(enum) {
    pub const nilo_json = .{ .tag = "signal", .unknown_fields = .ignore };

    metrics: struct { threshold: f64 },
    logs: struct { query: []const u8 },
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Condition);
}
