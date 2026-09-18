//! The same 63 bytes, on a name somebody wrote themselves. The fix is not a
//! `.name` this time — it is a shorter one.

const sql = @import("nilo_sql");

const Sku = struct {
    pub const nilo_table = .{
        .name = "skus",
        .key = .id,
        .unique = .{.{
            .columns = .{ .product_id, .term_id },
            .name = "skus_are_unique_per_product_and_per_term_and_per_platform_and_per_region",
        }},
    };

    id: i64,
    product_id: i64,
    term_id: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, .{ .tables = &.{Sku} });
}
