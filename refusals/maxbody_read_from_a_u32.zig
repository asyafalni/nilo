//! A body limit read from configuration, kept in a `u32` because that is what
//! the settings struct had. `maxBody` reads a `usize` through the pointer, and
//! taking any other width would mean converting on every request for a number
//! that has one natural type already: the one `listen()`'s `max_body` is.

const nilo = @import("nilo_http");

var limit: u32 = 16 << 20;

export fn refusal() void {
    var app: nilo.App = undefined;
    app.use(nilo.maxBody(&limit)) catch {};
}
