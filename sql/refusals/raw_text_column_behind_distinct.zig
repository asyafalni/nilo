//! A text column asked for as itself behind a `DISTINCT` and a comment. Both
//! leave the column bare to the database, so the wire format arrives as it
//! does for `raw_text_column_not_cast`; the check used to read either one as
//! an expression and let it through
//! ([ADR 124](../../docs/adr/124-a-raw-statement-cannot-cast-what-it-did-not-write.md)).

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");

const Invoice = struct {
    pub const nilo_table = .projection;

    total: sql.Decimal,
    id: i64,
};

export fn refusal() void {
    var run = nilo.Run.init(std.heap.page_allocator);
    var db = sql.Db.init(std.heap.page_allocator, "postgres://x/y", .{});
    _ = db.raw(Invoice, &run, "SELECT DISTINCT /* amount */ total, id FROM invoices", .{}) catch {};
}
