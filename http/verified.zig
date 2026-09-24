//! The claims behind a bearer token, as a handler argument — or a 401 with
//! the challenge on it before the handler runs
//! ([ADR 191](../docs/adr/191-verified-claims-are-a-handler-argument.md)).
//!
//! ```zig
//! const Google = jwt.Verifier(Claims, fetch.Client);
//!
//! fn me(user: nilo.Verified(Google), db: *Db) !Profile {
//!     return db.profileFor(user.claims.sub) orelse
//!         return nilo.Verified(Google).refuse("that account is closed", .{});
//! }
//! ```
//!
//! `nilo.Authorization(.bearer)` reads the header and stops at the token,
//! because a token is opaque to everybody but its issuer. This is the next
//! step up: the same header, then `Verifier.verify` on it — the ring, the
//! issuer, the audience and the clock, and a fetch of the issuer's keys when
//! a `kid` went missing — and the handler gets a struct of its own with the
//! claims in it. What used to be four lines in every authenticated handler,
//! or a resolver written once per program, is the argument's type.
//!
//! **The argument names the Verifier, and nilo looks the service up.** A
//! `jwt.Verifier(Claims, Client)` holds the ring and the client together, so
//! naming one type reaches both; `listen()` refuses to start when it was not
//! provided, the way it does for any service a route needs.
//!
//! **A refusal is a 401 with `WWW-Authenticate: Bearer`**, whether it is
//! nilo's — no header, the wrong scheme, a token the ring refuses — or the
//! handler's after reading, through `T.refuse`. The message names why the
//! token was refused (`Expired`, `WrongAudience`), because a client that can
//! be told to sign in again is better off than one told nothing, and none of
//! the reasons is a secret. The one answer that is not a 401 is the issuer's
//! keys being unreachable when a refresh was needed: that is a 503, since the
//! token may be perfectly good and the client should try again.
//!
//! **What it costs.** Reading the header allocates nothing; the claims are
//! parsed into the request arena, which is the one allocation `jwt.verify`
//! makes for the caller. The verification itself is the signature check —
//! an RSA exponentiation, on the route that asked. Nothing is held between
//! requests. A middleware guarding a prefix reads the same thing with
//! `c.verified(Google)`, and a handler under it that asks again verifies
//! again: the second check costs what the first did.
//!
//! This file names nothing in `http_core`: it reads a header value, an
//! arena, a lifetime and the Verifier, and `Ctx.verified` and the typed
//! engine are what hand those over.

const std = @import("std");
const core = @import("nilo_core");
const fail = @import("fail.zig");
const naming = @import("names.zig");
const authorization_mod = @import("authorization.zig");

const Str = core.Str;

/// The typed argument — see the file header. `V` is a `jwt.Verifier(…)`, or
/// anything carrying `nilo_verifier` (the claims type) and a
/// `verify(gpa, token, now_s, scope)` that answers it.
pub fn Verified(comptime V: type) type {
    comptime check(V);
    return struct {
        /// The Verifier this reads through, which `listen()` checks was
        /// provided and the typed engine looks up.
        pub const nilo_verified = V;
        /// What a nilo compile error calls this type (ADR 074).
        pub const nilo_type_name = "nilo.Verified(" ++ naming.of(V) ++ ")";
        /// What a 401 from this endpoint says in `WWW-Authenticate`.
        pub const challenge: [:0]const u8 = "Bearer";

        /// The payload, read into the Verifier's claims type. Strings in it
        /// point into the request arena.
        claims: V.nilo_verifier,
        /// The token as the client sent it, for a handler that passes it on.
        token: Str,

        /// A 401 that carries this endpoint's challenge. For the refusal
        /// that comes *after* verifying — the account is closed, the role
        /// is wrong.
        pub fn refuse(comptime fmt: []const u8, args: anytype) fail.Error {
            return fail.challenge(challenge, fmt, args);
        }
    };
}

/// Whether `T` is a `Verified(…)`. Asked by the typed engine.
pub fn is(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "nilo_verified"),
        else => false,
    };
}

/// Read the header, verify the token through `verifier`, or stop the
/// request with the 401 — or the 503 — the header says. `c.verified(V)` is
/// this with the Ctx's own arguments filled in, and it is what a middleware
/// calls. `scope` goes through to the Verifier's client for the fetch a
/// rotation costs.
pub fn read(
    comptime T: type,
    header: ?[]const u8,
    arena: std.mem.Allocator,
    lifetime: *const core.Lifetime,
    now_s: i64,
    scope: anytype,
    verifier: *T.nilo_verified,
) !T {
    const auth = try authorization_mod.read(.bearer, header, arena, lifetime);
    // Widened to `anyerror` because the names below belong to a module this
    // file does not import, and a Verifier of the caller's own — or a test's
    // fake — may answer a narrower set that a switch on it could not name.
    const claims = verifier.verify(arena, auth.value.view(), now_s, scope) catch |err| switch (@as(anyerror, err)) {
        error.OutOfMemory => return error.OutOfMemory,
        // Everything `jwt.verify` says about a token, by name.
        error.NotAToken,
        error.WrongAlgorithm,
        error.NoSuchKey,
        error.NoExpiry,
        error.Expired,
        error.NotYetValid,
        error.WrongIssuer,
        error.WrongAudience,
        error.ClaimsNotReadable,
        error.KeySizeNotSupported,
        error.CurveNotSupported,
        error.SignatureWrongLength,
        error.KeyNotUsable,
        error.BadSignature,
        => return fail.challenge(T.challenge, "that token is not valid here ({s})", .{@errorName(err)}),
        // A refresh was needed and the issuer could not be reached, or
        // answered something that is not a key set. The token has not been
        // judged, so this is the service's failure rather than the client's.
        else => return fail.status(503, "the issuer's keys could not be fetched to check this token ({s})", .{@errorName(err)}),
    };
    return .{ .claims = claims, .token = auth.value };
}

/// Everything that has to be true of `V` before a `Verified(V)` can be read,
/// said while compiling in the words of the thing that was written.
fn check(comptime V: type) void {
    comptime {
        switch (@typeInfo(V)) {
            .pointer => @compileError(
                "nilo: `nilo.Verified(" ++ naming.of(V) ++ ")` names a pointer, and the argument " ++
                    "names the Verifier's type.\n" ++
                    "  nilo looks the service up, the way it does for a `*Db`: " ++
                    "`nilo.Verified(" ++ naming.of(@typeInfo(V).pointer.child) ++ ")`.",
            ),
            .@"struct" => {},
            else => @compileError(
                "nilo: `nilo.Verified(" ++ naming.of(V) ++ ")` names " ++ naming.of(V) ++
                    ", which is not a `jwt.Verifier`.\n" ++
                    "  What goes here is the Verifier — the ring, the client and the claims " ++
                    "type held as one Service: `nilo.Verified(jwt.Verifier(Claims, fetch.Client))`.",
            ),
        }
        if (!@hasDecl(V, "nilo_verifier")) @compileError(
            "nilo: `nilo.Verified(" ++ naming.of(V) ++ ")` names " ++ naming.of(V) ++
                ", which is not a `jwt.Verifier`.\n" ++
                "  If " ++ naming.of(V) ++ " is the claims struct, it goes *inside* the Verifier, " ++
                "beside the client that fetches the issuer's keys:\n" ++
                "    const Google = jwt.Verifier(" ++ naming.of(V) ++ ", fetch.Client);\n" ++
                "    fn me(user: nilo.Verified(Google)) !Profile { … user.claims … }",
        );
        if (!@hasDecl(V, "verify")) @compileError(
            "nilo: `nilo.Verified(" ++ naming.of(V) ++ ")` names a Verifier with no `verify`.\n" ++
                "  `jwt.Verifier(Claims, Client)` has one; a Verifier of your own needs " ++
                "`verify(self, gpa, token, now_s, scope) !Claims`.",
        );
    }
}

/// A `Verified` in the return type, which `typed.checkAnswer` refuses: it is
/// read from the request, and answering with it would echo the token.
pub fn checkNotAnswered(comptime pattern: []const u8, comptime T: type) void {
    comptime {
        if (!is(T)) return;
        @compileError(
            "nilo: the handler for route \"" ++ pattern ++ "\" returns " ++ naming.of(T) ++
                ", which is what a handler is *given* rather than what it answers with.\n" ++
                "  The claims are an argument: `fn me(user: " ++ naming.of(T) ++ ") !Profile`. " ++
                "What goes back to the client is a struct of your own, without the token in it.",
        );
    }
}

// ---- tests ----

const testing = std.testing;

test "a Verified is told apart from anything else by its marker" {
    const Fake = struct {
        pub const nilo_verifier = struct { sub: []const u8 };
        pub fn verify(self: *@This(), gpa: std.mem.Allocator, token: []const u8, now_s: i64, scope: anytype) !nilo_verifier {
            _ = .{ self, gpa, token, now_s, scope };
            return .{ .sub = "" };
        }
    };
    try testing.expect(is(Verified(Fake)));
    try testing.expect(!is(Fake));
    try testing.expect(!is(u32));
    try testing.expectEqualStrings("Bearer", Verified(Fake).challenge);
}

// Below the first test on purpose: `zig build layering` reads an import
// under it as a test's, and this file names nothing in the core otherwise.
const App = @import("app.zig").App;
const Ctx = @import("ctx.zig").Ctx;
const typed = @import("typed.zig");
const openapi = @import("openapi.zig");
const nilo_testing = @import("testing.zig");
const middleware = @import("middleware.zig");

const Claims = struct { sub: []const u8, email: []const u8 };

/// What `jwt.Verifier(Claims, fetch.Client)` looks like from here: a marker
/// and a `verify`. The real one is tested in `jwt/verifier.zig`; this one
/// decides by the token's text, so the test needs no keys.
const FakeVerifier = struct {
    pub const nilo_verifier = Claims;

    verified: u32 = 0,

    pub fn verify(self: *FakeVerifier, gpa: std.mem.Allocator, token: []const u8, now_s: i64, scope: anytype) !Claims {
        _ = scope;
        self.verified += 1;
        if (std.mem.eql(u8, token, "expired")) return error.Expired;
        if (std.mem.eql(u8, token, "unreachable")) return error.KeysNotAvailable;
        if (!std.mem.startsWith(u8, token, "ok:")) return error.BadSignature;
        // The clock arrives as the Verifier would see it.
        if (now_s < 1_500_000_000) return error.NotYetValid;
        return .{ .sub = try gpa.dupe(u8, token["ok:".len..]), .email = "u@example" };
    }
};

const Profile = struct { sub: []const u8, email: []const u8 };

fn me(user: Verified(FakeVerifier)) Profile {
    return .{ .sub = user.claims.sub, .email = user.claims.email };
}

fn closed(user: Verified(FakeVerifier)) !Profile {
    _ = user;
    return Verified(FakeVerifier).refuse("that account is closed", .{});
}

fn guarded(c: *Ctx, next: middleware.Next) !void {
    _ = try c.verified(FakeVerifier);
    return next.run(c);
}

fn appServing(app: *App, verifier: *FakeVerifier) !void {
    try app.provide(verifier);
    try app.get("/me", me);
    try app.get("/closed", closed);
    try app.useOn("/admin", guarded);
    try app.get("/admin/me", me);
}

test "a verified argument is the claims, and a token the ring refuses is a 401 with the challenge" {
    var verifier: FakeVerifier = .{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try appServing(&app, &verifier);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    // No header at all is `Authorization(.bearer)`'s own refusal.
    const bare = try client.get(&app, "/me");
    try testing.expectEqual(@as(u16, 401), bare.status);
    try testing.expectEqualStrings("Bearer", bare.header("WWW-Authenticate").?);
    try testing.expectEqual(@as(u32, 0), verifier.verified);

    try client.setHeader("Authorization", "Bearer ok:u-7");
    const answered = try client.get(&app, "/me");
    try testing.expectEqual(@as(u16, 200), answered.status);
    try testing.expectEqualStrings("{\"sub\":\"u-7\",\"email\":\"u@example\"}", answered.body);
    try testing.expectEqual(@as(u32, 1), verifier.verified);

    try client.setHeader("Authorization", "Bearer expired");
    const refused = try client.get(&app, "/me");
    try testing.expectEqual(@as(u16, 401), refused.status);
    try testing.expectEqualStrings("Bearer", refused.header("WWW-Authenticate").?);
    try testing.expect(std.mem.indexOf(u8, refused.body, "not valid here (Expired)") != null);

    // The handler's own refusal after reading carries the same challenge.
    try client.setHeader("Authorization", "Bearer ok:u-7");
    const shut = try client.get(&app, "/closed");
    try testing.expectEqual(@as(u16, 401), shut.status);
    try testing.expectEqualStrings("Bearer", shut.header("WWW-Authenticate").?);
    try testing.expect(std.mem.indexOf(u8, shut.body, "that account is closed") != null);
}

test "keys that could not be fetched are a 503 rather than a 401, because the token was not judged" {
    var verifier: FakeVerifier = .{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try appServing(&app, &verifier);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();
    try client.setHeader("Authorization", "Bearer unreachable");
    const answer = try client.get(&app, "/me");
    try testing.expectEqual(@as(u16, 503), answer.status);
    try testing.expect(answer.header("WWW-Authenticate") == null);
    try testing.expect(std.mem.indexOf(u8, answer.body, "KeysNotAvailable") != null);
}

test "a middleware reads the same thing with c.verified, and the handler under it verifies again" {
    var verifier: FakeVerifier = .{};
    var app = App.init(testing.allocator);
    defer app.deinit();
    try appServing(&app, &verifier);

    var client = try nilo_testing.Client.init(testing.allocator, .{});
    defer client.deinit();

    try client.setHeader("Authorization", "Bearer expired");
    const stopped = try client.get(&app, "/admin/me");
    try testing.expectEqual(@as(u16, 401), stopped.status);
    try testing.expectEqual(@as(u32, 1), verifier.verified);

    try client.setHeader("Authorization", "Bearer ok:u-9");
    const through = try client.get(&app, "/admin/me");
    try testing.expectEqual(@as(u16, 200), through.status);
    try testing.expectEqualStrings("{\"sub\":\"u-9\",\"email\":\"u@example\"}", through.body);
    // Once in the guard and once in the handler: the cost the header states.
    try testing.expectEqual(@as(u32, 3), verifier.verified);
}

test "a route that asks for a Verified needs the Verifier provided, and the document says bearer" {
    var app = App.init(testing.allocator);
    defer app.deinit();
    try app.get("/me", me);

    // The requirement is the Verifier, by pointer, the way a `*Db` is.
    const needs = comptime typed.requirements("/me", me);
    try testing.expectEqual(@as(usize, 1), needs.len);
    try testing.expectEqualStrings(@typeName(FakeVerifier), needs[0].type_name);
    try testing.expect(needs[0].needs_mutable);

    const op = comptime typed.operation("/me", me);
    try testing.expectEqual(openapi.Security.bearer, op.security);
}
