//! A foreign key pointing at a type that is not a Row. A table's own name as
//! text is the other spelling and is allowed; a plain struct is neither.

const sql = @import("nilo_sql");

const Org = struct {
    id: i64,
    name: []const u8,
};

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .references = .{ .org_id = .{ Org, .id } },
    };

    id: i64,
    org_id: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{User} });
}
