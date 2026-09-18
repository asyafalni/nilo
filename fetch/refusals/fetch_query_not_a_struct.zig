//! A query handed over as a number rather than a struct. There is no field
//! name to put in front of the `=`, so nothing here could become a query
//! string, and the mistake is refused at the call rather than sent as `?42`.

const fetch = @import("nilo_fetch");
const core = @import("nilo_core");

export fn refusal() void {
    var run: core.Run = undefined;
    _ = fetch.withQuery(&run, "https://api.example.com/search", 42) catch {};
}
