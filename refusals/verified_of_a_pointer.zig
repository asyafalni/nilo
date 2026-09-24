//! `nilo.Verified(*Google)`, written the way a service argument is. The
//! argument names the type and nilo looks the service up, so the pointer is
//! one character too many
//! ([ADR 191](../docs/adr/191-verified-claims-are-a-handler-argument.md)).

const nilo = @import("nilo_http");

const Claims = struct { sub: []const u8 };

const Google = struct {
    pub const nilo_verifier = Claims;
    pub fn verify(self: *Google, gpa: anytype, token: []const u8, now_s: i64, scope: anytype) !Claims {
        _ = .{ self, gpa, token, now_s, scope };
        return .{ .sub = "" };
    }
};

fn me(user: nilo.Verified(*Google)) !void {
    _ = user;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/me", me) catch {};
}
