//! A partial index whose predicate asks for something the four terms cannot
//! say. Anything wider than them is an index written as a step.

const sql = @import("nilo_sql");

const Task = struct {
    pub const nilo_table = .{
        .name = "tasks",
        .key = .id,
        .index = .{.{ .columns = .{.weight}, .where = .{ .weight = .{ .gt = 3 } } }},
    };

    id: i64,
    weight: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{Task});
}
