//! Reading a signed JWT, in the order that makes the checks mean something.
//!
//! **The algorithm comes from the key, never from the token.** A verifier
//! that reads `alg` out of the header and does what it says will accept
//! `{"alg":"none"}`, and will accept an HMAC signed with the RSA public key
//! it published. So `alg` is not an instruction here, it is one more thing
//! compared — first against the four names this file knows, before any key
//! is looked up, and then against the one the key that was found answers to
//! (ADR 111): RS256 for an RSA key, and for the others the curve decides,
//! `P-256` ES256, `P-384` ES384, `Ed25519` EdDSA. A token saying `ES256`
//! over an RSA key is not "try ECDSA"; it is a mismatch, and it is refused
//! the way `none` is. So is `ES384` over a P-256 key.
//!
//! **Nothing in the payload is looked at until the signature has passed.**
//! `exp` off an unverified token is a number somebody chose.
//!
//! The claims come back as a struct of the caller's own — the same bargain
//! the rest of nilo makes, and the reason `sub` and `email` are fields with
//! types rather than lookups into a map. The registered claims are checked
//! whether or not that struct names them (ADR 111).

const std = @import("std");
const b64 = @import("b64.zig");
const jwks = @import("jwks.zig");
const rs256 = @import("rs256.zig");
const es256 = @import("es256.zig");
const es384 = @import("es384.zig");
const eddsa = @import("eddsa.zig");
const memo_mod = @import("memo.zig");

/// The names a header's `alg` may carry, and the whole of what is accepted
/// before a key is looked up. Which of them a token actually gets is the
/// key's decision.
const known_algorithms = [_][]const u8{ "RS256", "ES256", "ES384", "EdDSA" };

pub const Error = error{
    /// Not three base64url segments separated by two dots.
    NotAToken,
    /// The header says something other than `RS256`, `ES256`, `ES384` or
    /// `EdDSA` — including `none` — or says one of them over a key that
    /// answers to another.
    WrongAlgorithm,
    /// The header's `kid` is not in the key set, or it named none and the
    /// set has more than one key to choose from.
    NoSuchKey,
    /// The token carries no `exp`. A credential with no end is not one.
    NoExpiry,
    /// `exp` has passed.
    Expired,
    /// `nbf` has not arrived.
    NotYetValid,
    /// `iss` is not the issuer that was asked for, or there is none.
    WrongIssuer,
    /// `aud` does not carry the audience that was asked for.
    WrongAudience,
    /// The signature checked out and the payload does not fit the struct the
    /// caller asked for.
    ClaimsNotReadable,
    OutOfMemory,
} || rs256.Error || es256.Error || es384.Error || eddsa.Error;

/// What one registered claim has to be, said out loud. A union rather than a
/// nullable string, so that skipping a check is a word on the line that
/// builds the options and not a `null` that reads as a value
/// ([ADR 111](../docs/adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)).
pub const Expect = union(enum) {
    /// The claim has to be this: `iss` equal to it, or `aud` carrying it.
    is: []const u8,
    /// Nothing is asked of the claim, and the caller has said so.
    unchecked,
};

pub const Options = struct {
    /// The issuer's keys. Fetching and refreshing them is the caller's —
    /// `nilo_fetch` sends the GET and `nilo_cache` holds the answer.
    keys: *const jwks.Keys,
    /// What `iss` has to be. No default, so leaving it out is a compile
    /// error naming the field rather than a check that quietly is not
    /// there (ADR 111). `.unchecked` is for a key set shared by several
    /// issuers, which Microsoft's multi-tenant endpoint is.
    issuer: Expect,
    /// What `aud` has to carry. For Google this is the OAuth client id.
    /// No default, for the reason `issuer` has none: a Google ID token
    /// minted for somebody else's application is signed by the same keys as
    /// yours, and `aud` is all that tells them apart. `.unchecked` is for an
    /// access token whose issuer puts no `aud` in it (Cognito's, Clerk's
    /// and Keycloak's can lack one), and the check then moves to the claim
    /// that does name the application, in your own `Claims`.
    audience: Expect,
    /// Now, in seconds since the epoch. An argument rather than a clock, for
    /// the reason `nilo_id` takes a millisecond as one: a module with no
    /// event loop has no clock, and a test that cannot choose the time
    /// cannot test an expiry.
    now_s: i64,
    /// How far the two clocks are allowed to disagree, both ways.
    leeway_s: u32 = 0,
    /// Signatures already checked under these keys, so a token seen again
    /// skips the arithmetic and not the claims (`memo.zig`). Null checks
    /// every signature.
    memo: ?*memo_mod.Memo = null,
};

/// What the header is read into. Everything optional: it is somebody else's
/// document until it has been checked.
const Header = struct {
    alg: ?[]const u8 = null,
    kid: ?[]const u8 = null,
    typ: ?[]const u8 = null,
};

/// The claims JWT itself defines, as opposed to the ones the caller's struct
/// names. `aud` is a `Value` because it is a string in most tokens and an
/// array of strings in some, and both are legal.
const Registered = struct {
    iss: ?[]const u8 = null,
    aud: ?std.json.Value = null,
    exp: ?i64 = null,
    nbf: ?i64 = null,
};

/// Verify a token and read its payload into `Claims`.
///
/// Strings in the result point into `gpa`. Hand it a request arena and there
/// is nothing to free.
pub fn verify(
    comptime Claims: type,
    gpa: std.mem.Allocator,
    token: []const u8,
    opts: Options,
) Error!Claims {
    // Scratch for the header, the signature and the payload bytes. The
    // caller's allocator only ever holds the claims, so handing this a
    // long-lived gpa does not leak the parts nobody asked for.
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const tmp = scratch.allocator();

    const first = std.mem.indexOfScalar(u8, token, '.') orelse return error.NotAToken;
    const rest = token[first + 1 ..];
    const second = std.mem.indexOfScalar(u8, rest, '.') orelse return error.NotAToken;
    const signed = token[0 .. first + 1 + second];
    const payload_text = rest[0..second];
    const sig_text = rest[second + 1 ..];
    if (first == 0 or second == 0 or sig_text.len == 0) return error.NotAToken;
    // A fourth segment is JWE, which this does not read.
    if (std.mem.indexOfScalar(u8, sig_text, '.') != null) return error.NotAToken;

    const header_bytes = b64.keep(tmp, token[0..first]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotBase64Url => return error.NotAToken,
    };
    const header = std.json.parseFromSliceLeaky(Header, tmp, header_bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotAToken,
    };

    // Against the names known here, not against whatever the token would
    // like — and before a key is looked up, so `none` and `HS256` never get
    // as far as a `kid` match.
    const alg = header.alg orelse return error.WrongAlgorithm;
    if (!isKnown(alg)) return error.WrongAlgorithm;

    const key = opts.keys.find(header.kid) orelse return error.NoSuchKey;

    // A curve with no branch is named, not left to look like a mismatch: a
    // P-521 key under `ES256` is not the issuer using the wrong algorithm.
    if (!key.curveSupported()) return error.CurveNotSupported;

    // The key decides which arithmetic runs, and the header has to agree
    // with it. `ES256` over an RSA key is a mismatch, not a request.
    if (!std.mem.eql(u8, alg, key.algorithm())) return error.WrongAlgorithm;

    const sig = b64.keep(tmp, sig_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotBase64Url => return error.NotAToken,
    };
    // The memo answers for the whole token's bytes, so a different
    // signature, header or payload is a different digest and is checked.
    const digest: ?memo_mod.Digest = if (opts.memo != null) memo_mod.Memo.digestOf(token) else null;
    const remembered = if (opts.memo) |m| m.has(digest.?) else false;
    if (!remembered) {
        switch (key.material) {
            .rsa => |rsa| try rs256.verify(signed, sig, rsa.e, rsa.n),
            // The curve picked the `alg` above, and picks the arithmetic here.
            .ec => |ec| if (std.mem.eql(u8, ec.crv, es384.curves[0]))
                try es384.verify(signed, sig, ec.crv, ec.x, ec.y)
            else
                try es256.verify(signed, sig, ec.crv, ec.x, ec.y),
            .okp => |okp| try eddsa.verify(signed, sig, okp.crv, okp.x),
        }
        if (opts.memo) |m| m.remember(digest.?);
    }

    // Past here the bytes are the issuer's.
    const payload_bytes = b64.keep(tmp, payload_text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotBase64Url => return error.NotAToken,
    };
    const reg = std.json.parseFromSliceLeaky(Registered, tmp, payload_bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ClaimsNotReadable,
    };

    const leeway: i64 = opts.leeway_s;
    const exp = reg.exp orelse return error.NoExpiry;
    if (opts.now_s > exp + leeway) return error.Expired;
    if (reg.nbf) |nbf| {
        if (opts.now_s + leeway < nbf) return error.NotYetValid;
    }
    switch (opts.issuer) {
        .is => |want| {
            const iss = reg.iss orelse return error.WrongIssuer;
            if (!std.mem.eql(u8, iss, want)) return error.WrongIssuer;
        },
        .unchecked => {},
    }
    switch (opts.audience) {
        .is => |want| if (!audienceCarries(reg.aud, want)) return error.WrongAudience,
        .unchecked => {},
    }

    // `.alloc_always`: the default for a slice input points a string with no
    // escapes in it back into `payload_bytes`, which is scratch and is freed
    // on the way out. The promise on this function is that the strings live
    // in `gpa`, and this is what keeps it.
    return std.json.parseFromSliceLeaky(Claims, gpa, payload_bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ClaimsNotReadable,
    };
}

fn isKnown(alg: []const u8) bool {
    for (known_algorithms) |name| if (std.mem.eql(u8, alg, name)) return true;
    return false;
}

/// `aud` is one string in most tokens and a list in some. Both are the same
/// question: is this audience in there.
fn audienceCarries(aud: ?std.json.Value, want: []const u8) bool {
    const value = aud orelse return false;
    return switch (value) {
        .string => |s| std.mem.eql(u8, s, want),
        .array => |list| for (list.items) |item| {
            switch (item) {
                .string => |s| if (std.mem.eql(u8, s, want)) break true,
                else => {},
            }
        } else false,
        else => false,
    };
}

const testing = std.testing;

/// A 2048-bit key and a token signed with it, generated once with openssl and
/// pinned here, beside RFC 7515's own ES256 example. The RS256 payload is
/// `{"iss":"https://accounts.example","aud":"client-1","sub":"u-7",
///   "email":"a@example.com","exp":2000000000,"nbf":1000000000}`;
/// the RFC's is `{"iss":"joe","exp":1300819380,"http://example.com/is_root":true}`.
const vector = @import("vector.zig");

fn keySet() !jwks.Keys {
    return jwks.parse(testing.allocator, vector.jwks);
}

test "a token signed by the key in the set verifies, and the claims come back" {
    const Claims = struct { sub: []const u8, email: []const u8 };

    var keys = try keySet();
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const claims = try verify(Claims, arena.allocator(), vector.token, .{
        .keys = &keys,
        .issuer = .{ .is = "https://accounts.example" },
        .audience = .{ .is = "client-1" },
        .now_s = 1_500_000_000,
    });
    try testing.expectEqualStrings("u-7", claims.sub);
    try testing.expectEqualStrings("a@example.com", claims.email);
}

test "the claims live in the allocator handed in, not in verify's scratch" {
    const Claims = struct { sub: []const u8, email: []const u8 };

    var keys = try keySet();
    defer keys.deinit();

    // A real allocator rather than an arena, so that each string is its own
    // allocation and can be handed back to it. A string pointing into the
    // scratch arena — freed before this line runs — could not be freed here,
    // and the debug allocator says so.
    const claims = try verify(Claims, testing.allocator, vector.token, .{
        .keys = &keys,
        .now_s = 1_500_000_000,
        .issuer = .unchecked,
        .audience = .unchecked,
    });
    defer testing.allocator.free(claims.sub);
    defer testing.allocator.free(claims.email);

    try testing.expectEqualStrings("u-7", claims.sub);
    try testing.expectEqualStrings("a@example.com", claims.email);
}

test "one flipped byte in the payload is a bad signature, not a claim" {
    const Claims = struct { sub: []const u8 };

    var keys = try keySet();
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // One character of the payload segment, changed. The signature was taken
    // over the header and the payload together, so this is what a tampered
    // claim looks like on the wire.
    const bad = try arena.allocator().dupe(u8, vector.token);
    const at = std.mem.indexOfScalar(u8, bad, '.').? + 1;
    bad[at] = if (bad[at] == 'A') 'B' else 'A';
    try testing.expect(!std.mem.eql(u8, bad, vector.token));
    try testing.expectError(error.BadSignature, verify(Claims, arena.allocator(), bad, .{
        .keys = &keys,
        .now_s = 1_500_000_000,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));
}

test "alg none is refused before anything else is looked at" {
    const Claims = struct { sub: []const u8 };

    var keys = try keySet();
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // {"alg":"none"} . the real payload . nothing
    const forged = "eyJhbGciOiJub25lIn0." ++ vector.payload ++ ".";
    try testing.expectError(error.NotAToken, verify(Claims, arena.allocator(), forged, .{
        .keys = &keys,
        .now_s = 1_500_000_000,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));

    // …and with a signature-shaped segment on the end, so it is the `alg`
    // check doing the refusing rather than the empty third segment.
    const forged_sig = "eyJhbGciOiJub25lIn0." ++ vector.payload ++ ".AAAA";
    try testing.expectError(error.WrongAlgorithm, verify(Claims, arena.allocator(), forged_sig, .{
        .keys = &keys,
        .now_s = 1_500_000_000,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));
}

test "HS256 signed with the published modulus is refused" {
    const Claims = struct { sub: []const u8 };

    var keys = try keySet();
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // {"alg":"HS256"} — the confused-deputy attack every JWT library has had.
    const forged = "eyJhbGciOiJIUzI1NiJ9." ++ vector.payload ++ ".AAAA";
    try testing.expectError(error.WrongAlgorithm, verify(Claims, arena.allocator(), forged, .{
        .keys = &keys,
        .now_s = 1_500_000_000,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));
}

test "expiry, not-yet-valid, issuer and audience each get their own answer" {
    const Claims = struct { sub: []const u8 };

    var keys = try keySet();
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.Expired, verify(Claims, a, vector.token, .{
        .keys = &keys,
        .now_s = 2_000_000_001,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));
    try testing.expectError(error.NotYetValid, verify(Claims, a, vector.token, .{
        .keys = &keys,
        .now_s = 999_999_999,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));
    try testing.expectError(error.WrongIssuer, verify(Claims, a, vector.token, .{
        .keys = &keys,
        .issuer = .{ .is = "https://accounts.google.com" },
        .now_s = 1_500_000_000,
        .audience = .unchecked,
    }));
    try testing.expectError(error.WrongAudience, verify(Claims, a, vector.token, .{
        .keys = &keys,
        .audience = .{ .is = "some-other-client" },
        .now_s = 1_500_000_000,
        .issuer = .unchecked,
    }));
}

test "leeway covers a clock that is a minute out, and no more" {
    const Claims = struct { sub: []const u8 };

    var keys = try keySet();
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try verify(Claims, a, vector.token, .{
        .keys = &keys,
        .now_s = 2_000_000_030,
        .leeway_s = 60,
        .issuer = .unchecked,
        .audience = .unchecked,
    });
    try testing.expectError(error.Expired, verify(Claims, a, vector.token, .{
        .keys = &keys,
        .now_s = 2_000_000_090,
        .leeway_s = 60,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));
}

test "a kid that is not in the set says so rather than failing the signature" {
    const Claims = struct { sub: []const u8 };

    var keys = try jwks.parse(testing.allocator,
        \\{"keys":[{"kty":"RSA","kid":"somebody-else","n":"-_8","e":"AQAB"}]}
    );
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.NoSuchKey, verify(Claims, arena.allocator(), vector.token, .{
        .keys = &keys,
        .now_s = 1_500_000_000,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));
}

test "an audience given as a list is read the same as one given as a string" {
    try testing.expect(audienceCarries(.{ .string = "client-1" }, "client-1"));
    try testing.expect(!audienceCarries(.{ .string = "client-2" }, "client-1"));

    // Built by the parser rather than by hand, because a list `aud` only ever
    // reaches this function that way.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const listed = try std.json.parseFromSliceLeaky(
        Registered,
        arena.allocator(),
        \\{"aud":["other","client-1"]}
    ,
        .{ .ignore_unknown_fields = true },
    );
    try testing.expect(audienceCarries(listed.aud, "client-1"));
    try testing.expect(!audienceCarries(listed.aud, "client-3"));

    try testing.expect(!audienceCarries(null, "client-1"));
    try testing.expect(!audienceCarries(.{ .integer = 1 }, "client-1"));
}

test "things that are not tokens" {
    const Claims = struct { sub: []const u8 };

    var keys = try keySet();
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const opts: Options = .{ .keys = &keys, .issuer = .unchecked, .audience = .unchecked, .now_s = 1_500_000_000 };

    for ([_][]const u8{
        "",
        "one-segment",
        "two.segments",
        "a.b.c.d",
        ".b.c",
        "a..c",
        "a.b.",
        "!!!.b.c",
    }) |bad| {
        try testing.expectError(error.NotAToken, verify(Claims, a, bad, opts));
    }
}

// ES256, against RFC 7515 Appendix A.3.

const RfcClaims = struct { iss: []const u8, @"http://example.com/is_root": bool };

test "an ES256 token signed by the RFC's own key verifies, and the claims come back" {
    var keys = try jwks.parse(testing.allocator, vector.es256_jwks);
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const claims = try verify(RfcClaims, arena.allocator(), vector.es256_token, .{
        .keys = &keys,
        .issuer = .{ .is = "joe" },
        .now_s = 1_300_000_000,
        .audience = .unchecked,
    });
    try testing.expectEqualStrings("joe", claims.iss);
    try testing.expect(claims.@"http://example.com/is_root");

    // The registered claims are the module's business here as well.
    try testing.expectError(error.Expired, verify(RfcClaims, arena.allocator(), vector.es256_token, .{
        .keys = &keys,
        .now_s = 1_300_819_381,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));
    try testing.expectError(error.WrongIssuer, verify(RfcClaims, arena.allocator(), vector.es256_token, .{
        .keys = &keys,
        .issuer = .{ .is = "jane" },
        .now_s = 1_300_000_000,
        .audience = .unchecked,
    }));
}

test "one flipped byte in an ES256 payload is a bad signature, not a claim" {
    var keys = try jwks.parse(testing.allocator, vector.es256_jwks);
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const bad = try arena.allocator().dupe(u8, vector.es256_token);
    const at = std.mem.indexOfScalar(u8, bad, '.').? + 1;
    bad[at] = if (bad[at] == 'A') 'B' else 'A';
    try testing.expectError(error.BadSignature, verify(RfcClaims, arena.allocator(), bad, .{
        .keys = &keys,
        .now_s = 1_300_000_000,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));
}

test "an ES256 signature sent as DER is refused by its length, not as a bad signature" {
    var keys = try jwks.parse(testing.allocator, vector.es256_jwks);
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // The same r and s, wrapped the way every tool outside JOSE wraps them.
    const der = vector.es256_header ++ "." ++ vector.es256_payload ++ "." ++ vector.es256_signature_der;
    try testing.expectError(error.SignatureWrongLength, verify(RfcClaims, arena.allocator(), der, .{
        .keys = &keys,
        .now_s = 1_300_000_000,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));
}

test "a header saying ES256 over an RSA key is a mismatch, and so is the other way round" {
    const Claims = struct { iss: []const u8 };

    // The mixed set: an RSA key under `test-key`, the RFC's EC key under
    // `es256-key`, an Ed25519 key under `an-okp-key`, and the RS256 token
    // still reads against it.
    var keys = try keySet();
    defer keys.deinit();
    try testing.expectEqual(@as(usize, 3), keys.all.len);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try verify(Claims, a, vector.token, .{ .keys = &keys, .issuer = .unchecked, .audience = .unchecked, .now_s = 1_500_000_000 });

    // {"alg":"ES256","kid":"test-key"} — the RFC's real ES256 payload and
    // signature, pointed at the RSA key. Refused before any arithmetic.
    const es_over_rsa = "eyJhbGciOiJFUzI1NiIsImtpZCI6InRlc3Qta2V5In0." ++ vector.es256_payload ++ "." ++ vector.es256_signature;
    try testing.expectError(error.WrongAlgorithm, verify(Claims, a, es_over_rsa, .{
        .keys = &keys,
        .now_s = 1_300_000_000,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));

    // {"alg":"RS256","kid":"es256-key"} — the real RS256 payload and
    // signature, pointed at the EC key.
    const rsa_over_ec = "eyJhbGciOiJSUzI1NiIsImtpZCI6ImVzMjU2LWtleSJ9." ++ vector.payload ++ "." ++ vector.signature;
    try testing.expectError(error.WrongAlgorithm, verify(Claims, a, rsa_over_ec, .{
        .keys = &keys,
        .now_s = 1_500_000_000,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));

    // And the honest header over the EC key gets as far as the signature,
    // which was taken over a different header: a bad signature, not a
    // mismatch. That is the check after the one above, doing its job.
    const es_over_ec = "eyJhbGciOiJFUzI1NiIsImtpZCI6ImVzMjU2LWtleSJ9." ++ vector.es256_payload ++ "." ++ vector.es256_signature;
    try testing.expectError(error.BadSignature, verify(Claims, a, es_over_ec, .{
        .keys = &keys,
        .now_s = 1_300_000_000,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));
}

test "ES512 and every other name are refused before a key is looked up" {
    const Claims = struct { iss: []const u8 };

    var keys = try jwks.parse(testing.allocator, vector.es256_jwks);
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // {"alg":"ES512"} over the one-key set, which would otherwise answer.
    const forged = "eyJhbGciOiJFUzUxMiJ9." ++ vector.es256_payload ++ "." ++ vector.es256_signature;
    try testing.expectError(error.WrongAlgorithm, verify(Claims, arena.allocator(), forged, .{
        .keys = &keys,
        .now_s = 1_300_000_000,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));
}

test "a key on a curve with no branch is refused by name rather than as missing" {
    const Claims = struct { iss: []const u8 };

    var keys = try jwks.parse(testing.allocator,
        \\{"keys":[{"kty":"EC","crv":"P-521","x":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4v","y":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4v"}]}
    );
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.CurveNotSupported, verify(Claims, arena.allocator(), vector.es256_token, .{
        .keys = &keys,
        .now_s = 1_300_000_000,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));
}

test "the issuer and the audience have no default, so a call or a ring cannot leave either unsaid" {
    const Ring = @import("keyring.zig").Keyring.Options;
    inline for (.{ Options, Ring }) |T| {
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types, info.field_attrs) |name, FT, attrs| {
            if (comptime (std.mem.eql(u8, name, "issuer") or std.mem.eql(u8, name, "audience"))) {
                try testing.expect(attrs.defaultValue(FT) == null);
            }
        }
    }
}

test "an audience of .unchecked accepts a token with no aud, and an audience that is a value refuses it" {
    // RFC 7515's ES256 token carries `iss` and `exp` and no `aud`: the shape
    // of an access token whose issuer names the application in another claim.
    var keys = try jwks.parse(testing.allocator, vector.es256_jwks);
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.WrongAudience, verify(RfcClaims, arena.allocator(), vector.es256_token, .{
        .keys = &keys,
        .issuer = .{ .is = "joe" },
        .audience = .{ .is = "client-1" },
        .now_s = 1_300_000_000,
    }));
    const claims = try verify(RfcClaims, arena.allocator(), vector.es256_token, .{
        .keys = &keys,
        .issuer = .{ .is = "joe" },
        .audience = .unchecked,
        .now_s = 1_300_000_000,
    });
    try testing.expectEqualStrings("joe", claims.iss);
}

test "an issuer that is a value refuses another issuer's token, and .unchecked takes either" {
    var keys = try keySet();
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Claims = struct { sub: []const u8 };

    try testing.expectError(error.WrongIssuer, verify(Claims, arena.allocator(), vector.token, .{
        .keys = &keys,
        .issuer = .{ .is = "https://accounts.google.com" },
        .audience = .{ .is = "client-1" },
        .now_s = 1_500_000_000,
    }));
    _ = try verify(Claims, arena.allocator(), vector.token, .{
        .keys = &keys,
        .issuer = .unchecked,
        .audience = .{ .is = "client-1" },
        .now_s = 1_500_000_000,
    });
}

// ES384, over a key and a token made by another implementation (vector.zig).

const Issued = struct { iss: []const u8, sub: []const u8 };

fn issuedOpts(keys: *const jwks.Keys) Options {
    return .{
        .keys = keys,
        .issuer = .{ .is = "https://accounts.example" },
        .audience = .{ .is = "client-1" },
        .now_s = 1_500_000_000,
    };
}

test "an ES384 token verifies against the issuer's P-384 key, and the claims come back" {
    var keys = try jwks.parse(testing.allocator, vector.es384_jwks);
    defer keys.deinit();
    try testing.expectEqualStrings("ES384", keys.all[0].algorithm());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const claims = try verify(Issued, arena.allocator(), vector.es384_token, issuedOpts(&keys));
    try testing.expectEqualStrings("u-7", claims.sub);

    // The registered claims are the module's business under this key too.
    var late = issuedOpts(&keys);
    late.now_s = 2_000_000_001;
    try testing.expectError(error.Expired, verify(Issued, arena.allocator(), vector.es384_token, late));
}

test "a tampered ES384 token is a bad signature, in the payload or in the signature" {
    var keys = try jwks.parse(testing.allocator, vector.es384_jwks);
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bad_payload = try a.dupe(u8, vector.es384_token);
    const at = std.mem.indexOfScalar(u8, bad_payload, '.').? + 1;
    bad_payload[at] = if (bad_payload[at] == 'A') 'B' else 'A';
    try testing.expectError(error.BadSignature, verify(Issued, a, bad_payload, issuedOpts(&keys)));

    // A byte in the middle of r, past the last character that carries slack
    // bits, so the change is in the integer and not in the padding.
    const bad_sig = try a.dupe(u8, vector.es384_token);
    const sig_at = std.mem.lastIndexOfScalar(u8, bad_sig, '.').? + 20;
    bad_sig[sig_at] = if (bad_sig[sig_at] == 'A') 'B' else 'A';
    try testing.expectError(error.BadSignature, verify(Issued, a, bad_sig, issuedOpts(&keys)));
}

test "an ES384 signature sent as DER is refused by its length" {
    var keys = try jwks.parse(testing.allocator, vector.es384_jwks);
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const der = vector.es384_header ++ "." ++ vector.es384_payload ++ "." ++ vector.es384_signature_der;
    try testing.expectError(error.SignatureWrongLength, verify(Issued, arena.allocator(), der, issuedOpts(&keys)));
}

test "ES384 and ES256 each refuse the other's key, by the curve" {
    // The RFC's P-256 key, given the `kid` the ES384 token names, so that
    // the `kid` finds it and it is the `alg` that is being tested.
    var p256 = try jwks.parse(testing.allocator,
        "{\"keys\":[{\"kty\":\"EC\",\"crv\":\"P-256\",\"kid\":\"es384-key\",\"x\":\"" ++ vector.es256_x ++ "\",\"y\":\"" ++ vector.es256_y ++ "\"}]}");
    defer p256.deinit();
    var p384 = try jwks.parse(testing.allocator, vector.es384_jwks);
    defer p384.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An ES384 token pointed at the P-256 key, and the RFC's ES256 token (which
    // names no `kid`, so the one key answers) at the P-384 one.
    // Both are a mismatch before any arithmetic, not a bad signature.
    try testing.expectError(error.WrongAlgorithm, verify(Issued, a, vector.es384_token, .{
        .keys = &p256,
        .now_s = 1_300_000_000,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));
    try testing.expectError(error.WrongAlgorithm, verify(RfcClaims, a, vector.es256_token, .{
        .keys = &p384,
        .now_s = 1_300_000_000,
        .issuer = .unchecked,
        .audience = .unchecked,
    }));
}

// EdDSA over Ed25519, RFC 8037.

test "an EdDSA token verifies against the issuer's Ed25519 key, and the claims come back" {
    var keys = try jwks.parse(testing.allocator, vector.eddsa_jwks);
    defer keys.deinit();
    try testing.expectEqualStrings("EdDSA", keys.all[0].algorithm());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const claims = try verify(Issued, arena.allocator(), vector.eddsa_token, issuedOpts(&keys));
    try testing.expectEqualStrings("https://accounts.example", claims.iss);
    try testing.expectEqualStrings("u-7", claims.sub);
}

test "a tampered EdDSA token is a bad signature, in the payload or in the signature" {
    var keys = try jwks.parse(testing.allocator, vector.eddsa_jwks);
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bad_payload = try a.dupe(u8, vector.eddsa_token);
    const at = std.mem.indexOfScalar(u8, bad_payload, '.').? + 1;
    bad_payload[at] = if (bad_payload[at] == 'A') 'B' else 'A';
    try testing.expectError(error.BadSignature, verify(Issued, a, bad_payload, issuedOpts(&keys)));

    const bad_sig = try a.dupe(u8, vector.eddsa_token);
    const sig_at = std.mem.lastIndexOfScalar(u8, bad_sig, '.').? + 10;
    bad_sig[sig_at] = if (bad_sig[sig_at] == 'A') 'B' else 'A';
    try testing.expectError(error.BadSignature, verify(Issued, a, bad_sig, issuedOpts(&keys)));
}

test "an EdDSA header over an EC key, and an ES384 header over an Ed25519 key, are mismatches" {
    var ed = try jwks.parse(testing.allocator, vector.eddsa_jwks);
    defer ed.deinit();
    var p384 = try jwks.parse(testing.allocator, vector.es384_jwks);
    defer p384.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // {"alg":"EdDSA","kid":"es384-key"} over the P-384 key, with the Ed25519
    // token's own signature, and {"alg":"ES384","kid":"ed25519-key"} the
    // other way round.
    const eddsa_over_ec = "eyJhbGciOiJFZERTQSIsImtpZCI6ImVzMzg0LWtleSJ9." ++ vector.eddsa_payload ++ "." ++ vector.eddsa_signature;
    try testing.expectError(error.WrongAlgorithm, verify(Issued, a, eddsa_over_ec, issuedOpts(&p384)));
    const es384_over_okp = "eyJhbGciOiJFUzM4NCIsImtpZCI6ImVkMjU1MTkta2V5In0." ++ vector.es384_payload ++ "." ++ vector.es384_signature;
    try testing.expectError(error.WrongAlgorithm, verify(Issued, a, es384_over_okp, issuedOpts(&ed)));
}

test "a key on a curve with no branch is refused by name under any algorithm, Ed448 and P-521 alike" {
    var keys = try jwks.parse(testing.allocator,
        \\{"keys":[
        \\  {"kty":"OKP","crv":"Ed448","kid":"ed448","x":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"},
        \\  {"kty":"EC","crv":"P-521","kid":"p521","x":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","y":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"}
        \\]}
    );
    defer keys.deinit();

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // {"alg":"EdDSA","kid":"ed448"} and {"alg":"ES256","kid":"p521"}: the
    // honest names for these keys' neighbours, and still CurveNotSupported.
    const ed448 = "eyJhbGciOiJFZERTQSIsImtpZCI6ImVkNDQ4In0." ++ vector.eddsa_payload ++ "." ++ vector.eddsa_signature;
    try testing.expectError(error.CurveNotSupported, verify(Issued, a, ed448, issuedOpts(&keys)));
    const p521 = "eyJhbGciOiJFUzI1NiIsImtpZCI6InA1MjEifQ." ++ vector.es384_payload ++ "." ++ vector.es384_signature;
    try testing.expectError(error.CurveNotSupported, verify(Issued, a, p521, issuedOpts(&keys)));
}
