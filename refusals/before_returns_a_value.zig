//! Work registered with `app.before` that answers with a value. It runs
//! inside `listen()`, where nobody is waiting for one: an error stops the
//! boot, and anything else has nowhere to go (ADR 0220).

const nilo = @import("nilo_http");

fn countRows(run: *nilo.Run) !usize {
    _ = run;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.before(countRows, .{}) catch {};
}
