//! The response headers a browser reads as policy, as one middleware
//! ([ADR 246](../docs/adr/246-the-headers-a-browser-reads-as-policy-are-one-block.md)).
//!
//! ```zig
//! try app.use(nilo.secure.api(.{}));        // JSON and nothing a browser renders
//! try app.use(nilo.secure.pages(.{}));      // a server that also serves the pages
//! try app.use(nilo.secure.pages(.{
//!     .csp = "default-src 'self'; img-src 'self' https://cdn.example.com",
//! }));
//! ```
//!
//! **Two presets, because there are two kinds of server.** An API answers
//! with JSON that no browser should render, frame or let a page script into,
//! so `api` sends the policy that forbids all of it: `default-src 'none'`,
//! no framing, no referrer. A server that serves its own front end needs the
//! page to load its own scripts, styles, fonts and images, so `pages` sends
//! the policy Express's helmet made the common one, without the three
//! headers no browser reads any more and without `upgrade-insecure-requests`,
//! which turns a plain `http://localhost` page's assets into failed loads.
//!
//! **Every header is a field, and a field set to `null` is not sent.** The
//! values with a closed set (`Referrer-Policy`, the three `Cross-Origin-*`,
//! `X-Frame-Options`) are enums, so a misspelt value is a compile error
//! instead of a header the browser silently ignores. The two with an open
//! grammar (`Content-Security-Policy`, `Permissions-Policy`) are text, checked
//! while compiling for the bytes a header line cannot hold.
//! `X-Content-Type-Options: nosniff` has no field: it is never wrong.
//!
//! **What it costs is bytes on the wire, and nothing else.** The whole block
//! is assembled while compiling and kept as one of the seven header slots the
//! Ctx holds (`Ctx.putPolicy`), so the middleware is one store, allocates
//! nothing, and leaves the other six slots to CORS, gzip and the handler. The
//! response grows by the block: 200 bytes for `api` and 515 for `pages` as
//! shipped (a test below holds both), against an answer the size of
//! `{"id":7}`.
//!
//! **A route can change one line without writing the rest.** A handler that
//! sets one of these headers itself replaces that line of the block, rather
//! than sending two (`http1.isPolicyHeader`); two `Content-Security-Policy`
//! lines would make the browser enforce both. A group that installs a second
//! `nilo.secure` replaces the App's block whole.
//!
//! **`Strict-Transport-Security` goes out on plain HTTP too**, and that is
//! harmless by RFC 6797 §8.1: a browser ignores it on a connection that was
//! not TLS. Which is the point of sending it from here: behind a platform
//! that terminates TLS in front and adds nothing (most of them), the header
//! only exists if the application writes it. On a `-Dtls` listener this is
//! the only place it comes from.

const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const mw = @import("middleware.zig");

/// `Referrer-Policy`: how much of this page's address another site is told
/// when a link or a request leaves it.
pub const Referrer = enum {
    no_referrer,
    no_referrer_when_downgrade,
    origin,
    origin_when_cross_origin,
    same_origin,
    strict_origin,
    strict_origin_when_cross_origin,
    unsafe_url,
};

/// `X-Frame-Options`: who may put this page in a frame. Kept beside the
/// CSP's `frame-ancestors`, which supersedes it in every current browser,
/// because the scanners people grade a site with still look for it.
pub const Frame = enum { deny, same_origin };

/// `Cross-Origin-Opener-Policy`: whether a window this page opens, or that
/// opened it, keeps a handle on it.
pub const Opener = enum { same_origin, same_origin_allow_popups, noopener_allow_popups, unsafe_none };

/// `Cross-Origin-Resource-Policy`: which sites may load this answer with an
/// `<img>`, a `<script>` or a `fetch` in `no-cors` mode.
pub const Resource = enum { same_origin, same_site, cross_origin };

/// `Cross-Origin-Embedder-Policy`: what this page may load from other
/// origins. Off in both presets, because `require_corp` refuses every
/// third-party asset that does not opt in, which is most of them.
pub const Embedder = enum { require_corp, credentialless, unsafe_none };

/// `Strict-Transport-Security`.
pub const Hsts = struct {
    /// How long a browser keeps reaching this host only over TLS. A year, the
    /// value the preload list asks for and the one most sites send.
    max_age_s: u32 = 365 * 24 * 60 * 60,
    /// Every subdomain too. Off by default, because it is a promise about
    /// hosts this server may not be: an `http://` intranet name under the
    /// same domain stops loading for a year.
    include_subdomains: bool = false,
    /// Ask to be put on the browsers' built-in list. Needs both of the above
    /// at their strong setting, which the compiler checks.
    preload: bool = false,
};

/// The policy for a server that answers with JSON and serves no pages.
pub const Api = struct {
    /// Nothing loads, nothing runs and nothing frames this answer, should a
    /// browser ever be pointed at it.
    csp: ?[]const u8 = "default-src 'none'; frame-ancestors 'none'",
    hsts: ?Hsts = .{},
    frame_options: ?Frame = .deny,
    referrer_policy: ?Referrer = .no_referrer,
    opener_policy: ?Opener = null,
    resource_policy: ?Resource = null,
    embedder_policy: ?Embedder = null,
    permissions_policy: ?[]const u8 = null,
};

/// The policy for a server whose answers include its own pages.
pub const Pages = struct {
    /// Scripts, styles, fonts and images from this origin; inline styles and
    /// styles from `https:` too, because a CSS-in-JS library writes `style`
    /// attributes; no plugins, no inline script, no `<base>` pointing away,
    /// no form posting away, and framing only by this origin.
    csp: ?[]const u8 = "default-src 'self'; base-uri 'self'; font-src 'self' https: data:; " ++
        "form-action 'self'; frame-ancestors 'self'; img-src 'self' data:; object-src 'none'; " ++
        "script-src 'self'; script-src-attr 'none'; style-src 'self' https: 'unsafe-inline'",
    hsts: ?Hsts = .{},
    frame_options: ?Frame = .same_origin,
    /// The browsers' own default, written down: a page sends only its origin
    /// to another site. `no_referrer` breaks embeds that check where they are
    /// shown, a YouTube player among them.
    referrer_policy: ?Referrer = .strict_origin_when_cross_origin,
    /// `same_origin_allow_popups` rather than `same_origin`, because the
    /// stricter value cuts the handle a "Sign in with Google" popup reports
    /// back through.
    opener_policy: ?Opener = .same_origin_allow_popups,
    resource_policy: ?Resource = .same_origin,
    embedder_policy: ?Embedder = null,
    permissions_policy: ?[]const u8 = null,
};

/// The policy for a server that answers with JSON and serves no pages.
pub fn api(comptime options: Api) mw.Middleware {
    return writing(comptime block(options));
}

/// The policy for a server whose answers include its own pages.
pub fn pages(comptime options: Pages) mw.Middleware {
    return writing(comptime block(options));
}

fn writing(comptime lines: []const u8) mw.Middleware {
    return struct {
        fn run(c: *Ctx, next: mw.Next) anyerror!void {
            try c.putPolicy(lines);
            return next.run(c);
        }
    }.run;
}

/// Every line the options ask for, `Name: value\r\n` each, as one string.
/// The one place the options are read, so a test can hold the bytes.
fn block(comptime options: anytype) []const u8 {
    comptime {
        check(options);
        var out: []const u8 = "X-Content-Type-Options: nosniff\r\n";
        if (options.csp) |csp| out = out ++ "Content-Security-Policy: " ++ csp ++ "\r\n";
        if (options.hsts) |h| out = out ++ "Strict-Transport-Security: " ++ hstsValue(h) ++ "\r\n";
        if (options.frame_options) |f| out = out ++ "X-Frame-Options: " ++ switch (f) {
            .deny => "DENY",
            .same_origin => "SAMEORIGIN",
        } ++ "\r\n";
        if (options.referrer_policy) |r| out = out ++ "Referrer-Policy: " ++ spelled(r) ++ "\r\n";
        if (options.opener_policy) |o| out = out ++ "Cross-Origin-Opener-Policy: " ++ spelled(o) ++ "\r\n";
        if (options.resource_policy) |r| out = out ++ "Cross-Origin-Resource-Policy: " ++ spelled(r) ++ "\r\n";
        if (options.embedder_policy) |e| out = out ++ "Cross-Origin-Embedder-Policy: " ++ spelled(e) ++ "\r\n";
        if (options.permissions_policy) |p| out = out ++ "Permissions-Policy: " ++ p ++ "\r\n";
        return out;
    }
}

fn hstsValue(comptime h: Hsts) []const u8 {
    return std.fmt.comptimePrint("max-age={d}", .{h.max_age_s}) ++
        (if (h.include_subdomains) "; includeSubDomains" else "") ++
        (if (h.preload) "; preload" else "");
}

/// An enum tag as the header spells it: `same_origin_allow_popups` is
/// `same-origin-allow-popups`.
fn spelled(comptime tag: anytype) []const u8 {
    comptime {
        const name = @tagName(tag);
        var out: [name.len]u8 = undefined;
        for (name, 0..) |ch, i| out[i] = if (ch == '_') '-' else ch;
        const final = out;
        return &final;
    }
}

/// Everything that can be wrong with a policy, said while compiling. Each is
/// a header that would go out and do nothing, or do something nobody meant.
fn check(comptime options: anytype) void {
    comptime {
        if (options.csp) |csp| {
            if (csp.len == 0) @compileError(
                "nilo: secure was given an empty csp, which sends a header that allows everything.\n" ++
                    "  Leave it out with `.csp = null`, or write the policy: " ++
                    "`.csp = \"default-src 'self'\"`.",
            );
            if (!lineOk(csp)) @compileError(
                "nilo: the secure csp holds a control byte, which would end the header line early.\n" ++
                    "  Write the policy on one line; directives are separated by `; `.",
            );
        }
        if (options.permissions_policy) |p| {
            if (p.len == 0) @compileError(
                "nilo: secure was given an empty permissions_policy, which sends a header that says nothing.\n" ++
                    "  Leave it out with `.permissions_policy = null`, or name what is off: " ++
                    "`\"camera=(), microphone=(), geolocation=()\"`.",
            );
            if (!lineOk(p)) @compileError(
                "nilo: the secure permissions_policy holds a control byte, which would end the header line early.\n" ++
                    "  Write it on one line; features are separated by `, `.",
            );
        }
        if (options.hsts) |h| {
            if (h.preload and (!h.include_subdomains or h.max_age_s < 365 * 24 * 60 * 60)) @compileError(
                "nilo: secure hsts asks for preload without what the preload list requires, so the request to be listed is refused.\n" ++
                    "  hstspreload.org takes a host only with `.include_subdomains = true` and " ++
                    "`.max_age_s` of at least a year (31536000).",
            );
            if (h.max_age_s == 0 and (h.include_subdomains or h.preload)) @compileError(
                "nilo: secure hsts has a max_age_s of 0, which tells a browser to forget the host, beside a setting that asks it to remember.\n" ++
                    "  To stop sending the header, `.hsts = null`; to clear it from browsers, " ++
                    "`.hsts = .{ .max_age_s = 0 }` and nothing else.",
            );
        }
    }
}

fn lineOk(comptime text: []const u8) bool {
    for (text) |ch| if (ch < 0x20 or ch == 0x7f) return false;
    return true;
}

const testing = std.testing;
const http1 = @import("http1.zig");

test "the api preset is the policy that forbids a browser everything" {
    try testing.expectEqualStrings(
        "X-Content-Type-Options: nosniff\r\n" ++
            "Content-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\n" ++
            "Strict-Transport-Security: max-age=31536000\r\n" ++
            "X-Frame-Options: DENY\r\n" ++
            "Referrer-Policy: no-referrer\r\n",
        comptime block(Api{}),
    );
}

test "what each preset adds to a response is the number its header says" {
    // The figures in this file's header and in ADR 246. A change to a
    // preset changes them, and this is what says so.
    try testing.expectEqual(@as(usize, 200), comptime block(Api{}).len);
    try testing.expectEqual(@as(usize, 515), comptime block(Pages{}).len);
}

test "a field set to null is not sent, and nosniff always is" {
    const lines = comptime block(Api{
        .csp = null,
        .hsts = null,
        .frame_options = null,
        .referrer_policy = null,
    });
    try testing.expectEqualStrings("X-Content-Type-Options: nosniff\r\n", lines);
}

test "an enum value is spelled the way the header spells it" {
    const lines = comptime block(Pages{ .embedder_policy = .require_corp, .resource_policy = .same_site });
    try testing.expect(std.mem.indexOf(u8, lines, "Cross-Origin-Opener-Policy: same-origin-allow-popups\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, lines, "Cross-Origin-Resource-Policy: same-site\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, lines, "Cross-Origin-Embedder-Policy: require-corp\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, lines, "X-Frame-Options: SAMEORIGIN\r\n") != null);
}

test "hsts says every part it was given" {
    const lines = comptime block(Api{ .hsts = .{ .include_subdomains = true, .preload = true } });
    try testing.expect(std.mem.indexOf(u8, lines, "Strict-Transport-Security: max-age=31536000; includeSubDomains; preload\r\n") != null);
}

test "every line of a preset names a header a handler's own setHeader replaces" {
    const lines = comptime block(Pages{ .embedder_policy = .credentialless, .permissions_policy = "camera=()" });
    var it = std.mem.splitSequence(u8, lines[0 .. lines.len - 2], "\r\n");
    while (it.next()) |line| {
        const name = line[0..std.mem.indexOfScalar(u8, line, ':').?];
        try testing.expect(http1.isPolicyHeader(name));
    }
}

test "a handler's own header takes the place of the block's line for it" {
    const lines = comptime block(Api{});
    const rest = try http1.withoutLine(testing.allocator, lines, "content-security-policy");
    defer testing.allocator.free(rest);
    try testing.expect(std.mem.indexOf(u8, rest, "Content-Security-Policy") == null);
    try testing.expectEqual(lines.len - "Content-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\n".len, rest.len);
    try testing.expect(std.mem.startsWith(u8, rest, "X-Content-Type-Options: nosniff\r\nStrict-Transport-Security"));

    // A name the block does not carry leaves it as it was, unallocated.
    const same = try http1.withoutLine(testing.allocator, lines, "permissions-policy");
    try testing.expectEqual(lines.ptr, same.ptr);
}
