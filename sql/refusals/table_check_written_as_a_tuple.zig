//! `.check` written as a tuple. It has no columns to derive a name from, so
//! the key has to be the name the constraint goes into the database under.

const sql = @import("nilo_sql");

const Ledger = struct {
    pub const nilo_table = .{
        .name = "ledgers",
        .key = .id,
        .check = .{"amount > 0"},
    };

    id: i64,
    amount: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{Ledger});
}
