//! A view written as the whole `CREATE VIEW`. nilo writes that head itself,
//! for the reason a trigger is two words: the name is the thing the schema
//! already knows, and a second copy of it stops matching (ADR 0253).

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };
    id: i64,
    name: []const u8,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{
        .tables = &.{User},
        .views = &.{
            .{ .name = "names", .body = "CREATE VIEW names AS SELECT name FROM users" },
        },
    });
}
