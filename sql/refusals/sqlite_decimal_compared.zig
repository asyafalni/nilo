//! `.gt` on a `sql.Decimal` on SQLite. The column is TEXT there, and SQLite
//! compares text as text, so `.total = .{ .gt = "9.99" }` misses `"100.00"`.
//! Refused instead of answering wrong on one database only; equality stays
//! (ADR 049, ADR 055).

const sql = @import("nilo_sql");

const Invoice = struct {
    pub const nilo_table = .{ .name = "invoices", .key = .id };

    id: i64,
    total: sql.Decimal,
};

export fn refusal() void {
    _ = sql.statement.select(sql.dialect.SQLite, Invoice, @TypeOf(.{
        .where = .{ .total = .{ .gt = sql.Decimal{ .text = "9.99" } } },
    }));
}
