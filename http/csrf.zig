//! The CSRF middleware: a request that changes something is taken only from a
//! page this server serves (ADR 224).
//!
//! ```zig
//! try app.use(nilo.csrf.sameOrigin);                    // the page and the API are one server
//! try app.use(nilo.csrf.with(.{
//!     .origins = &.{"https://app.example.com"},         // a front end served from elsewhere
//! }));
//! ```
//!
//! **The browser already says where a request came from, so there is no
//! token.** A token in the session, a hidden field in every form and a compare
//! in a middleware is what CSRF protection was when the browser said nothing.
//! It now sends `Sec-Fetch-Site` on every request (every engine since 2023)
//! and `Origin` on every `POST`, `PUT`, `PATCH` and `DELETE` (since 2020), and
//! a page cannot set either. Reading them costs no state, no entropy, nothing
//! in the session and nothing in the form, which is what a server whose
//! session is sealed into the cookie and which renders no templates can
//! afford (ADR 033, ADR 027). It is the same check Go's
//! `http.CrossOriginProtection` makes.
//!
//! The rule, in the order it is asked:
//!
//! 1. `GET`, `HEAD` and `OPTIONS` pass. They are how a link, an image and a
//!    preflight arrive, and refusing a cross-site `GET` refuses every link
//!    into the site. A `GET` that changes something is not covered, and no
//!    CSRF check covers it: the route is the bug.
//! 2. `Sec-Fetch-Site: same-origin` or `none` passes: the browser says the
//!    request came from this origin, or from the user typing the address.
//! 3. Any other `Sec-Fetch-Site`, `same-site` included, passes only when
//!    `Origin` is one of the origins named. **`same-site` is refused on
//!    purpose**: it is what `SameSite=Lax` lets through, so a page on any
//!    subdomain of the site (a user's upload, a forgotten staging host) could
//!    otherwise post with the session cookie attached.
//! 4. No `Sec-Fetch-Site` but an `Origin`: passes when it is named, or when
//!    it names the authority the `Host` header did, scheme aside, the rule
//!    the WebSocket handshake uses (ADR 080).
//! 5. Neither header: passes. `curl`, a webhook, another server and every
//!    test in `bench/` send neither, and none of them has somebody else's
//!    cookie to borrow. The browser that sends neither is from before 2020.
//!
//! A refusal is a 403 naming the origin and the option, before the handler
//! runs. Nothing is allocated either way, and a request that changes nothing
//! is one compare of the method.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const mw = @import("middleware.zig");
const http1 = @import("http1.zig");
const fail = @import("fail.zig");
const cors = @import("cors.zig");
const websocket = @import("websocket.zig");

pub const Options = struct {
    /// Pages on other origins that may send this server a request that
    /// changes something. Empty, the default, means only this server's own.
    ///
    /// Each entry is a scheme, a host and a port with nothing after them:
    /// `"https://app.example.com"`, `"http://localhost:5173"`. The compare is
    /// case-insensitive, because nothing is sent back and so there is no
    /// spelling that has to survive.
    origins: []const []const u8 = &.{},
};

/// Take a request that changes something only from this server's own pages.
pub const sameOrigin = with(.{});

pub fn with(comptime options: Options) mw.Middleware {
    comptime check(options);

    return struct {
        fn run(c: *Ctx, next: mw.Next) anyerror!void {
            try refuseCrossSite(c, options.origins);
            return next.run(c);
        }
    }.run;
}

/// The CSRF middleware, reading the origins it trusts from `held` rather than
/// from a list settled while compiling (ADR 088).
///
/// It takes the same `cors.Origins` the CORS middleware does, because a front
/// end on another origin is one fact and both halves need it: CORS to let the
/// page read the answer, this to let it change something. One variable, filled
/// once before `listen()`, hands it to both.
///
/// `held` is a comptime pointer, so it has to be a variable that outlives the
/// App, a container-level `var`.
pub fn reading(comptime held: *const cors.Origins) mw.Middleware {
    return struct {
        fn run(c: *Ctx, next: mw.Next) anyerror!void {
            try refuseCrossSite(c, held.list);
            return next.run(c);
        }
    }.run;
}

fn refuseCrossSite(c: *Ctx, trusted: []const []const u8) !void {
    if (safe(c.method)) return;

    const site = if (c.header("Sec-Fetch-Site")) |s| s.view() else null;
    const origin = if (c.header("Origin")) |o| o.view() else null;
    // The `Host` header itself, deliberately, and not `host()`: that one reads
    // `X-Forwarded-Host` under `trusted_hops`, and what this compares has to be
    // the authority the request really named (ADR 080).
    const host = if (c.header("Host")) |h| h.view() else "";

    if (allows(site, origin, host, trusted)) return;

    return fail.forbidden(
        "this request changes something and came from \"{s}\", a page this server " ++
            "does not serve; name it in csrf .origins if it is one",
        .{origin orelse "another site"},
    );
}

/// `GET`, `HEAD` and `OPTIONS`: what a link, an image and a preflight are.
fn safe(method: http1.Method) bool {
    return switch (method) {
        .GET, .HEAD, .OPTIONS => true,
        .POST, .PUT, .DELETE, .PATCH, .other => false,
    };
}

/// Whether a request that changes something may go on, given what the browser
/// said about where it came from. The whole rule is here, in the order the
/// header of this file gives it, so it can be tested without a request.
fn allows(
    site: ?[]const u8,
    origin: ?[]const u8,
    host: []const u8,
    trusted: []const []const u8,
) bool {
    if (site) |s| {
        if (std.ascii.eqlIgnoreCase(s, "same-origin")) return true;
        if (std.ascii.eqlIgnoreCase(s, "none")) return true;
        // The browser has said this is not our origin. Only a name can
        // overrule it; matching the `Host` would let an `http://` page post
        // to its `https://` twin, which the browser has just told us apart.
        const o = origin orelse return false;
        return named(o, trusted);
    }
    const o = origin orelse return true;
    if (named(o, trusted)) return true;
    return websocket.sameAuthority(o, host);
}

fn named(origin: []const u8, trusted: []const []const u8) bool {
    for (trusted) |one| {
        if (std.ascii.eqlIgnoreCase(one, origin)) return true;
    }
    return false;
}

/// Everything that can be wrong with a list of trusted origins, said while
/// compiling. Each is a list that would trust nobody, or everybody, while
/// reading as though it did what it says.
fn check(comptime options: Options) void {
    comptime {
        for (options.origins) |origin| {
            if (origin.len == 0) @compileError(
                "nilo: csrf was given an empty origin, which matches nothing.\n" ++
                    "  An origin is a scheme, a host and a port: " ++
                    "\"https://app.example.com\", \"http://localhost:5173\".",
            );

            if (std.mem.eql(u8, origin, "*")) @compileError(
                "nilo: csrf was told to trust \"*\", which is every page on the web, " ++
                    "and that is the same as not installing it.\n  Name the pages you serve, " ++
                    "or leave csrf off the routes that take requests from anywhere with " ++
                    "`app.without(…)`.",
            );

            const scheme_end = std.mem.indexOf(u8, origin, "://");
            const has_path = if (scheme_end) |at|
                std.mem.indexOfScalar(u8, origin[at + "://".len ..], '/') != null
            else
                false;
            if (scheme_end == null or has_path) @compileError(
                "nilo: the csrf origin \"" ++ origin ++ "\" is not an origin, so no " ++
                    "request would ever match it.\n  A browser sends a scheme, a host and a " ++
                    "port with nothing after them: \"https://app.example.com\", no path and " ++
                    "no trailing slash.",
            );
        }
    }
}

const testing = std.testing;

test "a request from this server's own page goes through" {
    try testing.expect(allows("same-origin", "https://example.dev", "example.dev", &.{}));
    // The origin is not consulted when the browser has already said so,
    // because a proxy that rewrites `Host` is ordinary.
    try testing.expect(allows("same-origin", "https://example.dev", "127.0.0.1:8080", &.{}));
}

test "a request the user started by typing the address goes through" {
    try testing.expect(allows("none", null, "example.dev", &.{}));
}

test "a cross-site page is refused unless it was named" {
    try testing.expect(!allows("cross-site", "https://evil.example", "example.dev", &.{}));
    try testing.expect(allows(
        "cross-site",
        "https://app.example.com",
        "api.example.com",
        &.{"https://app.example.com"},
    ));
}

test "a page on another subdomain of the site is refused, which SameSite=Lax would not do" {
    try testing.expect(!allows("same-site", "https://uploads.example.dev", "example.dev", &.{}));
    try testing.expect(allows(
        "same-site",
        "https://app.example.dev",
        "api.example.dev",
        &.{"https://app.example.dev"},
    ));
}

test "a cross-site request is not let through by an Origin that matches the Host" {
    // An `http://` page posting to its `https://` twin: the browser calls it
    // cross-site, and the `Host` compare, which ignores the scheme, would not.
    try testing.expect(!allows("cross-site", "http://example.dev", "example.dev", &.{}));
}

test "a cross-site request that carries no Origin is refused" {
    try testing.expect(!allows("cross-site", null, "example.dev", &.{}));
}

test "with no Sec-Fetch-Site, an Origin naming the Host goes through, scheme aside" {
    try testing.expect(allows(null, "https://example.dev", "example.dev", &.{}));
    try testing.expect(allows(null, "http://localhost:5173", "localhost:5173", &.{}));
    try testing.expect(!allows(null, "https://evil.example", "example.dev", &.{}));
    try testing.expect(allows(null, "https://app.example.com", "api.example.com", &.{"https://app.example.com"}));
}

test "an Origin of null, from a sandboxed frame or a file, is refused" {
    try testing.expect(!allows(null, "null", "example.dev", &.{}));
    try testing.expect(!allows("cross-site", "null", "example.dev", &.{}));
}

test "a request that says nothing about where it came from goes through" {
    // curl, a webhook, another server: none has a cookie to borrow.
    try testing.expect(allows(null, null, "example.dev", &.{}));
}

test "a named origin is a whole match, never a prefix" {
    const trusted: []const []const u8 = &.{"https://app.example.com"};
    try testing.expect(!allows("cross-site", "https://app.example.com.evil.com", "api.example.com", trusted));
    try testing.expect(!allows("cross-site", "https://app.example.co", "api.example.com", trusted));
    try testing.expect(allows("cross-site", "HTTPS://APP.EXAMPLE.COM", "api.example.com", trusted));
}

test "only the methods that change something are checked" {
    try testing.expect(safe(.GET));
    try testing.expect(safe(.HEAD));
    try testing.expect(safe(.OPTIONS));
    try testing.expect(!safe(.POST));
    try testing.expect(!safe(.PUT));
    try testing.expect(!safe(.PATCH));
    try testing.expect(!safe(.DELETE));
    try testing.expect(!safe(.other));
}
