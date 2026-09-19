//! A form field that is a list of something no form value can become. A
//! list of files is the one somebody will reach for — `<input type="file"
//! multiple>` — and it is refused by name rather than read as text, because
//! an `Upload` is a part and not a value.

const nilo = @import("nilo_http");

const Gallery = struct { photos: []const nilo.Upload = &.{} };

fn upload(incoming: nilo.Form(Gallery)) u32 {
    _ = incoming;
    return 0;
}

export fn refusal() void {
    var app: nilo.App = undefined;
    app.post("/gallery", upload) catch {};
}
