//! A default that is not one of the enum's tags. The column would be created
//! with a CHECK that refuses its own default.

const sql = @import("nilo_sql");

const Priority = enum { urgent, high, normal, low };

const Task = struct {
    pub const nilo_table = .{
        .name = "tasks",
        .key = .id,
        .default = .{ .priority = .blocker },
    };

    id: i64,
    priority: Priority,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{Task} });
}
