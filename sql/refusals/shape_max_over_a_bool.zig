//! Postgres has no `max(boolean)` (*function max(boolean) does not exist*), so
//! a Row that reads one compiled and failed on the first request. SQLite would
//! answer it, in an order nobody chose, so it is refused on both.

const sql = @import("nilo_sql");

const Customer = struct {
    pub const nilo_table = .{ .name = "customers" };
    id: i64,
    name: []const u8,
};

const Order = struct {
    pub const nilo_table = .{
        .name = "orders",
        .references = .{ .customer_id = .{ Customer, .id } },
    };
    id: i64,
    customer_id: i64,
    shipped: bool,
};

const CustomerName = struct {
    pub const nilo_table = Customer;
    name: []const u8,
};

const ByCustomer = struct {
    pub const nilo_table = Order;
    pub const nilo_aggregate = .{ .any_shipped = .{ .max = .shipped } };
    customer: CustomerName,
    any_shipped: bool,
};

export fn refusal() void {
    _ = sql.selectFor(ByCustomer, @TypeOf(.{}));
}
