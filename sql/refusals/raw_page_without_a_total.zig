//! `db.rawPage` over a statement with no `count(*) OVER ()` on the end of
//! its list. The total is read from the column after the Row's last
//! field, and a list exactly the Row's width has no such column
//! ([ADR 0279](../../docs/adr/0279-a-raw-statement-can-carry-its-total.md)).

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Line = struct {
    pub const nilo_table = .projection;

    id: i64,
    email: nilo.Str,
};

export fn refusal() void {
    var run = nilo.Run.init(std.heap.page_allocator);
    var db = sql.Db.init(std.heap.page_allocator, "postgres://x/y", .{});
    _ = db.rawPage(Line, &run, "SELECT id, email FROM people ORDER BY id LIMIT 20", .{}) catch {};
}
