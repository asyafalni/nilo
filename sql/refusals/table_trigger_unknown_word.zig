//! A misspelled word inside a `.trigger`. Without the check the half goes
//! missing and the statement is `CREATE TRIGGER "n"  ON "t" …`, which the
//! database refuses at deploy rather than here.

const sql = @import("nilo_sql");

const Ledger = struct {
    pub const nilo_table = .{
        .name = "ledgers",
        .key = .id,
        .trigger = .{
            .ledgers_touch = .{
                .when = "BEFORE UPDATE",
                .run = "FOR EACH ROW EXECUTE FUNCTION set_updated_at()",
                .on = "ledgers",
            },
        },
    };

    id: i64,
    amount: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{Ledger});
}
