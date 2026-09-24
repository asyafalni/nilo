//! A raw statement naming `$1` and `$2`, handed one value. On Postgres this
//! is a run-time error; on SQLite the placeholder with no value binds NULL
//! and the statement answers wrong with nothing said. The tuple is one
//! value per `$n`, and the count is read while compiling
//! ([ADR 204](../../docs/adr/204-a-raw-placeholder-is-spelled-for-the-dialect.md)).

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Person = struct {
    pub const nilo_table = .{ .name = "people", .key = .id };

    id: i64,
    email: nilo.Str,
};

export fn refusal() void {
    var run = nilo.Run.init(std.heap.page_allocator);
    var db = sql.Db.init(std.heap.page_allocator, "postgres://x/y", .{});
    _ = db.raw(Person, &run, "SELECT id, email FROM people WHERE age > $1 AND country = $2", .{@as(i32, 18)}) catch {};
}
