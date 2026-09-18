//! A token that is not a password: a password-reset link, an email
//! verification, an API key (ADR 0241).
//!
//! Every ordinary application has all three, and the recipe is the class of
//! thing that runs perfectly and is open: 32 bytes of entropy, base64url to
//! send, the **digest** stored rather than the token, a constant-time compare
//! when it comes back. What goes wrong in practice is the plaintext in the
//! table, `std.mem.eql` on the compare, or a UUID used as the token and kept
//! exactly as it was sent. This file is that recipe written once, so that a
//! handler writes three calls and none of the three mistakes:
//!
//! ```zig
//! // making one: send the text, store the digest, and keep nothing else
//! const token = pw.Token.new(try c.entropy(pw.token_len));
//! const digest = token.digest();
//! _ = try db.insert(Reset, c, .{ .user_id = user.id, .digest = sql.Bytes.of(&digest) });
//! try mail(user.email, &token.text());
//!
//! // checking one: the row is found by whoever the link was for
//! if (!pw.Token.matches(row.digest.bytes, presented)) return nilo.fail.unauthorized("…", .{});
//! ```
//!
//! ## No argon2, on purpose
//!
//! The salt-and-stretch machinery one file over is the wrong tool here, and
//! not by a little. Argon2 exists because a password has perhaps forty bits of
//! entropy and the stretching is what makes each guess cost 13 ms. A token has
//! 256 bits, and no number of guesses at 256 bits is a threat — the digest is
//! stored so that a copy of the table is not a set of working links, and
//! SHA-256 does that in a microsecond. Stretching it would buy nothing and
//! cost a reset endpoint that answers in 13 ms, which is a reset endpoint
//! that can be walked: an attacker holding the table's worth of links to try
//! gets each answer 10,000 times slower, and so does the server.
//!
//! ## Why the compare is constant-time when the digest already is a hash
//!
//! Strictly, comparing two SHA-256 digests with `std.mem.eql` leaks the
//! number of leading bytes of the *digest* an attacker has right, and an
//! attacker cannot choose a token whose digest has a given prefix any faster
//! than by trying tokens. So the early-exit compare is not the hole here. It
//! is constant-time anyway because the caller who stores the digest as a
//! column and looks it up by equality is fine, and the caller who reads
//! `matches` and copies its shape onto something that is *not* a hash — a
//! bearer token held in memory, say — should copy the right shape.
//!
//! ## What it will not do
//!
//! Store, expire, or spend. A reset row has an `expires_at` and a `used_at`,
//! and both are columns in the caller's table, because where a token lives is
//! the application's the way a password hash's row is (ADR 0048). What this
//! file settles is the three things that are the same in every application
//! and wrong in most: how wide, how sent, and how compared.
//!
//! Entropy arrives as an argument for the reason a salt does (ADR 0046): a
//! module in this layer has no Bulkhead to ask through, and being handed the
//! bytes is what keeps `zig test pw/pw.zig` running with no module graph.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const base64 = std.base64.url_safe_no_pad;

/// A random token, 32 bytes wide, that is sent in one form and stored in
/// another.
///
/// A value rather than a thing with a lifetime, for the reason a `Hash` and a
/// `Uuid` are: nothing to free, and the text goes straight into a mail and
/// the digest straight into an insert.
pub const Token = struct {
    _bytes: [len]u8,

    /// Bytes of entropy one is made from, and what to ask `Ctx.entropy` for.
    /// Fixed rather than chosen, because one width is what makes the text one
    /// length and lets `matches` refuse anything else before decoding it.
    pub const len = 32;

    /// Characters the text form takes: 32 bytes in base64url, no padding.
    pub const text_len = 43;

    /// Bytes the stored form takes: a SHA-256 digest.
    pub const digest_len = Sha256.digest_length;

    /// What is stored instead of the token.
    pub const Digest = [digest_len]u8;

    /// A token from randomness the caller brought — `try c.entropy(pw.token_len)`
    /// inside a request, `std.Io.randomSecure` outside one.
    ///
    /// **`entropy` has to be unguessable, and this cannot check that.** What
    /// it can check is the width, and it does so in its own words: sixteen
    /// bytes is what a UUID holds, and a UUID used as a reset token is the
    /// mistake ADR 0241 names.
    pub fn new(entropy: anytype) Token {
        comptime checkWidth(@TypeOf(entropy));
        return .{ ._bytes = entropy };
    }

    /// The token as it came back — from a link, a header, a form — or null if
    /// what came back is not one. Null rather than an error, and one null for
    /// every reason, because which way a presented token was wrong is not
    /// something to tell whoever presented it.
    ///
    /// For the lookup when the digest is the key: an API key arrives on its
    /// own, so the row is `db.one(ApiKey, c, .{ .where = .{ .digest = … } })`
    /// on `parse(header).?.digest()`, and the database does the compare. A
    /// reset link says who it is for, and there `matches` is the whole check.
    pub fn parse(presented: []const u8) ?Token {
        if (presented.len != text_len) return null;
        var out: Token = .{ ._bytes = undefined };
        base64.Decoder.decode(&out._bytes, presented) catch return null;
        return out;
    }

    /// The form to send: 43 characters of base64url, safe in a URL, a header
    /// and a mail without escaping. By value, so it fits in the expression
    /// that uses it and nothing is allocated.
    pub fn text(self: *const Token) [text_len]u8 {
        var out: [text_len]u8 = undefined;
        _ = base64.Encoder.encode(&out, &self._bytes);
        return out;
    }

    /// The form to store: SHA-256 over the 32 bytes. A copy of the table is
    /// then a list of digests and not a list of working links.
    pub fn digest(self: *const Token) Digest {
        var out: Digest = undefined;
        Sha256.hash(&self._bytes, &out, .{});
        return out;
    }

    /// Whether `presented` is the token `stored` is the digest of, in time
    /// that does not depend on where they first differ.
    ///
    /// `stored` is a slice rather than a `Digest` because that is what a
    /// `bytea` column hands back. **A stored value that is not 32 bytes is
    /// false** — which is what a table holding the 43-character text instead
    /// of the digest answers on every row, so that mistake fails closed and
    /// is found by the first test rather than by the first attacker.
    /// `presented` of the wrong length, or not base64url, is false the same
    /// way: one answer, whatever was wrong.
    pub fn matches(stored: []const u8, presented: []const u8) bool {
        const token = parse(presented) orelse return false;
        if (stored.len != digest_len) return false;
        return std.crypto.timing_safe.eql(Digest, token.digest(), stored[0..digest_len].*);
    }

    fn checkWidth(comptime T: type) void {
        comptime {
            const advice =
                "\n  Ask for `c.entropy(pw.token_len)` in a handler, or `std.Io.randomSecure`" ++
                " into a `[pw.token_len]u8` outside one.";
            switch (@typeInfo(T)) {
                .array => |a| {
                    if (a.child != u8) @compileError(
                        "nilo: a Token is made from 32 bytes of entropy, and what it was given is not bytes.\n" ++
                            "  It was given " ++ @typeName(T) ++ "." ++ advice,
                    );
                    if (a.len != len) @compileError(std.fmt.comptimePrint(
                        "nilo: a Token is made from {d} bytes of entropy and was given {d}.\n" ++
                            "  The width is fixed so that the text is one length and the digest is one\n" ++
                            "  length; sixteen bytes is what a UUID holds, and a UUID is a key rather\n" ++
                            "  than a secret.{s}",
                        .{ len, a.len, advice },
                    ));
                },
                else => @compileError(
                    "nilo: a Token is made from 32 bytes of entropy, and what it was given is not bytes.\n" ++
                        "  It was given " ++ @typeName(T) ++ "." ++ advice,
                ),
            }
        }
    }
};

const testing = std.testing;

/// Thirty-two bytes that are not random, for the tests below; a test is the
/// one place a token made from a constant is fine.
fn fixed(seed: u8) [Token.len]u8 {
    var out: [Token.len]u8 = undefined;
    for (&out, 0..) |*b, i| b.* = seed +% @as(u8, @intCast(i));
    return out;
}

test "the text is 43 characters of base64url and reads back to the same token" {
    const token = Token.new(fixed(1));
    const sent = token.text();
    try testing.expectEqual(@as(usize, 43), sent.len);
    for (sent) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_';
        try testing.expect(ok);
    }

    const back = Token.parse(&sent) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, &token._bytes, &back._bytes);
    const resent = back.text();
    try testing.expectEqualSlices(u8, &sent, &resent);
}

test "the digest is stable, and is not the token" {
    const bytes = fixed(2);
    const token = Token.new(bytes);
    const first = token.digest();
    const second = token.digest();
    try testing.expectEqualSlices(u8, &first, &second);
    try testing.expect(!std.mem.eql(u8, &first, &bytes));

    // SHA-256 and nothing else, so a digest written by another program over
    // the same bytes is the same column value.
    var want: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&bytes, &want, .{});
    try testing.expectEqualSlices(u8, &want, &first);
}

test "the text that was sent matches the digest that was stored" {
    const token = Token.new(fixed(3));
    const stored = token.digest();
    const sent = token.text();
    try testing.expect(Token.matches(&stored, &sent));
}

test "one character off is not the token" {
    const token = Token.new(fixed(4));
    const stored = token.digest();
    var sent = token.text();

    // Every position, so a flip anywhere — including in the last character,
    // where only four of its six bits are the token's — is refused.
    for (0..sent.len) |i| {
        const was = sent[i];
        sent[i] = if (was == 'A') 'B' else 'A';
        try testing.expect(!Token.matches(&stored, &sent));
        sent[i] = was;
    }
    try testing.expect(Token.matches(&stored, &sent));
}

test "the wrong length, garbage, and an empty string are all simply false" {
    const token = Token.new(fixed(5));
    const stored = token.digest();
    const sent = token.text();

    try testing.expect(!Token.matches(&stored, ""));
    try testing.expect(!Token.matches(&stored, sent[0..42]));

    var longer: [44]u8 = undefined;
    @memcpy(longer[0..43], &sent);
    longer[43] = 'A';
    try testing.expect(!Token.matches(&stored, &longer));

    const garbage = "not base64url at all, and 43 bytes long!!!!";
    try testing.expectEqual(@as(usize, 43), garbage.len);
    try testing.expect(!Token.matches(&stored, garbage));

    // Padding is not part of the form, so a padded spelling is not it either.
    var padded = sent;
    padded[42] = '=';
    try testing.expect(!Token.matches(&stored, &padded));

    try testing.expect(Token.parse("") == null);
    try testing.expect(Token.parse("ab") == null);
    try testing.expect(Token.parse(garbage) == null);
}

test "a table that stored the text instead of the digest matches nothing" {
    // The mistake the digest exists to prevent, and what it answers if it is
    // made anyway: false on every row, rather than open on every row.
    const token = Token.new(fixed(6));
    const sent = token.text();
    try testing.expect(!Token.matches(&sent, &sent));
    try testing.expect(!Token.matches("", &sent));
    try testing.expect(!Token.matches(sent[0..31], &sent));
}

test "two tokens never share a digest, and neither does the same entropy twice" {
    // Different entropy, different digest; the same entropy, the same one —
    // which is what lets a link be checked against a row written earlier.
    const a = Token.new(fixed(7));
    const b = Token.new(fixed(8));
    const again = Token.new(fixed(7));
    const a_digest = a.digest();
    const b_digest = b.digest();
    const again_digest = again.digest();
    const a_text = a.text();
    const b_text = b.text();
    try testing.expect(!std.mem.eql(u8, &a_digest, &b_digest));
    try testing.expectEqualSlices(u8, &a_digest, &again_digest);
    try testing.expect(!Token.matches(&a_digest, &b_text));
    try testing.expect(!Token.matches(&b_digest, &a_text));
}
