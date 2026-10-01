//! A function whose name has capitals, written without quotes in its body.
//! Postgres keeps it in lower case, and nilo drops a function by the name in
//! the entry, in quotes, so the drop found nothing and its `IF EXISTS` said
//! nothing either (ADR 181).

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
            .{ .name = "setUpdatedAt", .body = "CREATE OR REPLACE FUNCTION setUpdatedAt() RETURNS trigger AS $$ BEGIN RETURN NEW; END $$ LANGUAGE plpgsql" },
        },
    });
}
