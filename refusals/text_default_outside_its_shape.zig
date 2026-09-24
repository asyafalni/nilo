//! `nilo.Text(.{ .max = 3 }) = .of("wati")`: a default the shape would refuse.
//! A default is the one value a request never sends, so it is the one the
//! shape would never catch — which is why `.of` checks it while compiling
//! ([ADR 193](../docs/adr/193-text-with-a-shape-is-a-type-and-a-rule-about-the-struct-is-a-function-on-it.md)).

const nilo = @import("nilo_http");

const Filter = struct {
    tag: nilo.Text(.{ .max = 3 }) = .of("wati"),
};

fn list(q: nilo.Query(Filter)) !void {
    _ = q;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.get("/items", list) catch {};
}
