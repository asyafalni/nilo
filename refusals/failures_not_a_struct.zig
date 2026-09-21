//! `app.failures` handed an enum of error codes. The shape of a failure body
//! is a struct whose fields are the JSON — a status and a sentence have to
//! land in fields, and an enum has none.

const nilo = @import("nilo_http");

const Kind = enum { not_found, bad_request, internal };

export fn refusal() void {
    var app: nilo.App = undefined;
    app.failures(Kind) catch {};
}
