//! One parameter is bound as one type and named on every column, so the
//! columns have to read as one. Text against a number is a cast nobody wrote.

const sql = @import("nilo_sql");

const Sku = struct {
    pub const nilo_table = .{ .name = "skus", .key = .id };

    id: i64,
    code: []const u8,
    name: []const u8,
    trademark: ?[]const u8,
    weight: i32,
};

export fn refusal() void {
    const found = sql.selectFor(Sku, @TypeOf(.{
        .where = .{ .across = .{ .columns = .{ .code, .weight }, .eq = "x" } },
    }));
    _ = found;
}
