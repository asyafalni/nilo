//! Response compression: a body gzipped per request, on a compressor
//! borrowed from a pool sized to the thread count (ADR 0287).
//!
//! ```zig
//! try app.compress(.{});                                   // gzip, bodies of 1 KB and up
//! try app.compress(.{ .level = .best, .min_bytes = 512 });
//! ```
//!
//! Once it is on, every `send` (and so every `sendJson`, `sendText` and
//! typed handler returning a value) gzips a body that is text, is at least
//! `min_bytes` long, and is going to a client whose `Accept-Encoding` says
//! gzip is welcome. The answer carries `Content-Encoding: gzip` and `Vary:
//! Accept-Encoding`, and its `Content-Length` is the compressed size. A
//! client that said nothing, or said `gzip;q=0`, gets the body as it is and
//! no `Content-Encoding` at all. A static file is not this: it was gzipped
//! once when the App was built (ADR 0010). A stream and an event stream are
//! not this either, and deliberately; the ADR says why.
//!
//! **Where the compressor lives is the whole design, and three places were
//! rejected before this one.** A deflate compressor is `~224 KB` of lookup
//! table and token buffer plus a 64 KB window. One per *connection* would
//! multiply the 4,669 bytes an idle connection holds by sixty. One per
//! *request*, allocated, breaks the budget of one allocation a request
//! (ADR 0018). And one on the *handler's stack*, the obvious shape and
//! the one `Compress.init` writes, is the worst of the three: the standard
//! library builds its token buffer as a 96 KB temporary before copying it
//! into place, and a fiber keeps its stack at the high-water mark it ever
//! reached, for the life of the connection (ADR 0063). Measured from the
//! assembly: **99,048 bytes of stack** for one call to `Compress.init`,
//! which on four thousand keep-alive connections is four hundred megabytes
//! of resident memory for a feature that was meant to save bandwidth.
//!
//! So the compressors sit in a pool on the heap, one per executor thread,
//! taken at `resolveChains` and never touched by a fiber's stack. A request
//! borrows one, gzips its whole body into the request arena, hands the
//! compressor back, and *then* writes the answer. **The borrow spans no
//! wait**: nothing between taking a slot and returning it can park the
//! fiber, so with one slot per thread the pool is never empty on a server.
//! The fallback for an empty pool exists for an App driven with no
//! server under it, and it is the uncompressed body, not an error.
//!
//! Handing a compressor back does not make it reusable: `finish` puts its
//! writer into the failing state, and the standard library's only way out
//! is `init`, which is the 99 KB temporary above. `reset` below does what
//! `init` does, field by field, into memory that is already there:
//! 40 bytes of stack, measured the same way. It depends on the fields
//! `std.compress.flate.Compress` has in the Zig this toolkit is pinned to,
//! and `test "a compressor reset in place produces what a fresh one does"`
//! holds it there byte for byte.

const std = @import("std");
const flate = std.compress.flate;
const http1 = @import("http1.zig");

pub const Options = struct {
    /// Bodies shorter than this go out as they are. Compressing a hundred
    /// bytes makes them longer, and the round trip is what a small answer
    /// costs; one kilobyte is where gzip starts paying for its header.
    min_bytes: usize = 1024,
    /// How hard to look for a match. `.default` is zlib's level 6 and what
    /// nginx and Go ship; `.fastest` is level 1 and roughly twice as quick
    /// for bodies a fifth larger; `.best` is level 9 and rarely worth its
    /// time on a body under a megabyte.
    level: Level = .default,
};

pub const Level = enum {
    fastest,
    default,
    best,

    fn flateOptions(self: Level) flate.Compress.Options {
        return switch (self) {
            .fastest => .fastest,
            .default => .default,
            .best => .best,
        };
    }
};

/// The compressors, one per executor thread, and which of them are free.
pub const Pool = struct {
    slots: []Slot,
    /// One bit per slot, set while it is free. Words rather than a lock: a
    /// borrow is one `cmpxchg` on the word its slot is in, and nothing
    /// waits.
    free: []std.atomic.Value(u64),
    options: Options,

    /// One compressor and its window. `~288 KB`, on the heap, never on a
    /// stack.
    pub const Slot = struct {
        state: flate.Compress,
        window: [flate.max_window_len]u8,
        /// The vtable `Compress.init` gave the writer, kept because `finish`
        /// replaces it with the failing one and `reset` has to put it back.
        vtable: *const std.Io.Writer.VTable,
    };

    /// `count` compressors. Each one is initialised once here, through the
    /// standard library's own `init`, on the thread that is building the
    /// App, whose stack is the process's and not a connection's.
    pub fn init(gpa: std.mem.Allocator, count: usize, options: Options) !Pool {
        const slots = try gpa.alloc(Slot, count);
        errdefer gpa.free(slots);
        const words = (count + 63) / 64;
        const free = try gpa.alloc(std.atomic.Value(u64), words);
        errdefer gpa.free(free);

        // `init` writes the gzip header into its output and asserts there is
        // room for it. This output is thrown away.
        var scratch: [16]u8 = undefined;
        for (slots) |*slot| {
            var discard: std.Io.Writer = .fixed(&scratch);
            slot.state = try flate.Compress.init(&discard, &slot.window, .gzip, options.level.flateOptions());
            slot.vtable = slot.state.writer.vtable;
        }
        for (free, 0..) |*word, w| {
            const in_this_word = @min(64, count - w * 64);
            word.* = .init(if (in_this_word == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(in_this_word)) - 1);
        }
        return .{
            .slots = slots,
            .free = free,
            .options = options,
        };
    }

    pub fn deinit(self: *Pool, gpa: std.mem.Allocator) void {
        gpa.free(self.free);
        gpa.free(self.slots);
        self.* = undefined;
    }

    pub fn len(self: *const Pool) usize {
        return self.slots.len;
    }

    /// A free compressor, or null when every one is out. Never waits.
    fn borrow(self: *const Pool) ?*Slot {
        for (self.free, 0..) |*word, w| {
            var bits = word.load(.acquire);
            while (bits != 0) {
                const bit: u6 = @intCast(@ctz(bits));
                const taken = bits & ~(@as(u64, 1) << bit);
                if (word.cmpxchgWeak(bits, taken, .acquire, .monotonic)) |now| {
                    bits = now;
                    continue;
                }
                return &self.slots[w * 64 + bit];
            }
        }
        return null;
    }

    fn giveBack(self: *const Pool, slot: *Slot) void {
        const i = (@intFromPtr(slot) - @intFromPtr(self.slots.ptr)) / @sizeOf(Slot);
        _ = self.free[i / 64].fetchOr(@as(u64, 1) << @intCast(i % 64), .release);
    }

    /// Whether an answer of this shape is one the pool would compress at
    /// all, before anybody reads what the client said: long enough, a
    /// status that carries a body, a type that is text. The cheap half of
    /// the decision, in the order cheapest first; `Ctx.send` asks it before
    /// reading `Accept-Encoding` off the head.
    pub fn eligible(self: *const Pool, status: u16, content_type: []const u8, body_len: usize) bool {
        if (body_len < self.options.min_bytes) return false;
        if (http1.bodyless(status)) return false;
        return compressible(content_type);
    }

    /// Gzip `body` into `arena`, or null when it is not worth it: no
    /// compressor free, or the result no smaller than what went in.
    ///
    /// Half the input plus a little is where text lands, so the output is
    /// usually one arena allocation that is never grown; when it is grown
    /// the arena resizes its last allocation in place.
    pub fn gzip(self: *const Pool, arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
        const slot = self.borrow() orelse return null;
        defer self.giveBack(slot);

        var out = std.Io.Writer.Allocating.initCapacity(arena, body.len / 2 + 64) catch return null;
        reset(slot, &out.writer, self.options.level.flateOptions()) catch return null;
        slot.state.writer.writeAll(body) catch return null;
        slot.state.finish() catch return null;

        const squeezed = out.written();
        if (squeezed.len >= body.len) return null;
        return squeezed;
    }
};

/// What `flate.Compress.init` does, into a compressor that is already there.
///
/// Field for field the same as `init` in the pinned standard library, with
/// one difference: the writer's vtable is the one `init` gave this slot
/// rather than a fresh literal, because the functions in it are private to
/// `Compress.zig`. `chain` is left as it is, as `init` leaves it undefined.
fn reset(slot: *Pool.Slot, output: *std.Io.Writer, opts: flate.Compress.Options) std.Io.Writer.Error!void {
    const c = &slot.state;
    try output.writeAll(flate.Container.gzip.header());
    c.writer = .{ .buffer = &slot.window, .vtable = slot.vtable, .end = 0 };
    c.history_len = 0;
    c.history_end_unhashed = false;
    c.bit_writer.output = output;
    c.bit_writer.buffered = 0;
    c.bit_writer.buffered_n = 0;
    c.buffered_tokens.pos = 0;
    c.buffered_tokens.n = 0;
    @memset(&c.buffered_tokens.lit_freqs, 0);
    @memset(&c.buffered_tokens.dist_freqs, 0);
    @memset(&c.lookup.head, .{ .value = std.math.maxInt(u15), .is_null = true });
    c.lookup.chain_pos = std.math.maxInt(u15);
    c.container = .gzip;
    c.opts = opts;
    c.hasher = .init(.gzip);
}

/// Whether an `Accept-Encoding` header says gzip is welcome.
///
/// Not `indexOf("gzip")`, because `gzip;q=0` contains the word and means the
/// exact opposite: it is how a client that cannot decompress says so, and
/// answering it with a gzipped body is a broken page rather than a slow one.
/// `*` is honoured too, with an explicit `gzip` entry outranking it either
/// way, which is what RFC 9110 §12.5.3 says to do.
pub fn acceptsGzip(header: ?[]const u8) bool {
    const value = header orelse return false;

    var star: ?bool = null;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        if (entry.len == 0) continue;

        const semi = std.mem.indexOfScalar(u8, entry, ';');
        const name = std.mem.trimEnd(u8, entry[0 .. semi orelse entry.len], " \t");
        const wanted = if (semi) |i| !isQualityZero(entry[i + 1 ..]) else true;

        if (std.ascii.eqlIgnoreCase(name, "gzip")) return wanted;
        if (std.mem.eql(u8, name, "*")) star = wanted;
    }
    return star orelse false;
}

/// Whether the parameters after a `;` say `q=0`: `q=0`, `q=0.0`, `q=0.000`.
/// Anything else, including a malformed one, is read as "wanted": the cost
/// of being wrong that way is a header the client asked for by listing the
/// encoding at all.
fn isQualityZero(params: []const u8) bool {
    var it = std.mem.splitScalar(u8, params, ';');
    while (it.next()) |raw| {
        const param = std.mem.trim(u8, raw, " \t");
        if (param.len < 2) continue;
        if (param[0] != 'q' and param[0] != 'Q') continue;
        const eq = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        if (std.mem.trim(u8, param[1..eq], " \t").len != 0) continue;

        return isZero(std.mem.trim(u8, param[eq + 1 ..], " \t"));
    }
    return false;
}

/// A `qvalue` that is zero: `0`, or `0.` followed by nothing but zeros
/// (RFC 9110 §12.4.2). Read by hand rather than through `parseFloat`,
/// which is 7 KB of machine code to answer a yes-or-no about three digits.
fn isZero(q: []const u8) bool {
    if (q.len == 0 or q[0] != '0') return false;
    if (q.len == 1) return true;
    if (q[1] != '.') return false;
    for (q[2..]) |digit| if (digit != '0') return false;
    return true;
}

/// Whether a body of this type is worth gzipping.
///
/// An allowlist rather than a blocklist. Getting it wrong in the permissive
/// direction means spending the work on a JPEG to save nothing; in the
/// strict direction it means a CSS file goes out uncompressed, which is
/// merely the behaviour of every previous version. So the list names what
/// is known to be text.
pub fn compressible(content_type: []const u8) bool {
    // `text/anything` is text, including the ones nobody has thought of.
    if (std.mem.startsWith(u8, content_type, "text/")) return true;

    // A structured type ending in `+json` or `+xml` (`image/svg+xml`,
    // `application/manifest+json`) is text however it starts.
    const base = content_type[0 .. std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len];
    const trimmed = std.mem.trimEnd(u8, base, " ");
    if (std.mem.endsWith(u8, trimmed, "+json")) return true;
    if (std.mem.endsWith(u8, trimmed, "+xml")) return true;

    for ([_][]const u8{
        "application/json",
        "application/javascript",
        "application/xml",
        "application/wasm",
        "application/x-ndjson",
        "image/x-icon",
        "font/ttf",
        "font/otf",
    }) |known| {
        if (std.mem.eql(u8, trimmed, known)) return true;
    }
    return false;
}

// ---- tests ----

const testing = std.testing;

/// The bytes a client would read: `gzipped` inflated.
fn inflated(gpa: std.mem.Allocator, gzipped: []const u8) ![]u8 {
    var in = std.Io.Reader.fixed(gzipped);
    var window: [flate.max_window_len]u8 = undefined;
    var inflate: flate.Decompress = .init(&in, .gzip, &window);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    _ = try inflate.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

/// A JSON body comfortably over the default threshold, and repetitive enough
/// that gzip halves it several times over.
const long_json = "{\"items\":[" ++ ("{\"id\":1,\"name\":\"Alpha Widget\",\"category\":\"electronics\",\"price\":328,\"quantity\":15,\"active\":true}," ** 40) ++ "{}],\"count\":40}";

test "a compressor reset in place produces what a fresh one does" {
    const gpa = testing.allocator;
    const body = long_json;

    var pool = try Pool.init(gpa, 1, .{});
    defer pool.deinit(gpa);

    // Through the standard library's own `init`, as the reference. With
    // room to start in: `init` asserts its output has somewhere to write.
    var fresh_out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    defer fresh_out.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var fresh = try flate.Compress.init(&fresh_out.writer, window, .gzip, .default);
    try fresh.writer.writeAll(body);
    try fresh.finish();

    // Through `reset`, twice, so the second use sees whatever the first left
    // behind, which is what every request after the first does.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const once = pool.gzip(arena.allocator(), body).?;
    const twice = pool.gzip(arena.allocator(), body).?;

    try testing.expectEqualSlices(u8, fresh_out.written(), once);
    try testing.expectEqualSlices(u8, fresh_out.written(), twice);

    const back = try inflated(gpa, twice);
    defer gpa.free(back);
    try testing.expectEqualStrings(body, back);
}

test "the pool hands out every slot once and takes each back" {
    const gpa = testing.allocator;
    var pool = try Pool.init(gpa, 3, .{});
    defer pool.deinit(gpa);

    const a = pool.borrow().?;
    const b = pool.borrow().?;
    const c = pool.borrow().?;
    try testing.expect(a != b and b != c and a != c);
    try testing.expect(pool.borrow() == null);

    pool.giveBack(b);
    try testing.expect(pool.borrow().? == b);
    try testing.expect(pool.borrow() == null);

    pool.giveBack(a);
    pool.giveBack(b);
    pool.giveBack(c);
    var taken: usize = 0;
    while (pool.borrow()) |_| taken += 1;
    try testing.expectEqual(@as(usize, 3), taken);
}

test "a pool with every compressor out sends the body as it is" {
    const gpa = testing.allocator;
    var pool = try Pool.init(gpa, 1, .{});
    defer pool.deinit(gpa);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const held = pool.borrow().?;
    try testing.expect(pool.gzip(arena.allocator(), long_json) == null);
    pool.giveBack(held);
    try testing.expect(pool.gzip(arena.allocator(), long_json) != null);
}

test "a body that does not shrink goes out as it is" {
    const gpa = testing.allocator;
    var pool = try Pool.init(gpa, 1, .{});
    defer pool.deinit(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Random bytes have nothing for deflate to find, and the gzip framing
    // makes the result longer than the input.
    var noise: [2048]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(&noise);
    try testing.expect(pool.gzip(arena.allocator(), &noise) == null);
}

// Below the first test block on purpose: a file outside the App's core may
// name it only from its tests (see `http_core` in build.zig).
const App = @import("app.zig").App;
const Ctx = @import("ctx.zig").Ctx;
const nilo_testing = @import("testing.zig");

fn sendLongJson(c: *Ctx) anyerror!void {
    try c.send(200, "application/json", long_json);
}

fn sendShortJson(c: *Ctx) anyerror!void {
    try c.send(200, "application/json", "{\"ok\":true}");
}

fn sendLongPng(c: *Ctx) anyerror!void {
    try c.send(200, "image/png", long_json);
}

fn sendOwnGzip(c: *Ctx) anyerror!void {
    try c.setStaticHeader("Content-Encoding", "gzip");
    try c.send(200, "application/json", long_json);
}

test "a JSON answer over the threshold goes out gzipped to a client that takes it" {
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.compress(.{});
    try app.get("/items", sendLongJson);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();

    const answer = try client.send(&app, "GET /items HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip, br\r\n\r\n");
    try testing.expectEqual(@as(u16, 200), answer.status);
    try testing.expectEqualStrings("gzip", answer.header("Content-Encoding").?);
    try testing.expectEqualStrings("Accept-Encoding", answer.header("Vary").?);
    try testing.expectEqualStrings("application/json", answer.header("Content-Type").?);
    try testing.expect(answer.body.len < long_json.len / 4);

    // The length on the wire is the compressed one, and what it frames
    // inflates to exactly what the handler sent.
    var length_buf: [16]u8 = undefined;
    const length = try std.fmt.bufPrint(&length_buf, "{d}", .{answer.body.len});
    try testing.expectEqualStrings(length, answer.header("Content-Length").?);
    const back = try inflated(gpa, answer.body);
    defer gpa.free(back);
    try testing.expectEqualStrings(long_json, back);
}

test "a client that did not ask for gzip gets the body as it is and no Content-Encoding" {
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.compress(.{});
    try app.get("/items", sendLongJson);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();

    // No header at all: what wrk sends, and what the benchmark arena's
    // rule for this profile names: "the server must not set
    // Content-Encoding".
    const silent = try client.get(&app, "/items");
    try testing.expectEqual(@as(u16, 200), silent.status);
    try testing.expect(silent.header("Content-Encoding") == null);
    try testing.expectEqualStrings(long_json, silent.body);
    // Still `Vary`: this answer would have differed for a client that asked.
    try testing.expectEqualStrings("Accept-Encoding", silent.header("Vary").?);

    // Said no in the one way that contains the word.
    const refused = try client.send(&app, "GET /items HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip;q=0, br\r\n\r\n");
    try testing.expect(refused.header("Content-Encoding") == null);
    try testing.expectEqualStrings(long_json, refused.body);
}

test "a body under min_bytes, a type that is not text, and a body already encoded are left alone" {
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.compress(.{});
    try app.get("/short", sendShortJson);
    try app.get("/png", sendLongPng);
    try app.get("/own", sendOwnGzip);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();
    try client.setHeader("Accept-Encoding", "gzip");

    const short = try client.get(&app, "/short");
    try testing.expect(short.header("Content-Encoding") == null);
    // Under the threshold there is one representation, so nothing varies.
    try testing.expect(short.header("Vary") == null);
    try testing.expectEqualStrings("{\"ok\":true}", short.body);

    const png = try client.get(&app, "/png");
    try testing.expect(png.header("Content-Encoding") == null);
    try testing.expect(png.header("Vary") == null);
    try testing.expectEqualStrings(long_json, png.body);

    // The handler's own header stands, and the bytes are the handler's.
    const own = try client.get(&app, "/own");
    try testing.expectEqualStrings("gzip", own.header("Content-Encoding").?);
    try testing.expectEqualStrings(long_json, own.body);
}

test "the threshold and the level are the caller's" {
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.compress(.{ .min_bytes = 8, .level = .fastest });
    try app.get("/short", sendShortJson);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();
    try client.setHeader("Accept-Encoding", "gzip");

    // Eleven bytes of JSON do not shrink under gzip's own 18 bytes of
    // framing, so even asked for at 8 it goes out as it is, with `Vary`
    // because it was eligible.
    const short = try client.get(&app, "/short");
    try testing.expect(short.header("Content-Encoding") == null);
    try testing.expectEqualStrings("Accept-Encoding", short.header("Vary").?);
    try testing.expectEqualStrings("{\"ok\":true}", short.body);
}

test "a HEAD carries the length the GET would have" {
    const gpa = testing.allocator;
    var app = App.init(gpa);
    defer app.deinit();
    try app.compress(.{});
    try app.get("/items", sendLongJson);

    var client = try nilo_testing.Client.init(gpa, .{});
    defer client.deinit();

    const got = try client.send(&app, "GET /items HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\n\r\n");
    const asked = try client.send(&app, "HEAD /items HTTP/1.1\r\nHost: t\r\nAccept-Encoding: gzip\r\n\r\n");
    try testing.expectEqual(@as(u16, 200), asked.status);
    try testing.expectEqualStrings("gzip", asked.header("Content-Encoding").?);
    try testing.expectEqualStrings(got.header("Content-Length").?, asked.header("Content-Length").?);
    try testing.expectEqualStrings("", asked.body);
}

test "compression is switched on once" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.compress(.{});
    try testing.expectError(error.CompressionAlreadyEnabled, app.compress(.{ .level = .best }));
}

test "Accept-Encoding is read, not searched for the word gzip" {
    // The plain cases.
    try testing.expect(acceptsGzip("gzip"));
    try testing.expect(acceptsGzip("gzip, deflate, br"));
    try testing.expect(acceptsGzip("deflate, gzip"));
    try testing.expect(acceptsGzip("GZIP"));
    try testing.expect(acceptsGzip("gzip;q=1.0"));
    try testing.expect(acceptsGzip("gzip ; q=0.5"));

    // `q=0` is how a client says it cannot, and it contains the word.
    try testing.expect(!acceptsGzip("gzip;q=0"));
    try testing.expect(!acceptsGzip("gzip;q=0.0"));
    try testing.expect(!acceptsGzip("gzip;q=0.000"));
    try testing.expect(!acceptsGzip("gzip;q=0."));
    try testing.expect(!acceptsGzip("deflate, gzip;q=0"));

    // Not zero, including the ones that start with one.
    try testing.expect(acceptsGzip("gzip;q=0.001"));
    try testing.expect(acceptsGzip("gzip;q=0.5"));
    try testing.expect(acceptsGzip("gzip;q=1"));
    try testing.expect(acceptsGzip("gzip;q=00"));
    try testing.expect(acceptsGzip("gzip;q="));
    try testing.expect(acceptsGzip("gzip;q=zero"));

    // A wildcard, and a named entry outranking it either way.
    try testing.expect(acceptsGzip("*"));
    try testing.expect(!acceptsGzip("*;q=0"));
    try testing.expect(!acceptsGzip("*, gzip;q=0"));
    try testing.expect(acceptsGzip("*;q=0, gzip"));

    // Nothing, and things that are not gzip.
    try testing.expect(!acceptsGzip(null));
    try testing.expect(!acceptsGzip(""));
    try testing.expect(!acceptsGzip("identity"));
    try testing.expect(!acceptsGzip("deflate, br"));

    // Names that contain it without being it.
    try testing.expect(!acceptsGzip("gzip-x"));
    try testing.expect(!acceptsGzip("x-gzip"));
}

test "the types worth gzipping are named, and the rest are not" {
    try testing.expect(compressible("text/html"));
    try testing.expect(compressible("text/plain; charset=utf-8"));
    try testing.expect(compressible("application/json"));
    try testing.expect(compressible("application/json; charset=utf-8"));
    try testing.expect(compressible("image/svg+xml"));
    try testing.expect(compressible("application/manifest+json"));
    try testing.expect(compressible("application/javascript"));
    try testing.expect(!compressible("image/png"));
    try testing.expect(!compressible("application/octet-stream"));
    try testing.expect(!compressible("font/woff2"));
    try testing.expect(!compressible("video/mp4"));
}
