//! nilo_sql: one row found by its key and decoded into the Row, on SQLite,
//! which is the read a handler behind `GET /people/{id}` makes most.
//!
//! SQLite rather than Postgres because it needs nothing running, and a row
//! that crosses no socket is the one whose count is the module's own work and
//! the driver's rather than the kernel's. `.in_fiber` runs the statement on
//! the thread that asked, so no hop to another thread lands in the count
//! (ADR 064). The database is shared memory, `file:…?mode=memory&cache=shared`,
//! because the refs this is compared against refuse a bare `:memory:`.
//!
//! The table is made with `db.exec` and written-out DDL rather than
//! `migrate.createMissing`, whose signature changed at v0.5.0 and which
//! v0.2.0 does not have: the same statement on every ref keeps the table out
//! of the comparison. The two calls that also moved are picked while
//! compiling.

const std = @import("std");
const sql = @import("nilo_sql");
const core = @import("nilo_core");
const harness = @import("harness");

pub fn main(init: std.process.Init.Minimal) !void {
    return harness.run(init, Program);
}

const Db = sql.Sqlite(.{ .threading = .in_fiber });

const Person = struct {
    pub const nilo_table = .{ .name = "people", .key = .id };

    id: i64,
    name: core.Str,
    email: core.Str,
    age: i64,
};

const ddl =
    \\CREATE TABLE people (
    \\  id    INTEGER PRIMARY KEY NOT NULL,
    \\  name  TEXT NOT NULL,
    \\  email TEXT NOT NULL,
    \\  age   INTEGER NOT NULL
    \\)
;

/// Rows seeded, and the keys an op cycles through. Every name and email is
/// the same length, so one key costs what the next does and a count that is
/// a multiple of this measures whole cycles.
const rows = 1000;

/// A Scope whose `arena()` is the harness's counted scratch, so what a find
/// allocates is counted call by call, as it would be on a `Ctx`. A `Run` owns
/// an arena of its own, and through it the count would be that arena's
/// chunks. `Str.static` because the lifetime trap is Debug-only and these
/// numbers are ReleaseFast.
const Scope = struct {
    scratch: std.mem.Allocator,

    pub fn arena(self: *Scope) std.mem.Allocator {
        return self.scratch;
    }

    pub fn str(_: *Scope, bytes: []const u8) core.Str {
        return core.Str.static(bytes);
    }
};

const Program = struct {
    gpa: std.mem.Allocator,
    threaded: *std.Io.Threaded,
    db: *Db,

    pub fn init(gpa: std.mem.Allocator) !Program {
        const threaded = try gpa.create(std.Io.Threaded);
        errdefer gpa.destroy(threaded);
        threaded.* = .init(gpa, .{});
        errdefer threaded.deinit();

        const db = try gpa.create(Db);
        errdefer gpa.destroy(db);
        var opts: Db.Opts = .{ .size = 2 };
        // v0.5.0 on, a Db that names no Rows to check says it means it.
        if (@hasField(Db.Opts, "unchecked")) opts.unchecked = true;
        db.* = .init(gpa, "file:nilo-release-sql?mode=memory&cache=shared", opts);
        errdefer db.deinit();
        // v0.2.0 starts on an Io alone; later refs take the Limits too.
        if (@typeInfo(@TypeOf(Db.nilo_start)).@"fn".params.len == 2)
            try db.nilo_start(threaded.io())
        else
            try db.nilo_start(threaded.io(), .off);

        var run = core.Run.init(gpa);
        defer run.deinit();
        _ = try db.exec(&run, ddl, .{});
        for (1..rows + 1) |k| {
            var name: [9]u8 = undefined;
            var email: [21]u8 = undefined;
            _ = try db.insert(Person, &run, .{
                .id = @as(i64, @intCast(k)),
                .name = try std.fmt.bufPrint(&name, "name-{d:0>4}", .{k}),
                .email = try std.fmt.bufPrint(&email, "p{d:0>4}@example.dev", .{k}),
                .age = @as(i64, @intCast(20 + k % 50)),
            });
            run.reset();
        }

        return .{ .gpa = gpa, .threaded = threaded, .db = db };
    }

    pub fn deinit(self: *Program) void {
        self.db.deinit();
        self.gpa.destroy(self.db);
        self.threaded.deinit();
        self.gpa.destroy(self.threaded);
    }

    pub fn op(self: *Program, scratch: std.mem.Allocator, i: usize) !void {
        var scope: Scope = .{ .scratch = scratch };
        const key: i64 = @intCast(i % rows + 1);
        const found = (try self.db.find(Person, &scope, key)) orelse return error.NotFound;
        harness.keep(&found);
    }
};
