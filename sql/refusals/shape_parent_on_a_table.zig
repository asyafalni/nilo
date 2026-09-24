//! A parent field on the Row that describes the table. That Row is the
//! table's columns and nothing else, or its DDL would have a column for the
//! parent; a parent belongs on a narrower Row that borrows it (ADR 0295).

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

const Invoice = struct {
    pub const nilo_table = .{ .name = "invoices", .references = .{ .customer_id = .{ Customer, .id } } };
    id: i64,
    customer_id: i64,
    customer: CustomerName,
};

export fn refusal() void {
    _ = sql.selectFor(Invoice, @TypeOf(.{}));
}
