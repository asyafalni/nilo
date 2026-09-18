//! A function in a SQLite schema. A SQLite function is a callback registered
//! on the connection, not a statement, so the list is refused (ADR 0253).

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };
    id: i64,
    name: []const u8,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.SQLite, .{
        .tables = &.{User},
        .functions = &.{
            .{ .name = "touch", .body = "CREATE OR REPLACE FUNCTION touch() RETURNS trigger AS $$ BEGIN RETURN NEW; END $$ LANGUAGE plpgsql" },
        },
    });
}
