//! An `sql.Ordering` key over a `sql.Decimal` on SQLite. The request chooses
//! which key runs, so the check is made where the statement is built for the
//! Dialect, not on the first request that picks it (ADR 049, ADR 165).

const sql = @import("nilo_sql");

const Invoice = struct {
    pub const nilo_table = .{ .name = "invoices", .key = .id };

    id: i64,
    total: sql.Decimal,
};

const Sort = sql.Ordering(Invoice, .{ .total = .total });

export fn refusal() void {
    // What `db.select` sizes its statement with once it knows the Dialect.
    _ = Sort.most(sql.dialect.SQLite);
}
