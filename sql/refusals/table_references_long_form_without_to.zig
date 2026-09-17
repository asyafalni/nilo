//! The long form of `.references` with columns and no table to point them at.

const sql = @import("nilo_sql");

const Card = struct {
    pub const nilo_table = .{
        .name = "cards",
        .key = .id,
        .references = .{
            .board = .{ .columns = .{ .board_id, .org_id } },
        },
    };

    id: i64,
    board_id: i64,
    org_id: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{Card});
}
