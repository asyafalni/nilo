//! An empty check body. `CHECK ()` is not a constraint, and the entry is more
//! likely half-finished than meant.

const sql = @import("nilo_sql");

const Ledger = struct {
    pub const nilo_table = .{
        .name = "ledgers",
        .key = .id,
        .check = .{ .ledgers_amount_is_positive = "" },
    };

    id: i64,
    amount: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{Ledger});
}
