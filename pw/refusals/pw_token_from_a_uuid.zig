//! A password-reset token made from a UUID. `id.v4` was already in the
//! program and sixteen random bytes looked like plenty, so its bytes went
//! in as the entropy. A Token is 32 bytes wide on purpose — one width is what
//! makes the text one length — and the sixteen a UUID holds are a key rather
//! than a secret.

const pw = @import("nilo_pw");

export fn refusal() void {
    const a_uuid: [16]u8 = @splat(0);
    const token = pw.Token.new(a_uuid);
    _ = token.text();
}
