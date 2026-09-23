//! A column in both `.default` and `.filled`: two answers to how it is
//! filled, which is how they come apart.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .default = .{ .created_at = .now },
        .filled = .created_at,
    };

    id: i64,
    created_at: sql.Timestamp,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{User} });
}
