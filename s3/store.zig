//! The Store — one endpoint, one region, one set of credentials, and the
//! derived key they turn into
//! ([ADR 060](../docs/adr/060-a-signing-key-changes-once-a-day.md)).
//!
//! A `Bucket` is what a handler holds; this is what every Bucket in the
//! program shares. It owns three things a bucket does not: the connection
//! pool and its gate (borrowed whole from `nilo_fetch`), the credentials, and
//! the signing key derived from them.
//!
//! **nilo owns the cache, the expiry and the derived key. The program owns
//! fetching.** `.static` is one struct literal; `.fetch` is one function, and
//! neither of them writes a lock.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("nilo_fetch");

const sign = @import("sign.zig");

/// What signs a request. `expires_at` is what makes the difference between a
/// program that runs all morning and a program that answers 403 after lunch.
pub const Credentials = struct {
    access_key_id: []const u8,
    secret_access_key: []const u8,
    /// Set by STS, IMDS and IRSA; absent for a long-lived key pair.
    session_token: ?[]const u8 = null,
    /// Unix seconds. Null means they do not expire, which is what a static
    /// key pair means and what nothing temporary ever does.
    expires_at: ?i64 = null,
};

/// Where credentials come from.
///
/// Two entry points to one mechanism, so nothing in the signing path knows
/// which was used. A third source, if one ever earns its place, is a third tag
/// and no new machinery.
pub const Source = union(enum) {
    /// A key pair for the life of the process.
    static: Credentials,
    /// Called once at startup, and again when the ones in hand are within
    /// `refresh_margin_s` of expiring. **Called lazily, on the request that
    /// notices** — there is no background task here, which is the same reason
    /// ADR 054 gave for refusing automatic replica routing.
    ///
    /// The Store copies what it returns into one allocation of its own, so
    /// the strings only have to outlive the call: a literal, a slice of a
    /// buffer the function frees on its way out, or memory it allocated from
    /// `gpa` and freed itself all work, and the Store never frees what it did
    /// not allocate.
    ///
    /// **It runs with no deadline of the Store's**, so a function that does
    /// I/O bounds that I/O itself. One fiber at a time is inside it. While
    /// the credentials in hand have not expired, a failure (an error return)
    /// costs no request anything: it is logged at `warn`, the old key keeps
    /// signing, and the next attempt is `retry_after_s` later. Once they have
    /// expired, the error fails the requests that wait on it (ADR 060).
    fetch: *const fn (gpa: std.mem.Allocator, io: std.Io) anyerror!Credentials,
};

pub const Options = struct {
    /// `https://s3.ap-southeast-1.amazonaws.com`, or `http://127.0.0.1:9000`
    /// for a MinIO in a container. Scheme, host and port; no path.
    ///
    /// **The scheme decides whether payloads are hashed** — `UNSIGNED-PAYLOAD`
    /// over TLS, a real SHA-256 over plaintext. There is nothing to configure
    /// and the reasoning is in ADR 060.
    endpoint: []const u8,
    /// The endpoint a *browser* reaches, when it is not the one this process
    /// dials — a store on a Docker network or a Tailscale address behind a
    /// reverse proxy the outside world sees. Null means the two are the same.
    ///
    /// It is the host in every presigned URL and every POST form, and it is
    /// **signed as that host**, which is why rewriting `url` after the fact
    /// cannot do this job: the host is inside the signature, and a presigned
    /// GET with a rewritten host is a 403 that reads like a signing bug
    /// ([ADR 177](../docs/adr/177-a-presigned-url-names-the-host-the-browser-reaches.md)).
    /// The scheme, host and port, like `endpoint`; no path.
    public_endpoint: ?[]const u8 = null,
    region: []const u8 = "us-east-1",
    credentials: Source,

    /// How many S3 calls may be in flight across the whole process. The
    /// ceiling on live connections, and therefore on memory: each HTTPS one
    /// holds 59,151 bytes of TLS and socket buffers, so this number times that
    /// is what the store may cost.
    max_in_flight: u32 = 32,
    /// How long one call may take, end to end.
    timeout_ms: u32 = 30_000,
    /// How much of an unread body is worth reading to keep a connection.
    max_drain: usize = 64 << 10,
    /// How long before expiry a refresh happens. Five minutes, so that the
    /// request paying for the refresh is never a request that would otherwise
    /// have failed.
    ///
    /// **Capped at half of what the credentials turn out to live**: a set
    /// that lives 200 s is refreshed 100 s before it ends, not on every
    /// request for the whole of its life (ADR 060).
    refresh_margin_s: i64 = 300,
};

/// How long after a failed `.fetch` the next attempt waits, while the
/// credentials in hand are still good. It bounds the load a credential
/// service that is down sees from a busy bucket to one call in this many
/// seconds, and the number of `warn` lines to the same.
pub const retry_after_s: i64 = 5;

pub const OpenError = error{
    /// The endpoint is not `http://host[:port]` or `https://host[:port]`.
    BadEndpoint,
    /// A region longer than a credential scope can carry.
    BadRegion,
    OutOfMemory,
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    client: fetch.Client,
    source: Source,
    options: Options,

    /// `http` or `https`, decided once. What it decides is the payload hash.
    scheme: Scheme,
    /// The authority out of the endpoint — `s3.amazonaws.com`, or
    /// `127.0.0.1:9000`. A Bucket builds its own host from this.
    authority: []const u8,
    /// The same two out of `public_endpoint`, or the dialled pair when there
    /// is none — so a Bucket reads these for a presigned URL and never asks
    /// which case it is in.
    public_scheme: Scheme,
    public_authority: []const u8,
    /// Owned copies, because `Options` is a literal at a call site and the
    /// strings in it may be a `Config`'s that outlive nothing.
    owned: []u8 = &.{},

    /// Everything a refresh replaces, under one lock.
    ///
    /// The lock is a plain shared/exclusive one and there is nothing clever
    /// in here on purpose: a `tryLock` pair is about 30 ns against a network
    /// round trip of 5–50 ms, which is 0.00015%, and ADR 017 puts the bar at
    /// ten per cent. The number is written down so nobody re-derives the
    /// temptation.
    lock: std.Io.RwLock = .init,
    creds: Credentials = .{ .access_key_id = "", .secret_access_key = "" },
    creds_owned: []u8 = &.{},
    /// How long before `expires_at` the credentials in hand are replaced:
    /// `refresh_margin_s`, or less when they live less than twice that.
    margin_s: i64 = 300,
    /// Unix seconds before which a failed fetch is not tried again, while the
    /// credentials in hand are alive. Zero when the last fetch worked.
    retry_at: i64 = 0,
    /// Held by whoever is refreshing, and across its `fetch`, which is I/O.
    /// The shared/exclusive `lock` is never held across one, so the requests
    /// that can still sign with the old key do not wait for it.
    gate: std.Io.Mutex = .init,
    keyed: sign.Keyed = undefined,
    /// The date the key in hand was derived for. A key changes once a day.
    key_date: [8]u8 = @splat(0),

    started: bool = false,

    pub const Scheme = enum { http, https };

    /// Everything that can be settled without an event loop.
    ///
    /// **The credentials are not fetched here**, and that differs from the
    /// sketch in ADR 060 for the reason ADR 037 exists: a Service that dials
    /// cannot dial before `listen()`, because there is no loop to dial on.
    /// `nilo_start` is where the first fetch happens.
    pub fn open(gpa: std.mem.Allocator, options: Options) OpenError!Store {
        const parsed = try parseEndpoint(options.endpoint);
        const public: ?Endpoint = if (options.public_endpoint) |e| try parseEndpoint(e) else null;
        if (options.region.len == 0 or options.region.len > 64) return error.BadRegion;

        // One allocation for every string this holds for the life of the
        // process, sliced up rather than allocated one at a time.
        const total = parsed.authority.len + (if (public) |p| p.authority.len else 0) +
            options.region.len + options.endpoint.len;
        const owned = try gpa.alloc(u8, total);
        errdefer gpa.free(owned);

        var at: usize = 0;
        const authority = copyInto(owned, &at, parsed.authority);
        // The very same slice when there is no public endpoint, so a Bucket
        // can tell the two cases apart by the pointer and build one pair.
        const public_authority = if (public) |p| copyInto(owned, &at, p.authority) else authority;
        const region = copyInto(owned, &at, options.region);
        const endpoint = copyInto(owned, &at, options.endpoint);

        var kept = options;
        kept.region = region;
        kept.endpoint = endpoint;
        // Read once, above; not held past `open`, so a literal at the call
        // site is fine the way `endpoint` is.
        kept.public_endpoint = null;

        return .{
            .gpa = gpa,
            .client = .init(gpa, .{
                .max_in_flight = options.max_in_flight,
                .timeout_ms = options.timeout_ms,
                .max_drain = options.max_drain,
                // Every body this module reads is bounded by the Bucket's own
                // `max_bytes` before a byte is read, so the Fitting's ceiling
                // is not the one doing the work here.
                .max_body = std.math.maxInt(usize),
            }),
            .source = options.credentials,
            .options = kept,
            .margin_s = kept.refresh_margin_s,
            .scheme = parsed.scheme,
            .authority = authority,
            .public_scheme = if (public) |p| p.scheme else parsed.scheme,
            .public_authority = public_authority,
            .owned = owned,
        };
    }

    pub fn deinit(self: *Store) void {
        self.client.deinit();
        if (self.creds_owned.len != 0) self.gpa.free(self.creds_owned);
        if (self.owned.len != 0) self.gpa.free(self.owned);
    }

    /// Finished once the loop exists (ADR 037), and idempotent: two Buckets
    /// over one Store both start it, and a program that also provides the
    /// Store itself starts it a third time.
    pub fn nilo_start(self: *Store, io: std.Io, limits: core.Limits) !void {
        if (self.started) return;
        try self.client.nilo_start(io, limits);
        self.started = true;
        // The first fetch, so that a credential source that is misconfigured
        // fails the server's startup rather than its first request.
        try self.refresh(io, @divFloor(core.nowMillis(), 1000));
    }

    /// What the health route asks
    /// ([ADR 154](../docs/adr/154-a-health-route-asks-the-services.md)).
    /// Started is ready: `nilo_start` fetched the first credentials, so a
    /// Store that reached here can sign. Not a request to the endpoint on
    /// every probe — a balancer asks every second, and a HEAD to somebody
    /// else's bucket at that rate is a bill and a rate limit, not a check.
    pub fn nilo_ready(self: *Store, _: *core.AnyScope) ?[]const u8 {
        if (!self.started) return "not started: `listen()` has not run";
        return null;
    }

    /// The signing key for `now`, and the session token that goes with it.
    ///
    /// The token is copied into `token_buf` while the lock is held. Anything
    /// left pointing into the Store would be a slice a refresh may overwrite
    /// while the request holding it is still being written — one bad signature
    /// per rotation, silently.
    ///
    /// **Credentials that are close to expiring do not stop a request.** One
    /// fiber takes the gate and refreshes; any other that finds the gate taken
    /// signs with the key in hand, which is good until `expires_at`. A fetch
    /// that failed is not retried for `retry_after_s`, and only credentials
    /// past `expires_at` turn its error into a failed request (ADR 060).
    pub fn keyFor(
        self: *Store,
        io: std.Io,
        now_ms: i64,
        token_buf: []u8,
    ) !Signing {
        const now_s = @divFloor(now_ms, 1000);

        // Three rounds at most: a refresh by another fiber with a later clock
        // can leave a key for the next day, and a request is not worth a
        // fourth look at it.
        var round: u8 = 0;
        while (round < 3) : (round += 1) {
            var hold_gate = false;
            {
                try self.lock.lockShared(io);
                defer self.lock.unlockShared(io);
                if (self.usable(now_s)) return self.snapshot(token_buf);
                if (self.keeps(now_s)) {
                    if (now_s < self.retry_at or !self.gate.tryLock())
                        return self.snapshot(token_buf);
                    hold_gate = true;
                }
            }
            if (hold_gate) {
                defer self.gate.unlock(io);
                try self.refreshHeld(io, now_s);
            } else {
                try self.refresh(io, now_s);
            }
        }

        try self.lock.lockShared(io);
        defer self.lock.unlockShared(io);
        return self.snapshot(token_buf);
    }

    /// What one request holds: a key, the token to send beside it, and when
    /// the credentials behind both stop working.
    ///
    /// The expiry is here rather than read off the Store because reading it
    /// there would be a read of shared state outside the lock — and it is
    /// wanted for exactly one thing, which is telling a presigned URL the
    /// truth about its own life.
    pub const Signing = struct {
        keyed: sign.Keyed,
        token: ?[]const u8,
        expires_at: ?i64,
    };

    /// Whether what is in hand can sign a request at `now_s` and is not due
    /// for replacing. Called under the lock, shared or exclusive.
    fn usable(self: *const Store, now_s: i64) bool {
        if (!self.keeps(now_s)) return false;
        if (self.creds.expires_at) |expiry| {
            if (now_s + self.margin_s >= expiry) return false;
        }
        return true;
    }

    /// Whether the key in hand still signs a valid request at `now_s`: it is
    /// for today and the credentials behind it have not expired, margin or no
    /// margin. Called under the lock.
    fn keeps(self: *const Store, now_s: i64) bool {
        if (self.creds.access_key_id.len == 0) return false;

        var stamp: sign.Stamp = .at(now_s);
        if (!std.mem.eql(u8, &self.key_date, stamp.date())) return false;

        if (self.creds.expires_at) |expiry| {
            if (now_s >= expiry) return false;
        }
        return true;
    }

    fn snapshot(self: *const Store, token_buf: []u8) !Signing {
        const token = self.creds.session_token orelse return .{
            .keyed = self.keyed,
            .token = null,
            .expires_at = self.creds.expires_at,
        };
        // A bucket declares this buffer from a comptime option, so being one
        // byte short is a configuration mistake with a name rather than a
        // signature that is quietly missing a header.
        if (token.len > token_buf.len) {
            std.log.warn(
                "nilo_s3: the session token is {d} bytes and the bucket's " ++
                    "`session_token_max` is {d}. Raise it.",
                .{ token.len, token_buf.len },
            );
            return error.SessionTokenTooLong;
        }
        @memcpy(token_buf[0..token.len], token);
        return .{
            .keyed = self.keyed,
            .token = token_buf[0..token.len],
            .expires_at = self.creds.expires_at,
        };
    }

    /// Take the gate, then refresh. For a caller that has no key it can sign
    /// with, which waits its turn behind whoever is already refreshing.
    fn refresh(self: *Store, io: std.Io, now_s: i64) !void {
        try self.gate.lock(io);
        defer self.gate.unlock(io);
        try self.refreshHeld(io, now_s);
    }

    /// Take the credentials again if they need taking, and derive today's key.
    /// The gate is held, so nobody else changes the state this reads; it
    /// re-checks first, because several fibers can decide at once that a
    /// refresh is due and only the first should do it.
    ///
    /// The `fetch` runs under the gate and **not** under `lock`, which is
    /// taken exclusively only to install the result: a source that takes
    /// seconds blocks the fibers with nothing to sign with and nobody else.
    fn refreshHeld(self: *Store, io: std.Io, now_s: i64) !void {
        const due = due: {
            try self.lock.lockShared(io);
            defer self.lock.unlockShared(io);
            if (self.usable(now_s)) return;
            const wanted = switch (self.source) {
                .static => self.creds.access_key_id.len == 0,
                .fetch => self.creds.access_key_id.len == 0 or
                    (if (self.creds.expires_at) |expiry|
                        now_s + self.margin_s >= expiry
                    else
                        false),
            };
            break :due wanted and (!self.keeps(now_s) or now_s >= self.retry_at);
        };

        var fresh: ?Credentials = null;
        var failed = false;
        if (due) switch (self.source) {
            .static => |fixed| fresh = fixed,
            .fetch => |take| fresh = take(self.gpa, io) catch |err| fail: {
                if (err == error.Canceled) return err;
                // Safe to read without the lock: only the gate's holder
                // writes, and that is this call. Asked of the credentials
                // rather than of `keeps`, which is also false the first second
                // after UTC midnight, when the key is merely yesterday's and
                // the derive below makes it today's.
                const alive = self.creds.access_key_id.len != 0 and
                    (if (self.creds.expires_at) |expiry| now_s < expiry else true);
                if (!alive) return err;
                std.log.warn(
                    "nilo_s3: fetching credentials failed ({s}); signing with the ones " ++
                        "in hand, which are good for {d} more seconds, and trying again " ++
                        "in {d}",
                    .{ @errorName(err), (self.creds.expires_at orelse now_s) - now_s, retry_after_s },
                );
                failed = true;
                break :fail null;
            },
        };

        try self.lock.lock(io);
        defer self.lock.unlock(io);
        if (failed) self.retry_at = now_s + retry_after_s;
        if (fresh) |f| try self.hold(f, now_s);

        var stamp: sign.Stamp = .at(now_s);
        try self.deriveLocked(stamp.date());
    }

    /// Copy a set of credentials in, and let go of the ones they replace.
    fn hold(self: *Store, fresh: Credentials, now_s: i64) !void {
        const token = fresh.session_token orelse "";
        const total = fresh.access_key_id.len + fresh.secret_access_key.len + token.len;
        const owned = try self.gpa.alloc(u8, total);
        errdefer self.gpa.free(owned);

        var at: usize = 0;
        const akid = copyInto(owned, &at, fresh.access_key_id);
        const secret = copyInto(owned, &at, fresh.secret_access_key);
        const kept_token = copyInto(owned, &at, token);

        if (self.creds_owned.len != 0) self.gpa.free(self.creds_owned);
        self.creds_owned = owned;
        self.creds = .{
            .access_key_id = akid,
            .secret_access_key = secret,
            .session_token = if (fresh.session_token == null) null else kept_token,
            .expires_at = fresh.expires_at,
        };
        self.retry_at = 0;
        self.margin_s = self.options.refresh_margin_s;
        if (fresh.expires_at) |expiry| {
            self.margin_s = @min(self.margin_s, @divFloor(@max(expiry - now_s, 0), 2));
        }
        // The key in hand was derived from credentials that are gone.
        self.key_date = @splat(0);
    }

    /// The four HMACs, done here so they are not done per request.
    fn deriveLocked(self: *Store, date: *const [8]u8) !void {
        if (self.creds.access_key_id.len > sign.akid_max) return error.AccessKeyIdTooLong;

        self.keyed = .{
            .key = try sign.derive(self.creds.secret_access_key, date, self.options.region),
            .access_key_id = undefined,
            .access_key_id_len = @intCast(self.creds.access_key_id.len),
            .scope = undefined,
            .scope_len = 0,
        };
        @memcpy(
            self.keyed.access_key_id[0..self.creds.access_key_id.len],
            self.creds.access_key_id,
        );
        const s = sign.scope(&self.keyed.scope, date, self.options.region);
        self.keyed.scope_len = @intCast(s.len);
        self.key_date = date.*;
    }

    /// What `x-amz-content-sha256` says, decided by the scheme and nothing
    /// else (ADR 060).
    ///
    /// Over `https://` it is `UNSIGNED-PAYLOAD`: hashing buys integrity TLS
    /// has already provided, at 5 ms per 10 MB with SHA-NI and 20 ms without —
    /// on a fiber, where ADR 013 says a handler must not hold its thread.
    /// Over `http://` it is the only integrity there is, and that path is a
    /// development MinIO rather than production load, so it is paid.
    ///
    /// The same answer for a request that carries no body at all, which needs
    /// no buffer because both answers are constants.
    pub fn payloadNoBody(self: *const Store) []const u8 {
        return if (self.scheme == .https) sign.unsigned_payload else sign.empty_payload;
    }

    /// `hex` is where a real hash is written; it is untouched otherwise.
    pub fn payloadFor(self: *const Store, body: ?[]const u8, hex: *[64]u8) []const u8 {
        if (self.scheme == .https) return sign.unsigned_payload;
        const bytes = body orelse return sign.empty_payload;
        if (bytes.len == 0) return sign.empty_payload;

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        _ = std.fmt.bufPrint(hex, "{x}", .{&digest}) catch unreachable;
        return hex;
    }
};

/// What `open` reads out of an endpoint.
const Endpoint = struct {
    scheme: Store.Scheme,
    authority: []const u8,
};

fn parseEndpoint(text: []const u8) OpenError!Endpoint {
    const scheme: Store.Scheme, const rest = if (std.mem.startsWith(u8, text, "https://"))
        .{ .https, text["https://".len..] }
    else if (std.mem.startsWith(u8, text, "http://"))
        .{ .http, text["http://".len..] }
    else
        return error.BadEndpoint;

    // A trailing `/` is what everybody's `S3_ENDPOINT` has in it, so it is
    // taken off rather than refused. Anything past it is a path, and a path in
    // an endpoint means somebody expects nilo to join two of them.
    const authority = std.mem.trimEnd(u8, rest, "/");
    if (authority.len == 0) return error.BadEndpoint;
    if (std.mem.indexOfScalar(u8, authority, '/') != null) return error.BadEndpoint;
    return .{ .scheme = scheme, .authority = authority };
}

fn copyInto(buf: []u8, at: *usize, text: []const u8) []const u8 {
    @memcpy(buf[at.*..][0..text.len], text);
    defer at.* += text.len;
    return buf[at.*..][0..text.len];
}

// -- tests ---------------------------------------------------------------

const testing = std.testing;

test "an endpoint is a scheme and an authority, and nothing else" {
    const https = try parseEndpoint("https://s3.ap-southeast-1.amazonaws.com");
    try testing.expectEqual(Store.Scheme.https, https.scheme);
    try testing.expectEqualStrings("s3.ap-southeast-1.amazonaws.com", https.authority);

    // A port survives, because a development endpoint is nothing but a port
    // and the host header has to carry it.
    const local = try parseEndpoint("http://127.0.0.1:9000");
    try testing.expectEqual(Store.Scheme.http, local.scheme);
    try testing.expectEqualStrings("127.0.0.1:9000", local.authority);

    // The trailing slash everybody's environment variable has.
    const slashed = try parseEndpoint("http://127.0.0.1:9000/");
    try testing.expectEqualStrings("127.0.0.1:9000", slashed.authority);
}

test "an endpoint that is not one is refused by name" {
    try testing.expectError(error.BadEndpoint, parseEndpoint("s3.amazonaws.com"));
    try testing.expectError(error.BadEndpoint, parseEndpoint("ftp://s3.amazonaws.com"));
    try testing.expectError(error.BadEndpoint, parseEndpoint("https://"));
    // A path, which would mean nilo joining two of them and getting it wrong.
    try testing.expectError(error.BadEndpoint, parseEndpoint("https://example.com/bucket"));
}

test "the payload hash is decided by the scheme and nothing else" {
    var hex: [64]u8 = undefined;

    var https = try Store.open(testing.allocator, .{
        .endpoint = "https://s3.amazonaws.com",
        .credentials = .{ .static = .{ .access_key_id = "A", .secret_access_key = "B" } },
    });
    defer https.deinit();
    try testing.expectEqualStrings(sign.unsigned_payload, https.payloadFor("some bytes", &hex));
    try testing.expectEqualStrings(sign.unsigned_payload, https.payloadFor(null, &hex));

    var plain = try Store.open(testing.allocator, .{
        .endpoint = "http://127.0.0.1:9000",
        .credentials = .{ .static = .{ .access_key_id = "A", .secret_access_key = "B" } },
    });
    defer plain.deinit();
    // Over plaintext the hash is the only integrity there is, so a body gets
    // one — the empty body included, which is a constant rather than work.
    try testing.expectEqualStrings(sign.empty_payload, plain.payloadFor(null, &hex));
    try testing.expectEqualStrings(sign.empty_payload, plain.payloadFor("", &hex));

    // SHA-256 of "Welcome to Amazon S3.", which is AWS's own PUT example and
    // therefore a value that can be checked against something.
    try testing.expectEqualStrings(
        "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072",
        plain.payloadFor("Welcome to Amazon S3.", &hex),
    );
}

test "a store keeps its own copy of the strings it was opened with" {
    var endpoint: [32]u8 = undefined;
    var region: [16]u8 = undefined;
    const e = try std.fmt.bufPrint(&endpoint, "https://s3.example.com", .{});
    const r = try std.fmt.bufPrint(&region, "ap-southeast-1", .{});

    var store = try Store.open(testing.allocator, .{
        .endpoint = e,
        .region = r,
        .credentials = .{ .static = .{ .access_key_id = "A", .secret_access_key = "B" } },
    });
    defer store.deinit();

    // The caller's buffers, overwritten the way a Config's would be if it were
    // read into a stack buffer and reused.
    @memset(&endpoint, 'x');
    @memset(&region, 'x');

    try testing.expectEqualStrings("s3.example.com", store.authority);
    try testing.expectEqualStrings("ap-southeast-1", store.options.region);
}

test "a region that cannot fit a credential scope is refused at open" {
    const long = "x" ** 65;
    try testing.expectError(error.BadRegion, Store.open(testing.allocator, .{
        .endpoint = "https://s3.example.com",
        .region = long,
        .credentials = .{ .static = .{ .access_key_id = "A", .secret_access_key = "B" } },
    }));
}

// -- credential refresh --------------------------------------------------

/// What a `.fetch` function in these tests sees and does. A plain function
/// pointer has no context, so the script is a container of `var`s; the test
/// runner is single-threaded and each test resets it.
const Script = struct {
    var calls: usize = 0;
    var fail: bool = false;
    /// The clock the fetched credentials count their life from.
    var now_s: i64 = 0;
    var life_s: i64 = 3600;

    fn reset(now: i64, life: i64) void {
        calls = 0;
        fail = false;
        now_s = now;
        life_s = life;
    }

    fn take(_: std.mem.Allocator, _: std.Io) anyerror!Credentials {
        calls += 1;
        if (fail) return error.CredentialServiceDown;
        return .{
            // Strings the Store must copy: these die with the call.
            .access_key_id = if (calls % 2 == 1) "AKIDODD" else "AKIDEVEN",
            .secret_access_key = "secret",
            .expires_at = now_s + life_s,
        };
    }
};

fn fetching(gpa: std.mem.Allocator) !Store {
    return Store.open(gpa, .{
        .endpoint = "http://127.0.0.1:9000",
        .credentials = .{ .fetch = Script.take },
    });
}

/// 2023-11-14 22:13:20 UTC: far enough from midnight that an hour of
/// simulated time never changes the day.
const t0: i64 = 1_700_000_000;

fn keyAt(store: *Store, io: std.Io, now_s: i64) !Store.Signing {
    var buf: [0]u8 = undefined;
    return store.keyFor(io, now_s * 1000, &buf);
}

test "credentials near their end are replaced, and the new ones sign" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    Script.reset(t0, 3600);

    var store = try fetching(testing.allocator);
    defer store.deinit();

    const first = try keyAt(&store, io, t0);
    try testing.expectEqualStrings("AKIDODD", first.keyed.akid());
    try testing.expectEqual(@as(usize, 1), Script.calls);

    // Well inside their life: nothing is fetched.
    _ = try keyAt(&store, io, t0 + 1000);
    try testing.expectEqual(@as(usize, 1), Script.calls);

    // Inside the five minutes: replaced, once.
    Script.now_s = t0 + 3400;
    const second = try keyAt(&store, io, t0 + 3400);
    try testing.expectEqualStrings("AKIDEVEN", second.keyed.akid());
    _ = try keyAt(&store, io, t0 + 3401);
    try testing.expectEqual(@as(usize, 2), Script.calls);
}

test "a failed fetch inside the margin fails nobody while the old credentials live" {
    testing.log_level = .err;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    Script.reset(t0, 3600);

    var store = try fetching(testing.allocator);
    defer store.deinit();
    _ = try keyAt(&store, io, t0);

    Script.fail = true;
    // 200 s left, which is what the audit reproduced as a failure.
    const signed = try keyAt(&store, io, t0 + 3400);
    try testing.expectEqualStrings("AKIDODD", signed.keyed.akid());
    try testing.expectEqual(@as(usize, 2), Script.calls);

    // The next requests do not ask the service that is down again...
    _ = try keyAt(&store, io, t0 + 3401);
    _ = try keyAt(&store, io, t0 + 3404);
    try testing.expectEqual(@as(usize, 2), Script.calls);

    // ...until `retry_after_s` has passed, and then they still sign.
    _ = try keyAt(&store, io, t0 + 3400 + retry_after_s);
    try testing.expectEqual(@as(usize, 3), Script.calls);

    // And the service coming back is noticed on the next attempt.
    Script.fail = false;
    Script.now_s = t0 + 3420;
    const back = try keyAt(&store, io, t0 + 3400 + 2 * retry_after_s);
    try testing.expectEqualStrings("AKIDEVEN", back.keyed.akid());
}

test "a failed fetch after the credentials expired fails the request" {
    testing.log_level = .err;
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    Script.reset(t0, 3600);

    var store = try fetching(testing.allocator);
    defer store.deinit();
    _ = try keyAt(&store, io, t0);

    Script.fail = true;
    try testing.expectError(error.CredentialServiceDown, keyAt(&store, io, t0 + 3600));
    // Every request past the expiry asks again: there is nothing to keep.
    try testing.expectError(error.CredentialServiceDown, keyAt(&store, io, t0 + 3601));
    try testing.expectEqual(@as(usize, 3), Script.calls);

    Script.fail = false;
    Script.now_s = t0 + 3602;
    _ = try keyAt(&store, io, t0 + 3602);
}

test "credentials that live less than the margin are not fetched on every request" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    Script.reset(t0, 100);

    var store = try fetching(testing.allocator);
    defer store.deinit();

    // Fifty seconds of requests against credentials that live a hundred,
    // under a margin of three hundred.
    var at: i64 = t0;
    while (at < t0 + 50) : (at += 5) _ = try keyAt(&store, io, at);
    try testing.expectEqual(@as(usize, 1), Script.calls);

    // The margin became half their life, so they are replaced at 50 s.
    Script.now_s = t0 + 50;
    _ = try keyAt(&store, io, t0 + 50);
    try testing.expectEqual(@as(usize, 2), Script.calls);
}

test "a fetch that returns strings it does not own is not freed or kept" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    Script.reset(t0, 3600);

    var store = try fetching(testing.allocator);
    defer store.deinit();
    _ = try keyAt(&store, io, t0);
    Script.now_s = t0 + 3400;
    _ = try keyAt(&store, io, t0 + 3400);
    // `testing.allocator` reports a leak or a double free at `deinit`; the
    // literals `Script.take` returns would be a crash if the Store freed them.
}
