//! One of a column's words written as text. A word is written the way a column
//! is, so that a tag renamed in Zig moves the default with it.

const sql = @import("nilo_sql");

const Priority = enum { urgent, high, normal, low };

const Task = struct {
    pub const nilo_table = .{
        .name = "tasks",
        .key = .id,
        .default = .{ .priority = "normal" },
    };

    id: i64,
    priority: Priority,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{Task});
}
