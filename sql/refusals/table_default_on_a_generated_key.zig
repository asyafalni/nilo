//! A default on a key the database fills in from a sequence. It already has
//! one, and it is the sequence.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .default = .{ .id = 1 },
    };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{User} });
}
