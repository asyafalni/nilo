//! A column an `.across` names is checked against the Row the way every
//! other column in a condition is, near miss and all.

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
        .where = .{ .across = .{ .columns = .{ .code, .trade_mark }, .icontains = "x" } },
    }));
    _ = found;
}
