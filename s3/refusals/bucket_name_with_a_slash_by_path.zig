//! Path style puts the name into a URL path unencoded, and a slash would make
//! it two segments, so the bucket would be a different one. The same predicate
//! refuses it at run time in `openAs`.

const s3 = @import("nilo_s3");

export fn refusal() void {
    const Odd = s3.Bucket("tenants/a", .{ .style = .path });
    _ = Odd;
}
