//! An extension named in a SQLite schema. SQLite loads an extension into a
//! connection; there is no statement that creates one, so the list is refused
//! rather than sent (ADR 181).

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };
    id: i64,
    name: []const u8,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.SQLite, .{
        .tables = &.{User},
        .extensions = &.{"pgcrypto"},
    });
}
