//! An answer with a version on it, so a client holding that version gets a
//! 304 and no body
//! ([ADR 189](../docs/adr/189-a-version-a-handler-names-is-an-etag.md)).
//!
//! ```zig
//! fn listOrders(c: *nilo.Ctx, db: *Db) !nilo.Versioned([]const Order) {
//!     const version = try db.one(u64, c, "select coalesce(max(revision), 0) from orders", .{});
//!     if (c.clientHas(version)) return .unchanged(version);
//!     return .{ .version = version, .value = try db.all(Order, c, "select * from orders", .{}) };
//! }
//! ```
//!
//! An `ETag` was a thing only a file had: `static.zig` makes one over a held
//! file's bytes or a descriptor's mtime and size, `sendfile.zig` compares it,
//! and a JSON endpoint polled every five seconds sent the whole body every
//! time. The handler is the one thing that knows what the body's version
//! *is* — a revision column, a `max(updated_at)`, a counter it bumps — and
//! it is also the one thing that can skip the work of building the body
//! when the client already holds it. So the version is a field the handler
//! fills in, the check is a method it may call before doing the work, and
//! the tag, the comparison and the 304 are nilo's.
//!
//! **The tag is weak.** `W/"<hex>"`, because a version the handler names
//! says the *representation* is the same and says nothing about the bytes:
//! the same value goes out gzipped to one client and plain to another, and
//! a strong tag would promise byte equality across the two. Weak is also
//! what `If-None-Match` compares by, which is the one comparison this path
//! makes. `If-Range` needs a strong tag and is a file's, not this.
//!
//! **A version is a `u64`.** A revision counts, a timestamp in milliseconds
//! fits, and text — an `updated_at` column kept as text, say — is hashed
//! into one with `std.hash.Wyhash.hash(0, text)`, which is what the guide
//! shows. Not a `[]const u8`, because a tag the handler wrote is a tag nilo
//! would have to check for quotes and control characters per request.
//!
//! **What it costs:** one comparison and a twenty-byte tag written into
//! the caller's frame; the `ETag` header is copied into the arena by
//! `setHeader` as any header is, which is inside the budget a response
//! carrying a header already spends. A 304 sends a head and nothing else.

const std = @import("std");

const headers_mod = @import("headers.zig");
const naming = @import("names.zig");
const static_mod = @import("static.zig");

/// The marker `typed.zig` reads, by name, the way it reads `nilo_bytes`.
pub const marker = "nilo_versioned";

/// An answer with a version on it.
///
/// `value` is the body, or null when the handler found — through
/// `c.clientHas(version)` — that the client already holds this version and
/// built nothing. A null `value` on a request whose client did *not* send
/// the version is a 500 saying so: it is a handler that skipped the work
/// without asking, and answering an empty 200 would be the silent version
/// of that bug.
pub fn Versioned(comptime T: type) type {
    return struct {
        const Self = @This();

        /// What the body is, for the compile-time engine and the document.
        pub const nilo_versioned = T;
        /// What a nilo compile error calls this type (ADR 074).
        pub const nilo_type_name = "nilo.Versioned(" ++ naming.of(T) ++ ")";

        /// The version of the body, as the handler counts it.
        version: u64,
        /// Headers to send with it, on the 200 and the 304 both — a
        /// `Cache-Control` goes here, and RFC 9110 has it on the 304 too.
        headers: headers_mod.Headers = .{},
        /// The body, or null for "the client already holds `version`".
        value: ?T,

        /// The answer for a client that already holds `version`.
        pub fn unchanged(version: u64) Self {
            return .{ .version = version, .value = null };
        }

        /// The same, with headers on it — the `Cache-Control` a 304 wants
        /// to carry as much as the 200 did.
        pub fn unchangedWith(version: u64, headers: headers_mod.Headers) Self {
            return .{ .version = version, .headers = headers, .value = null };
        }
    };
}

/// Whether `T` is a versioned answer, for the compile-time engine.
pub fn isVersioned(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, marker),
        else => false,
    };
}

/// `W/"` + sixteen hex digits + `"`.
pub const max_tag = 3 + 16 + 1;

/// The tag as it goes out in an `ETag` header, written into `buf`.
pub fn tagOf(buf: *[max_tag]u8, version: u64) []const u8 {
    // Cannot overflow: `max_tag` is what the widest `u64` comes to.
    return std.fmt.bufPrint(buf, "W/\"{x}\"", .{version}) catch unreachable;
}

/// The same tag without its `W/`, which is what `static.etagMatches`
/// compares a candidate against once it has stripped the candidate's own.
fn bareTagOf(buf: *[max_tag]u8, version: u64) []const u8 {
    return std.fmt.bufPrint(buf, "\"{x}\"", .{version}) catch unreachable;
}

/// Whether an `If-None-Match` value names `version`. What `Ctx.clientHas`
/// reads its header into, and what `typed.sendResult` asks before sending
/// a body — so a handler that never asks still answers 304 to a client
/// that has it, and one that asks skips the work as well.
///
/// Takes the header's value rather than the `Ctx`, so this file names
/// nothing in the App's core and stays outside it (`http_core` in
/// `build.zig`).
pub fn matches(if_none_match: []const u8, version: u64) bool {
    var buf: [max_tag]u8 = undefined;
    return static_mod.etagMatches(if_none_match, bareTagOf(&buf, version));
}

/// Everything that can be wrong with a versioned return type, said at the
/// route. `T` is the return type with its error union already taken off.
pub fn check(comptime pattern: []const u8, comptime T: type) void {
    comptime {
        // Under a `Response(T)` or a `Status(code, T)`: the status there
        // would be either wrong or the 200 this already answers, and the
        // wrapper's headers are a field this type has of its own.
        if (@typeInfo(T) == .@"struct" and @hasDecl(T, "nilo_response") and isVersioned(T.nilo_response)) @compileError(
            "nilo: the handler for route \"" ++ pattern ++ "\" returns " ++ naming.of(T) ++
                ", and a versioned answer is a 200 or a 304 by itself.\n" ++
                "  Return the `" ++ naming.of(T.nilo_response) ++ "` on its own; its `headers` " ++
                "field carries what the wrapper's would.",
        );
        if (!isVersioned(T)) return;
        const V = T.nilo_versioned;
        if (V == void) @compileError(
            "nilo: the handler for route \"" ++ pattern ++ "\" returns nilo.Versioned(void), " ++
                "and there is no body for a client to hold a version of.\n" ++
                "  A versioned answer is a body the client may already have. A route with " ++
                "nothing to send returns `void`.",
        );
        if (@typeInfo(V) == .optional) @compileError(
            "nilo: the handler for route \"" ++ pattern ++ "\" returns " ++ naming.of(T) ++
                ", and the `?` would have to mean two things: a 404, and a body the client " ++
                "already holds.\n" ++
                "  A thing that is not there has no version. Return " ++
                "`nilo.fail.notFound(\"there is no {f}\", .{c.path()})` for it, and " ++
                "`.unchanged(version)` for the body the client has.",
        );
    }
}

/// A versioned answer under a `Cached` or an `Idempotent`, which
/// `typed.checkAnswer` finds by reading the arguments beside the return
/// type: a kept answer is replayed as it was kept, and a 304 decided once
/// would be replayed to a client that does not hold the version.
pub fn checkNotKept(comptime pattern: []const u8, comptime T: type, comptime under: []const u8) void {
    comptime {
        @compileError(
            "nilo: the handler for route \"" ++ pattern ++ "\" returns " ++ naming.of(T) ++
                " under a `" ++ under ++ "`, and a kept answer is sent again as it was kept.\n" ++
                "  Whether the client holds the version is decided per request, and a kept 304 " ++
                "would go to a client that does not. Drop the `" ++ under ++
                "`, or return the body without the version.",
        );
    }
}

// ---- tests ----

const testing = std.testing;

test "the tag is weak and sixteen hex digits at most" {
    var buf: [max_tag]u8 = undefined;
    try testing.expectEqualStrings("W/\"0\"", tagOf(&buf, 0));
    try testing.expectEqualStrings("W/\"1a\"", tagOf(&buf, 26));
    try testing.expectEqualStrings("W/\"ffffffffffffffff\"", tagOf(&buf, std.math.maxInt(u64)));
    try testing.expectEqual(max_tag, tagOf(&buf, std.math.maxInt(u64)).len);
}

test "a client's If-None-Match matches the tag with or without its W/, and in a list" {
    var buf: [max_tag]u8 = undefined;
    const bare = bareTagOf(&buf, 26);
    try testing.expect(static_mod.etagMatches("W/\"1a\"", bare));
    try testing.expect(static_mod.etagMatches("\"1a\"", bare));
    try testing.expect(static_mod.etagMatches("\"9\", W/\"1a\"", bare));
    try testing.expect(static_mod.etagMatches("*", bare));
    try testing.expect(!static_mod.etagMatches("W/\"1b\"", bare));
    try testing.expect(!static_mod.etagMatches("1a", bare));
}

const App = @import("app.zig").App;
const Ctx = @import("ctx.zig").Ctx;
const typed = @import("typed.zig");
const openapi = @import("openapi.zig");
const nilo_testing = @import("testing.zig");
const Str = @import("nilo_core").Str;

const Order = struct { id: u32, total: i64 };

/// A table with a revision, and a count of how often the body was built —
/// which is the number `c.clientHas` exists to keep down.
const Orders = struct {
    revision: u64 = 26,
    built: u32 = 0,

    fn all(self: *Orders) []const Order {
        self.built += 1;
        return &.{ .{ .id = 1, .total = 1500 }, .{ .id = 2, .total = 700 } };
    }
};

fn listOrders(c: *Ctx, orders: *Orders) !Versioned([]const Order) {
    const cache: headers_mod.Headers = .of(&.{.{ .name = "Cache-Control", .value = "private, max-age=0" }});
    if (c.clientHas(orders.revision)) return .unchangedWith(orders.revision, cache);
    return .{ .version = orders.revision, .headers = cache, .value = orders.all() };
}

/// One that never asks: the 304 is still nilo's to answer.
fn listWithoutAsking(orders: *Orders) Versioned([]const Order) {
    return .{ .version = orders.revision, .value = orders.all() };
}

/// One that skipped the work without asking — the bug the 500 names.
fn skipsWithoutAsking(orders: *Orders) Versioned([]const Order) {
    return .unchanged(orders.revision);
}

fn showNote(c: *Ctx) Versioned([]const u8) {
    _ = c;
    return .{ .version = 7, .value = "a plain note" };
}

fn appServing(app: *App, orders: *Orders) !void {
    try app.provide(orders);
    try app.get("/orders", listOrders);
    try app.get("/orders/unasked", listWithoutAsking);
    try app.get("/orders/skipped", skipsWithoutAsking);
    try app.get("/note", showNote);
}

test "a versioned answer goes out with a weak ETag, and comes back as a 304 when the client holds it" {
    var orders: Orders = .{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try appServing(&app, &orders);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const first = try client.get(&app, "/orders");
    try testing.expectEqual(@as(u16, 200), first.status);
    try testing.expectEqualStrings("W/\"1a\"", first.header("ETag").?);
    try testing.expectEqualStrings("private, max-age=0", first.header("Cache-Control").?);
    try testing.expectEqualStrings("application/json", first.header("Content-Type").?);
    try testing.expectEqualStrings("[{\"id\":1,\"total\":1500},{\"id\":2,\"total\":700}]", first.body);
    try testing.expectEqual(@as(u32, 1), orders.built);

    // The client sends the tag back: a head, no body, no length — and the
    // tag and the handler's headers, because a 304 describes what the
    // client is holding. And the body was never built.
    try client.setHeader("If-None-Match", "W/\"1a\"");
    const again = try client.get(&app, "/orders");
    try testing.expectEqual(@as(u16, 304), again.status);
    try testing.expectEqualStrings("", again.body);
    try testing.expect(again.header("Content-Length") == null);
    try testing.expectEqualStrings("W/\"1a\"", again.header("ETag").?);
    try testing.expectEqualStrings("private, max-age=0", again.header("Cache-Control").?);
    try testing.expectEqual(@as(u32, 1), orders.built);

    // The version moved: the tag the client holds no longer matches, so
    // the body goes out under the new one.
    orders.revision = 27;
    const moved = try client.get(&app, "/orders");
    try testing.expectEqual(@as(u16, 200), moved.status);
    try testing.expectEqualStrings("W/\"1b\"", moved.header("ETag").?);
    try testing.expectEqual(@as(u32, 2), orders.built);
}

test "a handler that never asks still answers 304, and one that skipped without asking is a 500" {
    var orders: Orders = .{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try appServing(&app, &orders);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    // A strong tag, a list, and the weak one all match by the weak
    // comparison `If-None-Match` is read by.
    try client.setHeader("If-None-Match", "\"9\", \"1a\"");
    const unasked = try client.get(&app, "/orders/unasked");
    try testing.expectEqual(@as(u16, 304), unasked.status);
    try testing.expectEqualStrings("", unasked.body);
    // The work was done — nothing asked — which is what asking saves.
    try testing.expectEqual(@as(u32, 1), orders.built);

    // A client with no tag at all is sent the body.
    var fresh = try nilo_testing.Client.init(testing.allocator, .{});
    defer fresh.deinit();
    const whole = try fresh.get(&app, "/orders/unasked");
    try testing.expectEqual(@as(u16, 200), whole.status);
    try testing.expectEqualStrings("W/\"1a\"", whole.header("ETag").?);

    // `.unchanged` to a client that did not send the version is the
    // handler's mistake, said as one.
    const skipped = try fresh.get(&app, "/orders/skipped");
    try testing.expectEqual(@as(u16, 500), skipped.status);
    try testing.expect(std.mem.indexOf(u8, skipped.body, "answered `unchanged`, and the client did not send that version") != null);
}

test "a versioned answer's body is labelled the way the bare value would be" {
    var orders: Orders = .{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try appServing(&app, &orders);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    const note = try client.get(&app, "/note");
    try testing.expectEqual(@as(u16, 200), note.status);
    try testing.expectEqualStrings("text/plain", note.header("Content-Type").?);
    try testing.expectEqualStrings("a plain note", note.body);
    try testing.expectEqualStrings("W/\"7\"", note.header("ETag").?);
}

test "the document describes the ETag on the 200 and the 304 beside it" {
    var op = comptime typed.operation("/orders", listOrders);
    op.method = .GET;
    const ops = [_]openapi.Operation{op};

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try openapi.write(testing.allocator, &out.writer, &ops, .{});
    const document = out.written();

    try testing.expect(std.mem.indexOf(u8, document,
        \\"200":{"description":"the response","content":{"application/json":{"schema":{"type":"array","items":{"$ref":"#/components/schemas/Order"}}}},"headers":{"ETag":{"description":"the version of the body; send it back as If-None-Match to be told when it has not changed","schema":{"type":"string"}}}}
    ) != null);
    try testing.expect(std.mem.indexOf(u8, document,
        \\"304":{"description":"the client already holds this version","headers":{"ETag":
    ) != null);
}
