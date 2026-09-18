//! `.words_of` on a column that is not a Zig enum. There is no generated check
//! to give a name to, so the entry is a constraint that never arrives.

const sql = @import("nilo_sql");

const Ticket = struct {
    pub const nilo_table = .{
        .name = "tickets",
        .key = .id,
        .check = .{ .tickets_title_is_known = .{ .words_of = .title } },
    };

    id: i64,
    title: []const u8,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{Ticket} });
}
