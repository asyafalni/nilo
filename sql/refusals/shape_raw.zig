//! A raw statement fills a Row by position, and a parent's columns are
//! named for their path by a statement nilo wrote.

const sql = @import("nilo_sql");
const nilo = @import("nilo_http");

const Customer = struct {
    pub const nilo_table = .{ .name = "customers" };
    id: i64,
    name: []const u8,
};

const Staff = struct {
    pub const nilo_table = .{ .name = "staff" };
    id: i64,
    full_name: []const u8,
};

const Order = struct {
    pub const nilo_table = .{
        .name = "orders",
        .references = .{
            .customer_id = .{ Customer, .id },
            .owner_id = .{ Staff, .id },
            .approver_id = .{ Staff, .id },
        },
    };
    id: i64,
    customer_id: i64,
    owner_id: i64,
    approver_id: ?i64,
    total: i64,
    discount: ?i64,
};

const Line = struct {
    pub const nilo_table = .{ .name = "lines", .references = .{ .order_id = .{ Order, .id } } };
    id: i64,
    order_id: i64,
    sku: []const u8,
};

const CustomerName = struct {
    pub const nilo_table = Customer;
    name: []const u8,
};

const StaffName = struct {
    pub const nilo_table = Staff;
    full_name: []const u8,
};

const OrderCard = struct {
    pub const nilo_table = Order;
    id: i64,
    customer: CustomerName,
};

fn read(db: *sql.Db, run: *nilo.Run) !void {
    _ = try db.raw(OrderCard, run, "SELECT o.id, c.name FROM orders o JOIN customers c ON c.id = o.customer_id", .{});
}

export fn refusal() void {
    _ = &read;
}
