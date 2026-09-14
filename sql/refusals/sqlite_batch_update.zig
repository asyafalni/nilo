//! `updateMany` on the SQLite dialect, for the reason `sqlite_batch_insert`
//! gives. It is a file of its own because the first line used to call itself
//! "a batch insert" whichever call reached it, and a Refusal that names the
//! wrong verb is one the reader has to second-guess.

const sql = @import("nilo_sql");

const User = struct {
    pub const nilo_table = .{ .name = "users", .key = .id };

    id: i64,
    email: []const u8,
};

const Change = struct { id: i64, email: []const u8 };

export fn refusal() void {
    _ = sql.statement.updateMany(sql.dialect.SQLite, User, Change);
}
