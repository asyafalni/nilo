//! `.across` keeps a row when any column meets the condition, so a negated
//! operator would keep a row whose other column still matches (ADR 172).
//! "None of these columns" is one condition per column.

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
        .where = .{ .across = .{ .columns = .{ .code, .name }, .not_icontains = "test" } },
    }));
    _ = found;
}
