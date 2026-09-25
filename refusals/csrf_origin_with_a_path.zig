//! A trailing slash, copied from the browser's address bar. A browser's
//! `Origin` never carries one, so the page it names would always be refused.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.csrf.with(.{ .origins = &.{"https://app.example.com/"} })) catch {};
}
