//! `.after` over a `sql.Decimal` on SQLite is a `>` on text, so a page ends
//! where `9.99` is greater than `100.00`. Refused (ADR 049, ADR 150).

const sql = @import("nilo_sql");

const Invoice = struct {
    pub const nilo_table = .{ .name = "invoices", .key = .id };

    id: i64,
    total: sql.Decimal,
};

export fn refusal() void {
    _ = sql.statement.afterOf(
        sql.dialect.SQLite,
        Invoice,
        @TypeOf(.{
            .order = .{ .total = .asc, .id = .asc },
            .after = .{ .total = sql.Decimal{ .text = "9.99" }, .id = @as(i64, 1) },
        }),
        "",
        1,
        "a read",
    );
}
