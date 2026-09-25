//! An empty entry in the trusted list, which no request's `Origin` is.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.csrf.with(.{ .origins = &.{""} })) catch {};
}
