//! `session_token_max` sizes a stack buffer, and a presigned URL's query is
//! built in a buffer sized for the 2,048-byte token AWS documents. A bucket
//! asking for more would panic `presign` on a long enough token, so it is
//! refused while compiling.

const s3 = @import("nilo_s3");

export fn refusal() void {
    const Sts = s3.Bucket("sts", .{ .session_token_max = 4096 });
    _ = Sts;
}
