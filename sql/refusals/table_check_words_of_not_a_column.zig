//! `.words_of` naming something that is not a column. The check would be over
//! nothing, and nothing would say so until the CREATE TABLE ran.

const sql = @import("nilo_sql");

const Level = enum { low, high };

const Ticket = struct {
    pub const nilo_table = .{
        .name = "tickets",
        .key = .id,
        .check = .{ .tickets_level_is_known = .{ .words_of = .levell } },
    };

    id: i64,
    level: Level,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{Ticket} });
}
