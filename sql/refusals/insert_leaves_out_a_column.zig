//! An insert that leaves out a column nothing fills. A column added to the
//! table in one release and missed by an insert in the next was a
//! `NotNullViolated` on the first run of that insert, in production.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
    age: i32,
    created_at: sql.Timestamp,
};

export fn refusal() void {
    const found = sql.insertFor(User, @TypeOf(.{ .email = "a@b.c" }));
    _ = found;
}
