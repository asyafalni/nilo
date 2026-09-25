//! `"*"` borrowed from a CORS list, where it means a public API. Here it
//! would trust every page on the web, which is no check at all.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.csrf.with(.{ .origins = &.{"*"} })) catch {};
}
