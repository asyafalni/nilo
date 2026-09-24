//! A `.rename` entry that spells one field the way the case already spells
//! another. The same mistake `rename_all` alone can make, with the entry as
//! the cause — and the advice points at the entry rather than at the cases
//! ([ADR 168](../docs/adr/168-one-field-can-be-spelled-on-its-own.md)).

const nilo = @import("nilo_http");

const Summary = struct {
    pub const nilo_json = .{ .rename_all = .camelCase, .rename = .{ .amount_minor = "dueAt" } };

    amount_minor: i64,
    due_at: []const u8,
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Summary);
}
