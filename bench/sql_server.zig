//! Whether a Postgres wait costs a fiber or a thread.
//!
//! `bench/sql.zig` measures one connection sending one statement at a time
//! and finds that **a prepared key lookup is 26 µs, of which 24 µs is the
//! round trip** — the query itself is about two. The client spends 87% of
//! that blocked, one voluntary context switch per query.
//!
//! Which is fine, or fatal, depending on one thing: what the fiber does
//! while it waits. If the read suspends and the loop runs somebody else,
//! 24 µs is latency and the server's capacity is `pool size / 24 µs`. If it
//! blocks the OS thread, capacity is `threads / 24 µs` and the database
//! layer is the bottleneck of every application built on it — which is the
//! failure mode ADR 0014 names and the reason `nilo_start` exists at all.
//!
//! Reading the source says it suspends: pg.zig holds an `Io.net.Stream` and
//! reads through the `Io` it was handed, which under the engine is zio's.
//! **That is an argument, and this is the measurement.** Start it and point
//! the load generator at it:
//!
//! ```
//! zig build -Doptimize=ReleaseFast bench-sql-server
//! DATABASE_URL=postgres://nilo:nilo@localhost:5433/nilo ./zig-out/bin/nilo-bench-sql-server
//! ./bench/bench.sh http://127.0.0.1:8788/people/42
//! ```
//!
//! The number to compare against is 1 ÷ 24 µs ≈ **41,000 requests a second,
//! which is what one blocked thread would cap at.** Anything well past it is
//! the loop doing its job.
//!
//! ## Four routes, because a number needs something standing next to it
//!
//! - `/health` — a constant `[]const u8`, no `Ctx`. The floor.
//! - `/fixed/:id` — the same JSON `/people/:id` answers with, from a
//!   constant. Same `Ctx`, same serialiser, no database.
//! - `/deep/:id` — `/fixed/:id` plus eight kilobytes of stack touched and
//!   nothing else. The control that found what the memory actually was.
//! - `/people/:id` — one `db.find`.
//!
//! `POOL_SIZE` and `PREPARED=0` are the two knobs. Memory per idle
//! connection is measured by opening N keep-alive connections, doing one
//! request on each, and reading `VmRSS` while they sit there
//! ([ADR 0063](../docs/adr/0063-a-handlers-stack-is-per-connection.md)).
//!
//! ## And the arena's route, with its own two controls
//!
//! [HttpArena](https://github.com/MDA2AV/HttpArena)'s `async-db` profile is
//! `GET /async-db?min=10&max=50&limit=N` over a 100,000-row `items` table
//! with no index on `price` — a range scan that stops at `limit`, up to
//! fifty rows, one of them `jsonb`. nilo's entry there answered 66k req/s
//! on a box where the leaders answer 400k, and this is where that is taken
//! apart: the same handler, verbatim, beside two routes that leave
//! something out.
//!
//! - `/async-db` — the arena's handler, as submitted.
//! - `/async-db-notags` — the same rows without the `jsonb` column. What
//!   `sql.Json` costs per row.
//! - `/async-db-ids` — `SELECT id` with the same `WHERE` and `LIMIT`, and
//!   next to nothing decoded. The round trip and the scan.
//!
//! The table is the arena's own seed, which stands up in one command:
//!
//! ```
//! curl -sfL https://raw.githubusercontent.com/MDA2AV/HttpArena/main/data/pgdb-seed.sql -o /tmp/pgdb-seed.sql
//! docker run -d --rm --name nilo-arena-pg -p 127.0.0.1:5440:5432 \
//!     -e POSTGRES_USER=bench -e POSTGRES_PASSWORD=bench -e POSTGRES_DB=benchmark \
//!     -v /tmp/pgdb-seed.sql:/docker-entrypoint-initdb.d/seed.sql:ro postgres:18 -c max_connections=300
//! DATABASE_URL=postgres://bench:bench@127.0.0.1:5440/benchmark ./zig-out/bin/nilo-bench-sql-server
//! ```
//!
//! The three routes answer `{"items":[],"count":0}` when the table is not
//! there, the way the arena's contract says to; `/people/:id` needs
//! `bench/sql.zig`'s table instead, so the two halves of this server want
//! two databases, or one with both tables in it. The readings are in
//! [`bench/result/sql.md`](result/sql.md#12-the-arenas-query-at-one-connection).

const std = @import("std");
const nilo = @import("nilo_http");
const sql = @import("nilo_sql");
const fail = nilo.fail;

pub const std_options = nilo.std_options;
pub const std_options_debug_io = nilo.debug_io;
pub const panic = nilo.panic;

/// The same table `bench/sql.zig` builds, and the same four columns — so
/// the per-query number this server is compared against is the one that
/// bench printed rather than a near relative of it.
const Person = struct {
    pub const nilo_table = .{ .name = "nilo_bench_people", .key = .id };

    id: i64,
    email: nilo.Str,
    age: i32,
    created_at: sql.Timestamp,
};

fn getPerson(db: *sql.Db, c: *nilo.Ctx, id: i64) !Person {
    return try db.find(Person, c, id) orelse fail.notFound("no person {d}", .{id});
}

/// The control. Same server, same router, same response path, no database —
/// so the difference between the two numbers is the whole of what a query
/// costs a *server*, as opposed to what it costs a caller.
fn health() []const u8 {
    return "alive\n";
}

/// The third route, and the control for the control. `/health` returns a
/// constant `[]const u8` and takes no `Ctx`; this returns the same JSON
/// shape `/people/:id` does, from a constant, through the same serialiser —
/// so the difference between *this* and `/people/:id` is the database and
/// nothing else, and the difference between this and `/health` is what a
/// handler that does ordinary work costs (ADR 0063).
fn fixedPerson(c: *nilo.Ctx, id: i64) !Person {
    return .{
        .id = id,
        .email = c.str("p42@example.dev"),
        .age = 62,
        .created_at = .{ .micros = 1_755_374_094_000_000 },
    };
}

/// No database, no allocation, one deep-ish stack frame — the test of what
/// the 7.6 kB between `/fixed/:id` and `/people/:id` actually is. If a
/// handler that only *touches* eight kilobytes of its own stack holds the
/// same extra memory per idle connection, then memory per connection is a
/// function of the deepest stack that connection's fiber ever reached, and
/// not of anything the database did (ADR 0063).
fn deepStack(c: *nilo.Ctx, id: i64) !Person {
    var pad: [8192]u8 = undefined;
    @memset(&pad, @truncate(@as(u64, @bitCast(id))));
    std.mem.doNotOptimizeAway(&pad);
    return fixedPerson(c, id);
}

// ---- the arena's route ----

/// The arena's `items` table, column for column. `tags` is `jsonb`, which
/// `sql.Json` reads per row into the request arena.
const Item = struct {
    pub const nilo_table = .{ .name = "items", .key = .id };

    id: i32,
    name: nilo.Str,
    category: nilo.Str,
    price: i32,
    quantity: i32,
    active: bool,
    tags: sql.Json([]const []const u8),
    rating_score: i32,
    rating_count: i32,
};

const Rating = struct { score: i32, count: i32 };

/// One row as the arena wants it written: the two rating columns nested
/// under `rating`, everything else as it came.
const Listed = struct {
    id: i32,
    name: nilo.Str,
    category: nilo.Str,
    price: i32,
    quantity: i32,
    active: bool,
    tags: []const []const u8,
    rating: Rating,
};

const Listing = struct { items: []const Listed, count: usize };

/// What the arena specifies when Postgres is unreachable or nothing matched.
const nothing = Listing{ .items = &.{}, .count = 0 };

/// The defaults are the arena's; `limit` is clamped to 1–50 rather than
/// refused, because the contract says clamp.
const Range = struct { min: i32 = 10, max: i32 = 50, limit: i32 = 50 };

/// The arena's handler, verbatim from `frameworks/nilo/src/main.zig` there.
fn asyncDb(db: *sql.Db, c: *nilo.Ctx, q: nilo.Query(Range)) !Listing {
    const limit: usize = @intCast(std.math.clamp(q.value.limit, 1, 50));
    const rows = db.select(Item, c, .{
        .where = .{ .price = .{ .gte = q.value.min, .lte = q.value.max } },
        .limit = limit,
    }) catch return nothing;

    const out = try c.arena().alloc(Listed, rows.len);
    for (rows, out) |row, *listed| listed.* = .{
        .id = row.id,
        .name = row.name,
        .category = row.category,
        .price = row.price,
        .quantity = row.quantity,
        .active = row.active,
        .tags = row.tags.value,
        .rating = .{ .score = row.rating_score, .count = row.rating_count },
    };
    return .{ .items = out, .count = out.len };
}

/// The same table without its `jsonb` column, so the `SELECT` leaves it out.
const ItemNoTags = struct {
    pub const nilo_table = .{ .name = "items", .key = .id };

    id: i32,
    name: nilo.Str,
    category: nilo.Str,
    price: i32,
    quantity: i32,
    active: bool,
    rating_score: i32,
    rating_count: i32,
};

/// The first control: the same rows, the same JSON out, no `sql.Json` in.
fn asyncDbNoTags(db: *sql.Db, c: *nilo.Ctx, q: nilo.Query(Range)) !Listing {
    const limit: usize = @intCast(std.math.clamp(q.value.limit, 1, 50));
    const rows = db.select(ItemNoTags, c, .{
        .where = .{ .price = .{ .gte = q.value.min, .lte = q.value.max } },
        .limit = limit,
    }) catch return nothing;

    const out = try c.arena().alloc(Listed, rows.len);
    for (rows, out) |row, *listed| listed.* = .{
        .id = row.id,
        .name = row.name,
        .category = row.category,
        .price = row.price,
        .quantity = row.quantity,
        .active = row.active,
        .tags = &.{},
        .rating = .{ .score = row.rating_score, .count = row.rating_count },
    };
    return .{ .items = out, .count = out.len };
}

/// The second control: the scan and the round trip, with one `i32` a row
/// decoded and nothing written but the count.
fn asyncDbIds(db: *sql.Db, c: *nilo.Ctx, q: nilo.Query(Range)) !Listing {
    const limit: i32 = std.math.clamp(q.value.limit, 1, 50);
    const ids = db.raw(i32, c, "SELECT id FROM items WHERE price >= $1 AND price <= $2 LIMIT $3", .{
        q.value.min, q.value.max, limit,
    }) catch return nothing;
    return .{ .items = &.{}, .count = ids.len };
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;

    const url = init.minimal.environ.getPosix("DATABASE_URL") orelse {
        std.debug.print(
            "bench-sql-server needs a database.\n" ++
                "  DATABASE_URL=postgres://… ./zig-out/bin/nilo-bench-sql-server\n" ++
                "  docker compose -f sql/docker-compose.yml up -d\n" ++
                "  then run bench/sql.zig once to build the table.\n",
            .{},
        );
        return;
    };

    // Sized so the pool is not what runs out first: the question is whether
    // a waiting fiber frees the thread, and a pool of ten would cap the
    // answer at ten in flight whatever the loop does.
    //
    // `POOL_SIZE` overrides it, because "how many connections" turned out to
    // be the one knob users are told to raise and nobody had measured the
    // curve behind it (ADR 0062).
    const size: u16 = if (init.minimal.environ.getPosix("POOL_SIZE")) |text|
        std.fmt.parseInt(u16, text, 10) catch 64
    else
        64;
    // `PREPARED=0` turns the statement cache off, which is how the memory
    // it costs per connection was measured (ADR 0057).
    const prepared = if (init.minimal.environ.getPosix("PREPARED")) |text|
        !std.mem.eql(u8, text, "0")
    else
        true;
    // The whole pool dialled here rather than filled in the background:
    // this is a benchmark, and a pool still filling during the first second
    // of a run is a number about the reconnector.
    var db = sql.Db.init(gpa, url, .{
        .size = size,
        .connect_on_init = size,
        .prepared = prepared,
        // The Rows here are the controls' own; nothing checks them on purpose.
        .unchecked = true,
    });
    defer db.deinit();

    var app = nilo.App.init(gpa);
    defer app.deinit();

    try app.provide(&db);
    try app.get("/people/:id", getPerson);
    try app.get("/health", health);
    try app.get("/fixed/:id", fixedPerson);
    try app.get("/deep/:id", deepStack);
    try app.get("/async-db", asyncDb);
    try app.get("/async-db-notags", asyncDbNoTags);
    try app.get("/async-db-ids", asyncDbIds);

    // No logger, for the reason `bench/main.zig` gives: a line per request
    // would measure the logger.
    try app.listen(.{ .port = 8788 });
}
