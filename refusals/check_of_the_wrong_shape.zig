//! A `nilo_check` that takes only the value and no rules to write into. It
//! has nowhere to put what did not hold, so the shape is refused with the one
//! that works
//! ([ADR 0264](../docs/adr/0264-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md)).

const nilo = @import("nilo_http");

const SignUp = struct {
    password: nilo.Str,
    confirm: nilo.Str,

    pub fn nilo_check(self: SignUp) bool {
        return self.password.eql(self.confirm.view());
    }
};

fn signUp(in: nilo.Form(SignUp)) !void {
    _ = in;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/sign-up", signUp) catch {};
}
