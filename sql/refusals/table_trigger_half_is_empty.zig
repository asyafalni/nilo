//! A trigger with one of its two halves empty. The statement would be written
//! with a hole in it.

const sql = @import("nilo_sql");

const Ledger = struct {
    pub const nilo_table = .{
        .name = "ledgers",
        .key = .id,
        .trigger = .{
            .ledgers_touch = .{ .when = "BEFORE UPDATE", .run = "" },
        },
    };

    id: i64,
    amount: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{Ledger} });
}
