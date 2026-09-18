//! A function written as a plain `CREATE FUNCTION`. Applied twice it fails
//! the second time, and a moved body could not be one step, so the entry has
//! to open `CREATE OR REPLACE FUNCTION <name>` (ADR 0253).

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };
    id: i64,
    name: []const u8,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{
        .tables = &.{User},
        .functions = &.{
            .{ .name = "set_updated_at", .body = "CREATE FUNCTION set_updated_at() RETURNS trigger AS $$ BEGIN RETURN NEW; END $$ LANGUAGE plpgsql" },
        },
    });
}
