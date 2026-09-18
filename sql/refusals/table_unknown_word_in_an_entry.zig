//! A misspelled word inside a `.unique`. Without the check it is a plain
//! unique that compiles, creates an index and folds no case — found the day
//! two rows that differ by capitals both go in.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .unique = .{.{ .columns = .{.email}, .ignorng_case = true }},
    };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{User} });
}
