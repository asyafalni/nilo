//! A foreign key naming its table as text, pointing at a table no Row in the
//! list names. The type check moved one level up rather than away, so the list
//! is where the name has to resolve (ADR 0222).

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .references = .{ .org_id = .{ "orgs", .id } },
    };

    id: i64,
    org_id: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{User});
}
