//! The origin `null`, which a sandboxed frame or a `file:` page sends. Any
//! site can make one, so a list that trusts it trusts every site.

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.cors.with(.{ .origins = &.{ "https://example.com", "null" }, .credentials = true })) catch {};
}
