//! A JWKS document read into the keys nilo can actually verify with.
//!
//! **nilo parses a key set and does not fetch one.** The fetch is an HTTPS GET
//! and `nilo_fetch` already sends those; the cache is `nilo_cache`; the
//! refresh policy — how long a key set is good for, what to do when a `kid`
//! misses — is the caller's, the way every other policy here is. What a
//! caller *cannot* already write safely is the rest of this module, and
//! ADR 111 is where that line is argued.
//!
//! Three key types are read: `RSA`, as `n` and `e`; `EC`, as `crv`, `x` and
//! `y`; and `OKP`, as `crv` and `x` (RFC 8037). **The key is what decides how
//! a token is checked**: `token.zig` picks RS256, ES256, ES384 or EdDSA from
//! the key it found (its type, and its curve for the last three), never from
//! the token's `alg` (ADR 111). A key set usually carries keys this cannot
//! use, such as a symmetric `oct` key or one marked `"use": "enc"`. Those
//! are **skipped rather than refused**: a document nilo cannot fully read is
//! still a document with the right key in it, and an issuer adding a key type
//! is not a reason to stop signing people in.

const std = @import("std");
const b64 = @import("b64.zig");

pub const Error = error{
    /// The bytes are not a JSON object with a `keys` array in it.
    NotAKeySet,
    /// A key said RSA and then did not carry `n` and `e` as base64url, or
    /// said EC and did not carry `crv`, `x` and `y`, or said OKP and did not
    /// carry `crv` and `x`.
    KeyNotUsable,
    OutOfMemory,
};

/// One public key out of a key set, with what it is made of already decoded.
/// `kid` is borrowed from nothing — like the integers, it is owned by the
/// `Keys` that holds it.
pub const Key = struct {
    kid: []const u8,
    material: Material,

    /// What the key is made of, and so which algorithm a token signed with it
    /// has to have used.
    pub const Material = union(enum) {
        rsa: Rsa,
        ec: Ec,
        okp: Okp,
    };

    pub const Rsa = struct {
        /// The exponent, big-endian. `AQAB` — 65537 — for essentially every
        /// key in the world.
        e: []const u8,
        /// The modulus, big-endian.
        n: []const u8,
    };

    pub const Ec = struct {
        /// The curve's JWA name, `P-256` or `P-384` for the two that have a
        /// branch. Kept
        /// as text so that a curve nilo has no branch for is refused by name
        /// at `verify` rather than skipped here and reported as a missing
        /// key.
        crv: []const u8,
        /// The two affine coordinates, big-endian, each the curve's width.
        x: []const u8,
        y: []const u8,
    };

    pub const Okp = struct {
        /// The curve's JWA name, `Ed25519` for the one that has a branch.
        /// Kept as text for the reason `Ec.crv` is: `Ed448` and `X25519`
        /// are refused by name at `verify`, not lost at parse.
        crv: []const u8,
        /// The whole public key, which is one string where an EC key has two.
        x: []const u8,
    };

    /// The `alg` a token signed with this key has to say. The comparison in
    /// `token.zig` runs this way round: the key decides, the header agrees.
    /// A key on a curve with no branch answers to nothing, and is `""`;
    /// `token.zig` refuses it by name (`CurveNotSupported`) before it asks.
    pub fn algorithm(self: Key) []const u8 {
        return switch (self.material) {
            .rsa => "RS256",
            .ec => |ec| curveAlgorithm("EC", ec.crv),
            .okp => |okp| curveAlgorithm("OKP", okp.crv),
        };
    }

    /// Whether the key's curve is one that has a branch. An RSA key has no
    /// curve, so it always is.
    pub fn curveSupported(self: Key) bool {
        return switch (self.material) {
            .rsa => true,
            .ec, .okp => self.algorithm().len != 0,
        };
    }
};

/// The curves that have a branch, with the key type each belongs to and the
/// `alg` a token under it says. **The one table**: `algorithm()`, the
/// skipping of a key whose own `alg` is another, and `jwt.curves` all read
/// it, so a curve is added in one line here and one file beside `es256.zig`.
pub const supported = [_]struct { kty: []const u8, crv: []const u8, alg: []const u8 }{
    .{ .kty = "EC", .crv = "P-256", .alg = "ES256" },
    .{ .kty = "EC", .crv = "P-384", .alg = "ES384" },
    .{ .kty = "OKP", .crv = "Ed25519", .alg = "EdDSA" },
};

fn curveAlgorithm(kty: []const u8, crv: []const u8) []const u8 {
    for (supported) |s| {
        if (std.mem.eql(u8, s.kty, kty) and std.mem.eql(u8, s.crv, crv)) return s.alg;
    }
    return "";
}

/// Whether `alg` is a name some curve of key type `kty` answers to. A key
/// that says an `alg` outside these is for something else (`ES512`, say) and
/// is skipped, where one on an unknown curve that says nothing is kept.
fn answersTo(kty: []const u8, alg: []const u8) bool {
    for (supported) |s| {
        if (std.mem.eql(u8, s.kty, kty) and std.mem.eql(u8, s.alg, alg)) return true;
    }
    return false;
}

/// The keys of one document, owned together. `deinit` frees the lot.
pub const Keys = struct {
    all: []const Key,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Keys) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The key a token's `kid` names. A key set with exactly one key answers
    /// for a token that named no `kid` at all, which is what a single-key
    /// issuer's tokens look like; a set with more than one does not guess.
    pub fn find(self: *const Keys, kid: ?[]const u8) ?Key {
        if (kid) |want| {
            for (self.all) |key| {
                if (std.mem.eql(u8, key.kid, want)) return key;
            }
            return null;
        }
        if (self.all.len == 1) return self.all[0];
        return null;
    }
};

/// What `std.json` is asked for. Every field is optional because a key set is
/// somebody else's document and the fields nilo does not use are the ones
/// most likely to be missing or to be a shape nilo did not expect.
const Document = struct {
    keys: []const Entry = &.{},

    const Entry = struct {
        kty: ?[]const u8 = null,
        alg: ?[]const u8 = null,
        use: ?[]const u8 = null,
        kid: ?[]const u8 = null,
        n: ?[]const u8 = null,
        e: ?[]const u8 = null,
        crv: ?[]const u8 = null,
        x: ?[]const u8 = null,
        y: ?[]const u8 = null,
    };
};

/// Read a JWKS document. The result owns its own memory and outlives `bytes`.
pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) Error!Keys {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    // `.alloc_always`, because the default for a slice is to point a string
    // with no escapes in it back into `bytes` — and `kid` and `crv` are read
    // as text. The caller's `bytes` are a response body that is gone by the
    // first `find`; the promise below is that nothing here still points at
    // them.
    const doc = std.json.parseFromSliceLeaky(Document, alloc, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotAKeySet,
    };

    var kept: std.ArrayList(Key) = .empty;
    for (doc.keys) |entry| {
        // Anything that is not a signing key of a type read here is another
        // key in the same document, not a malformed one.
        const kty = entry.kty orelse continue;
        if (entry.use) |use| if (!std.mem.eql(u8, use, "sig")) continue;

        const material: Key.Material = if (std.mem.eql(u8, kty, "RSA")) rsa: {
            if (entry.alg) |alg| if (!std.mem.eql(u8, alg, "RS256")) continue;

            // Past here it *said* it was an RSA signing key, so a missing or
            // unreadable integer is the document being wrong rather than a
            // key nilo does not handle.
            const n_text = entry.n orelse return error.KeyNotUsable;
            const e_text = entry.e orelse return error.KeyNotUsable;
            break :rsa Key.Material{ .rsa = .{
                .e = try decode(alloc, e_text),
                .n = try decode(alloc, n_text),
            } };
        } else if (std.mem.eql(u8, kty, "EC")) ec: {
            if (entry.alg) |alg| if (!answersTo("EC", alg)) continue;

            // The same bargain: it said EC, so it owes a curve and a point.
            // Which curve is not checked here — a curve with no branch is
            // `verify`'s refusal, by name, rather than a key that went
            // missing.
            const crv = entry.crv orelse return error.KeyNotUsable;
            const x_text = entry.x orelse return error.KeyNotUsable;
            const y_text = entry.y orelse return error.KeyNotUsable;
            break :ec Key.Material{ .ec = .{
                .crv = crv,
                .x = try decode(alloc, x_text),
                .y = try decode(alloc, y_text),
            } };
        } else if (std.mem.eql(u8, kty, "OKP")) okp: {
            if (entry.alg) |alg| if (!answersTo("OKP", alg)) continue;

            // The same bargain once more: it said OKP, so it owes a curve and
            // a key. `X25519` and `Ed448` are `verify`'s refusal.
            const crv = entry.crv orelse return error.KeyNotUsable;
            const x_text = entry.x orelse return error.KeyNotUsable;
            break :okp Key.Material{ .okp = .{
                .crv = crv,
                .x = try decode(alloc, x_text),
            } };
        } else continue;

        try kept.append(alloc, .{ .kid = entry.kid orelse "", .material = material });
    }

    return .{ .all = try kept.toOwnedSlice(alloc), .arena = arena };
}

/// base64url out of the document into the arena; a segment that is not
/// base64url is the document being wrong.
fn decode(alloc: std.mem.Allocator, text: []const u8) Error![]u8 {
    return b64.keep(alloc, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotBase64Url => return error.KeyNotUsable,
    };
}

const testing = std.testing;

test "a key of a type nilo does not read, beside an RSA one, is skipped and not refused" {
    var keys = try parse(testing.allocator,
        \\{"keys":[
        \\  {"kty":"oct","kid":"secret","k":"aaaa"},
        \\  {"kty":"RSA","alg":"RS256","use":"sig","kid":"rsa","n":"-_8","e":"AQAB"}
        \\]}
    );
    defer keys.deinit();

    try testing.expectEqual(@as(usize, 1), keys.all.len);
    try testing.expectEqualStrings("rsa", keys.all[0].kid);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x01 }, keys.all[0].material.rsa.e);
}

test "an EC key is read as one, with its curve and both coordinates" {
    var keys = try parse(testing.allocator,
        \\{"keys":[
        \\  {"kty":"EC","crv":"P-256","use":"sig","kid":"ec","x":"-_8","y":"AQAB"},
        \\  {"kty":"RSA","kid":"rsa","n":"-_8","e":"AQAB"}
        \\]}
    );
    defer keys.deinit();

    try testing.expectEqual(@as(usize, 2), keys.all.len);
    const ec = keys.find("ec").?;
    try testing.expectEqualStrings("ES256", ec.algorithm());
    try testing.expectEqualStrings("P-256", ec.material.ec.crv);
    try testing.expectEqualSlices(u8, &.{ 0xfb, 0xff }, ec.material.ec.x);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x01 }, ec.material.ec.y);
    try testing.expectEqualStrings("RS256", keys.find("rsa").?.algorithm());
}

test "an EC key that says another algorithm, or is for encryption, is skipped" {
    var keys = try parse(testing.allocator,
        \\{"keys":[
        \\  {"kty":"EC","crv":"P-521","alg":"ES512","kid":"p521","x":"-_8","y":"AQAB"},
        \\  {"kty":"EC","crv":"P-256","use":"enc","kid":"enc","x":"-_8","y":"AQAB"},
        \\  {"kty":"EC","crv":"P-256","kid":"sig","x":"-_8","y":"AQAB"}
        \\]}
    );
    defer keys.deinit();

    try testing.expectEqual(@as(usize, 1), keys.all.len);
    try testing.expectEqualStrings("sig", keys.all[0].kid);
}

test "an EC key on another curve with no alg is kept, so that verify can name it" {
    var keys = try parse(testing.allocator,
        \\{"keys":[{"kty":"EC","crv":"P-521","kid":"p521","x":"-_8","y":"AQAB"}]}
    );
    defer keys.deinit();

    try testing.expectEqual(@as(usize, 1), keys.all.len);
    try testing.expectEqualStrings("P-521", keys.all[0].material.ec.crv);
    try testing.expect(!keys.all[0].curveSupported());
    try testing.expectEqualStrings("", keys.all[0].algorithm());
}

test "a P-384 key answers to ES384 and an Ed25519 key to EdDSA, by their curve" {
    var keys = try parse(testing.allocator,
        \\{"keys":[
        \\  {"kty":"EC","crv":"P-384","alg":"ES384","kid":"p384","x":"-_8","y":"AQAB"},
        \\  {"kty":"EC","crv":"P-256","kid":"p256","x":"-_8","y":"AQAB"},
        \\  {"kty":"OKP","crv":"Ed25519","alg":"EdDSA","use":"sig","kid":"ed","x":"-_8"},
        \\  {"kty":"OKP","crv":"Ed448","kid":"ed448","x":"-_8"},
        \\  {"kty":"OKP","crv":"X25519","use":"enc","kid":"x25519","x":"-_8"},
        \\  {"kty":"OKP","crv":"Ed25519","alg":"ES256","kid":"liar","x":"-_8"}
        \\]}
    );
    defer keys.deinit();

    // The X25519 key is for encryption and the last claims an `alg` that is
    // not an OKP one; both are skipped.
    try testing.expectEqual(@as(usize, 4), keys.all.len);
    try testing.expectEqualStrings("ES384", keys.find("p384").?.algorithm());
    try testing.expectEqualStrings("ES256", keys.find("p256").?.algorithm());
    const ed = keys.find("ed").?;
    try testing.expectEqualStrings("EdDSA", ed.algorithm());
    try testing.expectEqualStrings("Ed25519", ed.material.okp.crv);
    try testing.expectEqualSlices(u8, &.{ 0xfb, 0xff }, ed.material.okp.x);
    // Ed448 is kept so that `verify` can refuse it by name.
    try testing.expect(!keys.find("ed448").?.curveSupported());
}

test "an OKP key missing its curve or its key is the document being wrong" {
    try testing.expectError(error.KeyNotUsable, parse(testing.allocator,
        \\{"keys":[{"kty":"OKP","kid":"a","x":"-_8"}]}
    ));
    try testing.expectError(error.KeyNotUsable, parse(testing.allocator,
        \\{"keys":[{"kty":"OKP","crv":"Ed25519","kid":"a"}]}
    ));
}

test "a kid that is not in the set finds nothing" {
    var keys = try parse(testing.allocator,
        \\{"keys":[{"kty":"RSA","kid":"one","n":"-_8","e":"AQAB"}]}
    );
    defer keys.deinit();

    try testing.expect(keys.find("two") == null);
    try testing.expect(keys.find("one") != null);
}

test "one key answers for a token with no kid, and two do not" {
    var one = try parse(testing.allocator,
        \\{"keys":[{"kty":"RSA","kid":"a","n":"-_8","e":"AQAB"}]}
    );
    defer one.deinit();
    try testing.expect(one.find(null) != null);

    var two = try parse(testing.allocator,
        \\{"keys":[
        \\  {"kty":"RSA","kid":"a","n":"-_8","e":"AQAB"},
        \\  {"kty":"EC","crv":"P-256","kid":"b","x":"-_8","y":"AQAB"}
        \\]}
    );
    defer two.deinit();
    try testing.expect(two.find(null) == null);
}

test "an RSA key with no modulus is the document being wrong" {
    try testing.expectError(error.KeyNotUsable, parse(testing.allocator,
        \\{"keys":[{"kty":"RSA","kid":"a","e":"AQAB"}]}
    ));
}

test "an EC key missing a coordinate or its curve is the document being wrong" {
    try testing.expectError(error.KeyNotUsable, parse(testing.allocator,
        \\{"keys":[{"kty":"EC","crv":"P-256","kid":"a","x":"-_8"}]}
    ));
    try testing.expectError(error.KeyNotUsable, parse(testing.allocator,
        \\{"keys":[{"kty":"EC","crv":"P-256","kid":"a","y":"-_8"}]}
    ));
    try testing.expectError(error.KeyNotUsable, parse(testing.allocator,
        \\{"keys":[{"kty":"EC","kid":"a","x":"-_8","y":"AQAB"}]}
    ));
    // Standard base64 where base64url was owed.
    try testing.expectError(error.KeyNotUsable, parse(testing.allocator,
        \\{"keys":[{"kty":"EC","crv":"P-256","kid":"a","x":"+/8","y":"AQAB"}]}
    ));
}

test "the keys outlive the bytes they were read from" {
    const gpa = testing.allocator;
    const text =
        \\{"keys":[{"kty":"EC","crv":"P-256","kid":"rotated-1","x":"-_8","y":"AQAB"}]}
    ;
    const bytes = try gpa.dupe(u8, text);
    var keys = try parse(gpa, bytes);
    defer keys.deinit();

    // The response body this came out of is gone, and then some.
    @memset(bytes, 'x');
    gpa.free(bytes);

    const key = keys.find("rotated-1") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("rotated-1", key.kid);
    try testing.expectEqualStrings("P-256", key.material.ec.crv);
}

test "bytes that are not a key set at all" {
    try testing.expectError(error.NotAKeySet, parse(testing.allocator, "not json"));
}

test "a key set with no keys parses to nothing rather than failing" {
    var keys = try parse(testing.allocator, "{\"keys\":[]}");
    defer keys.deinit();
    try testing.expectEqual(@as(usize, 0), keys.all.len);
    try testing.expect(keys.find(null) == null);
}
