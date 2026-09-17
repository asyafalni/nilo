//! A direction on a unique constraint. It holds whichever way the index behind
//! it is read, so the word would do nothing.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .unique = .{.{ .columns = .{ .org_id, .{ .created_at = .desc } } }},
    };

    id: i64,
    org_id: i64,
    created_at: sql.Timestamp,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{User});
}
