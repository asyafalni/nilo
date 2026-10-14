//! A decision that is not given the origin last. `cors.deciding` passes the
//! request's `Origin` as text after the services.

const nilo = @import("nilo_http");

const Sites = struct {};

fn allows(sites: *Sites) bool {
    _ = sites;
    return true;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.cors.deciding(allows, .{})) catch {};
}
