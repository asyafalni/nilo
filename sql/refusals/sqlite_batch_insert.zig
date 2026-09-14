//! `insertMany` on the SQLite dialect. There is no `unnest` and no array
//! parameter, and the batch form SQLite does have — `VALUES (…), (…)` — grows
//! its statement text with the batch, which is the one thing a statement here
//! may not do (ADR 0039, ADR 0061).
//!
//! This Refusal used to fire from the per-column branch and say SQLite had no
//! column type for `i64`, which was false and sent the reader to
//! `dialect.accepts` to find out. The dialect is judged first now, so the
//! sentence names the database rather than the column.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

const Line = struct { email: []const u8 };

export fn refusal() void {
    _ = sql.statement.insertMany(sql.dialect.SQLite, User, Line);
}
