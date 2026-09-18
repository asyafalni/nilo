//! A default that is not the column's own type. Nothing converts it on the
//! way: the database reads the text as it stands.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .default = .{ .age = "18" },
    };

    id: i64,
    age: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{User} });
}
