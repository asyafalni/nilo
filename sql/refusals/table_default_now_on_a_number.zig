//! `.now` on a column that holds no moment. It is the time the row was
//! written, so it goes in a `sql.Timestamp`.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .default = .{ .age = .now },
    };

    id: i64,
    age: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{User} });
}
