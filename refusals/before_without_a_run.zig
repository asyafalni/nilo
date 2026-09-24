//! Work registered with `app.before` whose first parameter is the service
//! rather than the boot's Run. The Run is nilo's to make — on the server's
//! loop, after the services — and the function has to have somewhere to
//! take it (ADR 180).

const nilo = @import("nilo_http");

const Db = struct { open: bool = false };

fn migrate(db: *Db) !void {
    db.open = true;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    var db: Db = .{};
    app.before(migrate, .{&db}) catch {};
}
