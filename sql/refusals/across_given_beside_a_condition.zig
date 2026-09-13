//! A `sql.given` in an `.across` guards the whole bracket, the way one in an
//! `.exists` guards the whole subquery. A fixed operator beside it would be
//! dropped with it — a `<=` that goes away because the search box was empty.

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
        .where = .{ .across = .{
            .columns = .{ .code, .name },
            .icontains = sql.given(@as(?[]const u8, null)),
            .ne = "retired",
        } },
    }));
    _ = found;
}
