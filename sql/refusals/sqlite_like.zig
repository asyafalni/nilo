//! `like` on SQLite, whose `LIKE` folds ASCII case and cannot be told not to
//! by a statement — the same fact `contains` is refused for there, caught
//! up with (ADR 0263).
//!
//! Until it was, `.like` compiled on SQLite and matched `Ada@` against
//! `ada@`, on that database only; a program that wanted the folding writes
//! `.ilike`, which is the one letter the Refusal names.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

export fn refusal() void {
    _ = sql.statement.select(sql.dialect.SQLite, User, @TypeOf(.{
        .where = .{ .email = .{ .like = @as([]const u8, "%@b.c") } },
    }));
}
