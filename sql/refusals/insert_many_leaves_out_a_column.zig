//! The same for a batch: every row of it would be refused.

const sql = @import("nilo_sql");

const Bill = struct {
    pub const nilo_table = .{ .name = "bills", .key = .id };

    id: i64,
    amount: i64,
    reduction: i64,
};

const Line = struct { amount: i64 };

export fn refusal() void {
    const found = sql.insertManyFor(Bill, Line);
    _ = found;
}
