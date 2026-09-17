//! A constraint's name written as a column. It is the sentence Postgres says
//! when a row breaks it, so it is text rather than one of the Row's own names.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .unique = .{.{ .columns = .{ .org_id, .email }, .name = .one_per_board }},
    };

    id: i64,
    org_id: i64,
    email: []const u8,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{User});
}
