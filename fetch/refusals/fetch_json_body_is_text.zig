//! A body already encoded as JSON, handed to `postJson`. `std.json` would
//! write it out as one JSON *string* — `"{\"amount\":500}"`, quotes and
//! escapes and all — and the far end would answer 400 to a body that looked
//! right in the editor. A body already encoded goes through `post`.

const fetch = @import("nilo_fetch");
const core = @import("nilo_core");

export fn refusal() void {
    var client: fetch.Client = undefined;
    var run: core.Run = undefined;
    _ = client.postJson(&run, "https://api.example.com/v1/charges", "{\"amount\":500}", .{}) catch {};
}
