//! `nilo.Verified(Claims)` with the claims struct where the Verifier goes.
//! The argument names the Service that holds the ring, the client and the
//! claims type, and the message says where the struct belongs
//! ([ADR 0260](../docs/adr/0260-verified-claims-are-a-handler-argument.md)).

const nilo = @import("nilo_http");

const Claims = struct { sub: []const u8 };

fn me(user: nilo.Verified(Claims)) !void {
    _ = user;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/me", me) catch {};
}
