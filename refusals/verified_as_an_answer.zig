//! A `nilo.Verified(…)` in the return type. It is what a handler is given,
//! and answering with it would send the token back to the client along
//! with the claims
//! ([ADR 0260](../docs/adr/0260-verified-claims-are-a-handler-argument.md)).

const nilo = @import("nilo_http");

const Claims = struct { sub: []const u8 };

const Google = struct {
    pub const nilo_verifier = Claims;
    pub fn verify(self: *Google, gpa: anytype, token: []const u8, now_s: i64, scope: anytype) !Claims {
        _ = .{ self, gpa, token, now_s, scope };
        return .{ .sub = "" };
    }
};

fn me(user: nilo.Verified(Google)) nilo.Verified(Google) {
    return user;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/me", me) catch {};
}
