//! A check body that is not text. nilo does not read the body, so a number
//! there is not a body it could make sense of some other way.

const sql = @import("nilo_sql");

const Ledger = struct {
    pub const nilo_table = .{
        .name = "ledgers",
        .key = .id,
        .check = .{ .ledgers_amount_is_positive = 0 },
    };

    id: i64,
    amount: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{Ledger} });
}
