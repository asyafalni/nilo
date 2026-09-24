//! `nilo.Text(.{})`: no bound and no check, which is a `Str` under a longer
//! name. Refused so that the type keeps meaning "text with a shape"
//! ([ADR 193](../docs/adr/193-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md)).

const nilo = @import("nilo_http");

const SignUp = struct {
    nickname: nilo.Text(.{}),
};

fn signUp(in: nilo.Form(SignUp)) !void {
    _ = in;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
