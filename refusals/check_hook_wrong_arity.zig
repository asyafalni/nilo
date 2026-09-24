//! A `nilo_check` that takes no `Io`, so it could never make the Scope a
//! statement against the database needs
//! ([ADR 180](../docs/adr/180-work-that-needs-the-services-runs-on-their-loop.md)).

const nilo = @import("nilo_http");

const Ledger = struct {
    rows: u32,

    pub fn nilo_start(_: *Ledger, _: std.Io) !void {}

    pub fn nilo_check(self: *Ledger) !void {
        if (self.rows == 0) return error.Empty;
    }
};

const std = @import("std");

export fn refusal() void {
    var ledger = Ledger{ .rows = 0 };
    var app: nilo.App = undefined;
    app.provide(&ledger) catch {};
}
