//! Two tables giving an index the same name. The name belongs to the schema
//! on both databases, so the plan passed and the second `CREATE INDEX`
//! failed when the version ran (ADR 123).

const sql = @import("nilo_sql");

const Order = struct {
    pub const nilo_table = .{
        .name = "orders",
        .key = .id,
        .index = .{.{ .columns = .{.created_at}, .name = "by_created_at" }},
    };
    id: i64,
    created_at: sql.Timestamp,
};

const Invoice = struct {
    pub const nilo_table = .{
        .name = "invoices",
        .key = .id,
        .index = .{.{ .columns = .{.created_at}, .name = "by_created_at" }},
    };
    id: i64,
    created_at: sql.Timestamp,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{ Order, Invoice } });
}
