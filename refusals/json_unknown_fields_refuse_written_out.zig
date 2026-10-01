//! `.unknown_fields = .refuse`, written out. Refusing is what every type does
//! with a key it has no field for, so the line would change nothing, and a
//! marker that changes nothing is the silence ADR 016 refuses.

const nilo = @import("nilo_http");

const Settings = struct {
    pub const nilo_json = .{ .unknown_fields = .refuse };

    theme: []const u8,
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Settings);
}
