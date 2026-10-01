//! `.not_distinct_from` already takes an optional and treats null as a value,
//! so it is one statement either way and `sql.given` has no term to drop
//! (ADR 149). The message is that one, not a complaint from further down.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    deleted_at: ?i64,
};

export fn refusal() void {
    const found = sql.selectFor(User, @TypeOf(.{
        .where = .{ .deleted_at = .{ .not_distinct_from = sql.given(@as(?i64, null)) } },
    }));
    _ = found;
}
