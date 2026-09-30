//! `.order` on a `sql.Decimal` on SQLite sorts the digits as text, so `100.00`
//! comes before `9.99`. Refused, the same as `.gt` is (ADR 049).

const sql = @import("nilo_sql");

const Invoice = struct {
    pub const nilo_table = .{ .name = "invoices", .key = .id };

    id: i64,
    total: sql.Decimal,
};

export fn refusal() void {
    _ = sql.statement.select(sql.dialect.SQLite, Invoice, @TypeOf(.{
        .order = .{ .total = .desc, .id = .desc },
        .limit = 5,
    }));
}
