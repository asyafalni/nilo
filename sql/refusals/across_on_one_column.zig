//! One column is an ordinary condition; `.across` is for a value tested
//! against several, and naming one is almost always a list that lost a line.

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
        .where = .{ .across = .{ .columns = .{.code}, .icontains = "x" } },
    }));
    _ = found;
}
