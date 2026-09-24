//! A version on nothing: there is no body for the client to hold, so there
//! is nothing for the tag to name
//! ([ADR 189](../docs/adr/189-a-version-a-handler-names-is-an-etag.md)).

const nilo = @import("nilo_http");

fn touch() nilo.Versioned(void) {
    return .{ .version = 1, .value = {} };
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/orders", touch) catch {};
}
