//! Two sides of a foreign key holding different types, where the target was
//! named as text. The check is the same one a target written as a type gets;
//! what moved is where it runs (ADR 181).

const sql = @import("nilo_sql");

const Org = struct {
    pub const nilo_table = .{ .name = "orgs", .key = .id };

    id: i64,
    name: []const u8,
};

const User = struct {
    pub const nilo_table = .{
        .name = "users",
        .key = .id,
        .references = .{ .org_id = .{ "orgs", .id } },
    };

    id: i64,
    org_id: []const u8,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{ Org, User } });
}
