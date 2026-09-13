//! A `.rename` entry spelling a field exactly as it is written, which changes
//! nothing — refused the way `.rename_all = .snake_case` is, because a line
//! that does nothing is a line somebody will read as doing something
//! ([ADR 0207](../docs/adr/0207-one-field-can-be-spelled-on-its-own.md)).

const nilo = @import("nilo_http");

const Summary = struct {
    pub const nilo_json = .{ .rename = .{ .amount = "amount" } };

    amount: i64,
};

export fn refusal() void {
    _ = nilo.openapi.schemaOf(Summary);
}
