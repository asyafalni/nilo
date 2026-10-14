//! ECDSA over P-384 with SHA-384 — ES384 — over a public key given as the
//! two coordinates a JWKS carries.
//!
//! **This is `es256.zig` over the next curve up, and it is the same twenty
//! lines on purpose** ([ADR 111](../docs/adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)).
//! Everything hard is `std.crypto.sign.ecdsa.EcdsaP384Sha384`'s: the key,
//! the signature and the arithmetic. What this adds is the three refusals in
//! front of it (the curve, the coordinate length, the signature length),
//! because "verified" and "did not check" have to be different answers.
//!
//! **A JWS signature is raw `r || s`, ninety-six bytes on P-384, and not
//! DER** (RFC 7518 §3.4): each integer is padded to the curve's width, forty
//! eight bytes here. The decoder is `Signature.fromBytes` and never
//! `fromDer`, so a DER signature, which is a hundred and three bytes or so,
//! arrives as `error.SignatureWrongLength`.
//!
//! **Which key type this is for is the key's business, not the token's.**
//! `token.zig` calls this because the key it found is `EC` on `P-384`, and
//! only after the header's `alg` has been compared against `ES384`.

const std = @import("std");
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP384Sha384;

pub const Error = error{
    /// The key's `crv` is not `P-384`. A curve with no branch is an error
    /// rather than a best effort, the way an RSA size with no branch is.
    CurveNotSupported,
    /// The signature is not ninety-six bytes, so it cannot be `r || s` on
    /// this curve. A DER signature lands here.
    SignatureWrongLength,
    /// A coordinate is not forty-eight bytes, or the two together are not a
    /// point on the curve.
    KeyNotUsable,
    /// The key is fine, the signature is not the signature of this message.
    BadSignature,
};

/// The one curve this file has a branch for. A `crv` that is not on this
/// list is `error.CurveNotSupported`.
pub const curves = [_][]const u8{"P-384"};

/// One coordinate of a P-384 point, in bytes. `x` and `y` are each this.
pub const coordinate_len = 48;

/// `r || s` on P-384: two coordinates' worth.
pub const signature_len = 2 * coordinate_len;

/// `signed` is the first two segments of the token with the dot still between
/// them — the bytes the issuer hashed. `crv`, `x` and `y` are the key's,
/// exactly as they come out of a JWKS after base64url.
pub fn verify(signed: []const u8, sig: []const u8, crv: []const u8, x: []const u8, y: []const u8) Error!void {
    if (!std.mem.eql(u8, crv, curves[0])) return error.CurveNotSupported;
    if (x.len != coordinate_len or y.len != coordinate_len) return error.KeyNotUsable;
    if (sig.len != signature_len) return error.SignatureWrongLength;

    // SEC1 uncompressed: 0x04, then x, then y. ninety-seven bytes on the
    // stack and nothing allocated.
    var sec1: [1 + 2 * coordinate_len]u8 = undefined;
    sec1[0] = 0x04;
    @memcpy(sec1[1 .. 1 + coordinate_len], x);
    @memcpy(sec1[1 + coordinate_len ..], y);
    const key = Ecdsa.PublicKey.fromSec1(&sec1) catch return error.KeyNotUsable;

    // `fromBytes`, not `fromDer` — see the header.
    const signature = Ecdsa.Signature.fromBytes(sig[0..signature_len].*);
    signature.verify(signed, key) catch |err| switch (err) {
        // An r or s of zero, or one past the group order, is a signature
        // that could not have been made; it is refused as one that was not.
        error.SignatureVerificationFailed,
        error.IdentityElement,
        error.NonCanonical,
        => return error.BadSignature,
    };
}

const testing = std.testing;
const b64 = @import("b64.zig");
const vector = @import("vector.zig");

test "a curve with no branch is refused rather than guessed" {
    // A P-256 key is thirty-two bytes a coordinate; the curve is refused
    // before the length is looked at.
    const x = @as([32]u8, @splat(0x01));
    const sig = @as([96]u8, @splat(0));
    try testing.expectError(error.CurveNotSupported, verify("a.b", &sig, "P-256", &x, &x));
    try testing.expectError(error.CurveNotSupported, verify("a.b", &sig, "P-521", &x, &x));
}

test "a signature that is not r || s on this curve is refused by its length" {
    const x = @as([48]u8, @splat(0x01));
    // The sixty-four bytes of an ES256 signature, and a DER-shaped one.
    const es256_sized = @as([64]u8, @splat(0));
    const der_shaped = @as([103]u8, @splat(0));
    try testing.expectError(error.SignatureWrongLength, verify("a.b", &es256_sized, "P-384", &x, &x));
    try testing.expectError(error.SignatureWrongLength, verify("a.b", &der_shaped, "P-384", &x, &x));
}

test "a coordinate that is not forty-eight bytes is not a key" {
    const short = @as([47]u8, @splat(0x01));
    const full = @as([48]u8, @splat(0x01));
    const sig = @as([96]u8, @splat(0));
    try testing.expectError(error.KeyNotUsable, verify("a.b", &sig, "P-384", &short, &full));
    try testing.expectError(error.KeyNotUsable, verify("a.b", &sig, "P-384", &full, &short));
}

test "two coordinates that are not a point on the curve are not a key" {
    const one = @as([47]u8, @splat(0)) ++ [_]u8{0x01};
    const sig = @as([96]u8, @splat(0x01));
    try testing.expectError(error.KeyNotUsable, verify("a.b", &sig, "P-384", &one, &one));
}

test "a P-384 signature made by another implementation verifies here, and one bit off does not" {
    const gpa = testing.allocator;
    const x = try b64.keep(gpa, vector.es384_x);
    defer gpa.free(x);
    const y = try b64.keep(gpa, vector.es384_y);
    defer gpa.free(y);
    const sig = try b64.keep(gpa, vector.es384_signature);
    defer gpa.free(sig);

    const signed = vector.es384_header ++ "." ++ vector.es384_payload;
    try verify(signed, sig, "P-384", x, y);

    sig[10] ^= 0x01;
    try testing.expectError(error.BadSignature, verify(signed, sig, "P-384", x, y));
}

test "a signature made by std over the same key round-trips, so the r || s layout is std's" {
    const pair = Ecdsa.KeyPair.generateDeterministic(@as([48]u8, @splat(7))) catch unreachable;
    const sec1 = pair.public_key.toUncompressedSec1();
    const signed = "header.payload";
    const sig = (pair.sign(signed, null) catch unreachable).toBytes();
    try verify(signed, &sig, "P-384", sec1[1..49], sec1[49..97]);
}

test "an r or s of zero is a bad signature rather than a crash" {
    const gpa = testing.allocator;
    const x = try b64.keep(gpa, vector.es384_x);
    defer gpa.free(x);
    const y = try b64.keep(gpa, vector.es384_y);
    defer gpa.free(y);

    const zeros = @as([96]u8, @splat(0));
    try testing.expectError(error.BadSignature, verify("a.b", &zeros, "P-384", x, y));
}
