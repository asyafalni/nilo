//! Work registered with `app.before` that is not a function. The App runs
//! it inside `listen()` on the server's loop, and there is nothing to run
//! in a value (ADR 0220).

const nilo = @import("nilo_http");

export fn refusal() void {
    var app: nilo.App = undefined;
    const migrated: bool = true;
    app.before(migrated, .{}) catch {};
}
