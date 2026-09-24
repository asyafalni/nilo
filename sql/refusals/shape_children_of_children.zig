//! One level of children is one more statement for every parent at once.
//! A second level would be a statement per level with nowhere to stop, so it
//! is a call of its own (ADR 0295).

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

const Note = struct {
    pub const nilo_table = .{ .name = "notes", .references = .{ .line_id = .{ Line, .id } } };
    id: i64,
    line_id: i64,
    body: []const u8,
};

const NoteBody = struct {
    pub const nilo_table = Note;
    body: []const u8,
};

const LineNotes = struct {
    pub const nilo_table = Line;
    id: i64,
    notes: []const NoteBody,
};

const OrderLines = struct {
    pub const nilo_table = Order;
    id: i64,
    lines: []const LineNotes,
};

export fn refusal() void {
    _ = sql.selectFor(OrderLines, @TypeOf(.{}));
}
