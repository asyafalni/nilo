//! Two entries naming the check over one column's words. One of the two would
//! be a constraint the database never gets.

const sql = @import("nilo_sql");

const Level = enum { low, high };

const Ticket = struct {
    pub const nilo_table = .{
        .name = "tickets",
        .key = .id,
        .check = .{
            .tickets_level_is_known = .{ .words_of = .level },
            .tickets_level_is_one_of_two = .{ .words_of = .level },
        },
    };

    id: i64,
    level: Level,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{Ticket});
}
