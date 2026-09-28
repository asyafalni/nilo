//! A cursor on `db.page`, which skips rows by `OFFSET` and counts every
//! match: a count has no page to be relative to after a cursor, and
//! `db.feed` is the call that reads one (ADR 150).

const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Post = struct {
    pub const nilo_table = .{ .name = "posts", .key = .id };
    id: i64,
};

export fn refusal() void {
    var db: sql.Db = undefined;
    var run: nilo.Run = undefined;
    _ = db.page(Post, &run, .{
        .order = .{ .id = .asc },
        .after = .{ .id = @as(i64, 1) },
        .limit = 20,
    }) catch {};
}
