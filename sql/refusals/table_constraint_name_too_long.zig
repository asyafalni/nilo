//! A derived constraint name past 63 bytes. Postgres cuts it down on the way
//! in, in a NOTICE nothing reads, and the snapshot then holds a name the
//! database does not have.

const sql = @import("nilo_sql");

const Sku = struct {
    pub const nilo_table = .{
        .name = "skus",
        .key = .id,
        .unique = .{.{ .product_type_id, .platform_id, .acquisition_id, .product_id, .term_id }},
    };

    id: i64,
    product_type_id: i64,
    platform_id: i64,
    acquisition_id: i64,
    product_id: i64,
    term_id: i64,
};

export fn refusal() void {
    _ = comptime sql.migrate.missingOf(sql.Postgres, &.{Sku});
}
