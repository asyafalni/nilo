//! A check name Postgres would take and then cut down at 63 bytes, in a
//! NOTICE nothing here reads. The snapshot would hold a name the database does
//! not have.

const sql = @import("nilo_sql");

const Ledger = struct {
    pub const nilo_table = .{
        .name = "ledgers",
        .key = .id,
        .check = .{
            .ledgers_amount_is_positive_and_the_currency_is_one_we_actually_settle_in = "amount > 0",
        },
    };

    id: i64,
    amount: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{Ledger} });
}
