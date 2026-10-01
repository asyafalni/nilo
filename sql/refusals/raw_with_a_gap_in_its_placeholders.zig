//! A raw statement naming `$1` and `$3` and handed three values. The tuple
//! binds by position, so the second value has no placeholder: Postgres
//! refuses the statement at run time, and SQLite drops the value and answers
//! with nothing said. The placeholders are `$1` up to `$n` with no gap, and
//! that is read while compiling
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
    _ = db.raw(Person, &run, "SELECT id, email FROM people WHERE age > $1 AND country = $3", .{ @as(i32, 18), @as(i32, 1), @as(i32, 2) }) catch {};
}
