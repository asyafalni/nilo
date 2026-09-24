//! A Row with a parent would lock a row of every table it joins, which is
//! not what somebody holding one order meant.

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

fn hold(db: *sql.Db, run: *nilo.Run) !void {
    var tx = try db.begin(run, .{});
    defer tx.deinit();
    _ = try tx.select(OrderCard, run, .{ .lock = .update });
}

export fn refusal() void {
    _ = &hold;
}
