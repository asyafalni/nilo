//! `db.raw` reads one value per row when its first argument is a column
//! type rather than a Row — `[]const u8`, `i64`, `?bool` — and it reads
//! column one. A `SELECT` list of two into a scalar is one column nobody
//! reads, so it is counted while compiling the way a Row's list is
//! ([ADR 125](../../docs/adr/125-a-row-that-owns-no-table.md)).

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

export fn refusal() void {
    var run = nilo.Run.init(std.heap.page_allocator);
    var db = sql.Db.init(std.heap.page_allocator, "postgres://x/y", .{});
    _ = db.raw([]const u8, &run, "SELECT id, email FROM people", .{}) catch {};
}
