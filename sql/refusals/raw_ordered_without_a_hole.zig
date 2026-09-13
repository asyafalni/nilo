//! `db.rawOrdered` handed a statement with nowhere to write the clause. The
//! statement is the caller's, and appending to somebody else's SQL is the
//! thing `db.raw` exists not to do — so the caller says where, with `{order}`
//! ([ADR 0204](../../docs/adr/0204-an-order-chosen-at-run-time-from-a-closed-set.md)).

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Card = struct {
    pub const nilo_table = .projection;

    id: i64,
    title: []const u8,
};

const Sort = sql.Ordering(Card, .{ .id = .id, .title = "lower(title)" });

export fn refusal() void {
    var run = nilo.Run.init(std.heap.page_allocator);
    var db = sql.Db.init(std.heap.page_allocator, "postgres://x/y", .{});
    _ = db.rawOrdered(Card, &run, "SELECT id, title FROM tickets", .{}, Sort.by(&.{.{ .key = .id }})) catch {};
}
