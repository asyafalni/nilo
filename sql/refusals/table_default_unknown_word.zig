//! A word `.default` does not have. The one it has is `.now`; everything else
//! is a literal of the column's own type, and a default the database has to
//! work out is a step.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .default = .{ .token = .gen_uuid },
    };

    id: i64,
    token: sql.Uuid,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{User} });
}
