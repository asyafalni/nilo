//! Two partial indexes over one column. The name is derived from the table and
//! the columns, so the two collide — and the second `CREATE` would fail at
//! migrate time, after the first had already run.

const sql = @import("nilo_sql");

const Outbox = struct {
    pub const nilo_table = .{
        .name = "outbox",
        .key = .id,
        .index = .{
            .{ .columns = .{.sent_at}, .where = .{ .sent_at = null } },
            .{ .columns = .{.sent_at}, .where = .{ .sent_at = .{ .ne = null } } },
        },
    };

    id: i64,
    sent_at: ?sql.Timestamp,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{Outbox} });
}
