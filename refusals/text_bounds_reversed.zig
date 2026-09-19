//! `nilo.Text(.{ .min = 72, .max = 10 })`, the bounds the wrong way round.
//! Nothing is at least 72 and at most 10 characters, so the field could never
//! be filled and every request would be a 400
//! ([ADR 0264](../docs/adr/0264-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md)).

const nilo = @import("nilo_http");

const SignUp = struct {
    password: nilo.Text(.{ .min = 72, .max = 10 }),
};

fn signUp(in: nilo.Form(SignUp)) !void {
    _ = in;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
