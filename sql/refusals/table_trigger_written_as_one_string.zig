//! A trigger written as one string. nilo writes `ON "<table>"` in the middle,
//! and finding where that goes inside a string is parsing SQL.

const sql = @import("nilo_sql");

const Ledger = struct {
    pub const nilo_table = .{
        .name = "ledgers",
        .key = .id,
        .trigger = .{
            .ledgers_touch = "BEFORE UPDATE FOR EACH ROW EXECUTE FUNCTION set_updated_at()",
        },
    };

    id: i64,
    amount: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{Ledger} });
}
