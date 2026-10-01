//! An upsert conflicting on a column the values written do not carry.
//!
//! `ON CONFLICT ("id")` fires when the row being inserted has an `id` that is
//! already there. Here `id` comes from its default, which is new every time, so
//! the statement never conflicts: it inserts a duplicate on every call, or
//! fails on the unique over `email` that was really meant.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
    age: i64,
};

export fn refusal() void {
    const stmt = sql.insertOrUpdateFor(User, @TypeOf(.{ .email = "a@b.c", .age = @as(i64, 3) }), .key);
    _ = stmt;
}
