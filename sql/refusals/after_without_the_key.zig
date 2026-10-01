//! A cursor over a column two rows can share, with the key left out. Both
//! rows stand at the same cursor, and the one the page did not reach is
//! skipped by the next (ADR 150).

const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Post = struct {
    pub const nilo_table = .{ .name = "posts", .key = .id };
    id: i64,
    created_at: sql.Timestamp,
};

export fn refusal() void {
    var db: sql.Db = undefined;
    var run: nilo.Run = undefined;
    const last: Post = undefined;
    _ = db.feed(Post, &run, .{
        .order = .{ .created_at = .desc },
        .after = .{ .created_at = last.created_at },
        .limit = 20,
    }) catch {};
}
