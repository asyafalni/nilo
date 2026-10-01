//! A feed with no ceiling. It reads one row past its limit to say whether
//! there are more, and with no limit there is never more (ADR 150).

const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Post = struct {
    pub const nilo_table = .{ .name = "posts", .key = .id };
    id: i64,
};

export fn refusal() void {
    var db: sql.Db = undefined;
    var run: nilo.Run = undefined;
    _ = db.feed(Post, &run, .{ .order = .{ .id = .asc } }) catch {};
}
