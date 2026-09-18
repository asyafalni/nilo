//! A check written as a struct that is not `.{ .words_of = … }`. A check is
//! SQL, as text, and there is exactly one other shape.

const sql = @import("nilo_sql");

const Ledger = struct {
    pub const nilo_table = .{
        .name = "ledgers",
        .key = .id,
        .check = .{ .ledgers_amount_is_positive = .{ .body = "amount > 0" } },
    };

    id: i64,
    amount: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{Ledger} });
}
