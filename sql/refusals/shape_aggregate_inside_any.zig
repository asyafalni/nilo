//! A condition on a group is a `HAVING` and one on a row is a `WHERE`, and
//! one alternative of `.any` cannot be half of each.

const sql = @import("nilo_sql");

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

const ByCustomer = struct {
    pub const nilo_table = Order;
    pub const nilo_aggregate = .{ .revenue = .{ .sum = .total } };
    customer: CustomerName,
    revenue: i64,
};

export fn refusal() void {
    _ = sql.selectFor(ByCustomer, @TypeOf(.{ .where = .{ .any = .{ .{ .revenue = .{ .gt = @as(i64, 1) } }, .{ .customer = .{ .name = @as([]const u8, "Acme") } } } } }));
}
