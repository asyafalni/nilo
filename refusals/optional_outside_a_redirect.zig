//! `?Redirect(303)`: a redirect is an answer the handler decided on, so there
//! is no body for the `?` to be missing. Nothing in the typed layer read
//! this shape, and the `Redirect` struct went out as JSON
//! ([ADR 203](../docs/adr/203-a-question-mark-goes-inside-the-wrapper.md)).

const nilo = @import("nilo_http");

fn open(id: u32) ?nilo.Redirect(303) {
    if (id == 0) return null;
    return .to("/orders");
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/open/:id", open) catch {};
}
