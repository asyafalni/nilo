//! A direction that is neither `.asc` nor `.desc`.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .index = .{.{ .columns = .{.{ .created_at = .down }} }},
    };

    id: i64,
    created_at: sql.Timestamp,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{User} });
}
