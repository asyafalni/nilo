//! A partial index comparing a column against a literal of another type. The
//! predicate is checked exactly as a condition is, which is what makes it a
//! vocabulary rather than the string ADR 123 refused.

const sql = @import("nilo_sql");

const Task = struct {
    pub const nilo_table = .{
        .name = "tasks",
        .key = .id,
        .index = .{.{ .columns = .{.weight}, .where = .{ .weight = "heavy" } }},
    };

    id: i64,
    weight: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{Task} });
}
