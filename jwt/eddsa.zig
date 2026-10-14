//! EdDSA over Ed25519 — `alg: "EdDSA"` — over a public key given as the one
//! coordinate an `OKP` JWK carries (RFC 8037).
//!
//! **Everything hard here is `std.crypto.sign.Ed25519`'s**: `PublicKey.fromBytes`
//! and `Signature.verify`. What this adds is the three refusals in front of
//! it (the curve, the key length, the signature length), because "verified"
//! and "did not check" have to be different answers
//! ([ADR 111](../docs/adr/111-nilo-verifies-a-token-and-does-not-fetch-one.md)).
//!
//! **An OKP key is one string, not two.** `x` is the whole public key, thirty-
//! two bytes, where an EC key has an `x` and a `y` to join into a SEC1
//! point. And `crv` is the only thing that says which OKP algorithm this is:
//! `Ed25519` is verified here, while `Ed448` (std has none) and `X25519`
//! (a key agreement, not a signature) are `error.CurveNotSupported`.
//!
//! **The signature is the sixty-four bytes Ed25519 already has**, `R || S`,
//! and a JWS carries them as they are. No DER anywhere, so the failure
//! `es256.zig` guards against does not exist here; a signature of any other
//! length is `error.SignatureWrongLength`.
//!
//! **There is no hash to choose.** Ed25519 hashes inside the scheme, so
//! `alg` is the single name `EdDSA`, and the curve in the key is what
//! tells Ed25519 from Ed448.

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;

pub const Error = error{
    /// The key's `crv` is not `Ed25519`.
    CurveNotSupported,
    /// The signature is not sixty-four bytes.
    SignatureWrongLength,
    /// `x` is not thirty-two bytes, or is not the encoding of a point.
    KeyNotUsable,
    /// The key is fine, the signature is not the signature of this message.
    BadSignature,
};

/// The one curve this file has a branch for. A `crv` that is not on this
/// list is `error.CurveNotSupported`.
pub const curves = [_][]const u8{"Ed25519"};

/// The public key, in bytes.
pub const key_len = Ed25519.PublicKey.encoded_length;

/// `R || S`.
pub const signature_len = Ed25519.Signature.encoded_length;

/// `signed` is the first two segments of the token with the dot still between
/// them. `crv` and `x` are the key's, exactly as they come out of a JWKS
/// after base64url.
pub fn verify(signed: []const u8, sig: []const u8, crv: []const u8, x: []const u8) Error!void {
    if (!std.mem.eql(u8, crv, curves[0])) return error.CurveNotSupported;
    if (x.len != key_len) return error.KeyNotUsable;
    if (sig.len != signature_len) return error.SignatureWrongLength;

    const key = Ed25519.PublicKey.fromBytes(x[0..key_len].*) catch return error.KeyNotUsable;
    const signature = Ed25519.Signature.fromBytes(sig[0..signature_len].*);
    // Every way this can fail is a signature that is not this key's over
    // these bytes: a small-order key and an S past the group order are
    // refused as signatures that could not have been made.
    signature.verify(signed, key) catch return error.BadSignature;
}

const testing = std.testing;
const b64 = @import("b64.zig");
const vector = @import("vector.zig");

test "a curve with no branch is refused rather than guessed" {
    const x = @as([32]u8, @splat(0x01));
    const sig = @as([64]u8, @splat(0));
    try testing.expectError(error.CurveNotSupported, verify("a.b", &sig, "Ed448", &x));
    try testing.expectError(error.CurveNotSupported, verify("a.b", &sig, "X25519", &x));
}

test "a signature that is not sixty-four bytes is refused by its length" {
    const x = @as([32]u8, @splat(0x01));
    const short = @as([63]u8, @splat(0));
    try testing.expectError(error.SignatureWrongLength, verify("a.b", &short, "Ed25519", &x));
}

test "a key that is not thirty-two bytes is not a key" {
    const short = @as([31]u8, @splat(0x01));
    const sig = @as([64]u8, @splat(0));
    try testing.expectError(error.KeyNotUsable, verify("a.b", &sig, "Ed25519", &short));
}

test "RFC 8037 Appendix A.4's own example verifies here, and one bit off does not" {
    const gpa = testing.allocator;
    const x = try b64.keep(gpa, vector.rfc8037_x);
    defer gpa.free(x);
    const sig = try b64.keep(gpa, vector.rfc8037_signature);
    defer gpa.free(sig);

    const signed = vector.rfc8037_header ++ "." ++ vector.rfc8037_payload;
    try verify(signed, sig, "Ed25519", x);

    sig[10] ^= 0x01;
    try testing.expectError(error.BadSignature, verify(signed, sig, "Ed25519", x));
}

test "a signature made by std round-trips" {
    const pair = Ed25519.KeyPair.generateDeterministic(@as([32]u8, @splat(7))) catch unreachable;
    const signed = "header.payload";
    const sig = (pair.sign(signed, null) catch unreachable).toBytes();
    try verify(signed, &sig, "Ed25519", &pair.public_key.toBytes());
}

test "an all-zero signature is a bad signature rather than a crash" {
    const gpa = testing.allocator;
    const x = try b64.keep(gpa, vector.rfc8037_x);
    defer gpa.free(x);
    const zeros = @as([64]u8, @splat(0));
    try testing.expectError(error.BadSignature, verify("a.b", &zeros, "Ed25519", x));
}
