//! A `$1` written into a composed statement as text. A placeholder in a
//! `Composed` is `param(n)`: that is what spells it for the dialect — `$n` on
//! Postgres, `?n` on SQLite — and what `db.composed` counts the values
//! against (ADR 208). One written as text would be spelled for one database
//! and counted by nobody. The person meant `text(" WHERE id = ")` then
//! `param(1)`.

const std = @import("std");
const sql = @import("nilo_sql");

export fn refusal() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var s = sql.Composed.init(arena.allocator(), .dollar);
    s.text("SELECT 1 WHERE id = $1") catch {};
}
