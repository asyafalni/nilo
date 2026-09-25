//! An origin written as a URL. A browser's `Origin` has no path, not even a
//! trailing slash, so this one matches nothing and the browser refuses the
//! response without saying why.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.cors.with(.{ .origins = &.{"https://example.com/"} })) catch {};
}
