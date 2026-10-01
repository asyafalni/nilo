//! A cursor beside an order that sorts one column down and the next up. A
//! row comparison runs one way, so `(created_at, id) < ($1, $2)` would page
//! the ties in the wrong direction and skip or repeat them (ADR 150).

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
        .order = .{ .created_at = .desc, .id = .asc },
        .after = .{ .created_at = last.created_at, .id = last.id },
        .limit = 20,
    }) catch {};
}
