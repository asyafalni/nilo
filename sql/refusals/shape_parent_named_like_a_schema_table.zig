//! The same clash when the table has a schema: `"app"."orders"` is not
//! `"orders"`, but its name in the `FROM` is, and Postgres refuses *table name
//! specified more than once* for the pair.

const sql = @import("nilo_sql");

const Customer = struct {
    pub const nilo_table = .{ .name = "customers" };
    id: i64,
    name: []const u8,
};

const Order = struct {
    pub const nilo_table = .{
        .name = "app.orders",
        .references = .{ .customer_id = .{ Customer, .id } },
    };
    id: i64,
    customer_id: i64,
    total: i64,
};

const CustomerName = struct {
    pub const nilo_table = Customer;
    name: []const u8,
};

const OrderCard = struct {
    pub const nilo_table = Order;
    id: i64,
    orders: CustomerName,
};

export fn refusal() void {
    _ = sql.selectFor(OrderCard, @TypeOf(.{}));
}
