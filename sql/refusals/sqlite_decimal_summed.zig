//! A `sum` over a `sql.Decimal` on SQLite is added in floating point, so
//! `0.1` and `0.2` come back `0.30000000000000004`. The same holds for `avg`,
//! `min` and `max`, which compare the text. Refused (ADR 049, ADR 218).

const sql = @import("nilo_sql");

const Customer = struct {
    pub const nilo_table = .{ .name = "customers" };
    id: i64,
    name: []const u8,
};

const Invoice = struct {
    pub const nilo_table = .{ .name = "invoices", .references = .{ .customer_id = .{ Customer, .id } } };
    id: i64,
    customer_id: i64,
    amount: sql.Decimal,
};

const CustomerName = struct {
    pub const nilo_table = Customer;
    name: []const u8,
};

const Billed = struct {
    pub const nilo_table = Invoice;
    pub const nilo_aggregate = .{ .billed = .{ .sum = .amount } };
    customer: CustomerName,
    billed: sql.Decimal,
};

export fn refusal() void {
    _ = sql.statement.select(sql.dialect.SQLite, Billed, @TypeOf(.{}));
}
