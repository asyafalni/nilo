//! `.filled` on the integer key a sequence fills: already left out without
//! saying so.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .filled = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    const found = sql.insertFor(User, @TypeOf(.{ .email = "a@b.c" }));
    _ = found;
}
