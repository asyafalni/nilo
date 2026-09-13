//! A `.rename` entry naming a field the struct does not have. The entry is
//! keyed by the field as it is written, so a typo here is a spelling that
//! would never apply, refused where it was written
//! ([ADR 0207](../docs/adr/0207-one-field-can-be-spelled-on-its-own.md)).

const nilo = @import("nilo_http");

const Summary = struct {
    pub const nilo_json = .{ .rename_all = .camelCase, .rename = .{ .estimated_cost = "estimatedCostMinor" } };

    id: i64,
    estimated_cost_amount_minor: i64,
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Summary);
}
