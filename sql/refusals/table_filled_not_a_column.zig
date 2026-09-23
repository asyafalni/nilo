//! A near miss in `.filled` would otherwise excuse nothing and say nothing.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .filled = .creatd_at };

    id: i64,
    email: []const u8,
    created_at: sql.Timestamp,
};

export fn refusal() void {
    const found = sql.insertFor(User, @TypeOf(.{ .email = "a@b.c" }));
    _ = found;
}
