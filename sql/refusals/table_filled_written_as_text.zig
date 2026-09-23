//! `.filled` names columns the way the rest of the marker does, not as text.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .filled = "created_at" };

    id: i64,
    created_at: sql.Timestamp,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{User} });
}
