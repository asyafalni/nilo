//! Reading a zstd answer, against a real loopback server (ADR 295).
//!
//! Its own root, built with `fetch_config.zstd` and `fetch_config.gzip` true
//! whatever `-Dfetch_zstd` and `-Dfetch_gzip` say, so the rest of the suite
//! stays the proof of the build a dependent gets by default.

const std = @import("std");
const core = @import("nilo_core");
const fetch = @import("fetch.zig");

const testing = std.testing;
const Canned = fetch.testing.Canned;

test {
    _ = @import("zstd_read.zig");
    _ = @import("decode.zig");
}

fn withIo(comptime body: fn (std.Io) anyerror!void) !void {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    try body(threaded.io());
}

fn started(io: std.Io) !fetch.Client {
    var client: fetch.Client = .init(testing.allocator, .{});
    try client.nilo_start(io, .none);
    return client;
}

/// Some JSON, `count` objects of it: compressible the way an API's answer is.
fn json(gpa: std.mem.Allocator, count: usize) ![]u8 {
    var built: std.Io.Writer.Allocating = .init(gpa);
    errdefer built.deinit();
    try built.writer.writeByte('[');
    for (0..count) |i| {
        if (i != 0) try built.writer.writeByte(',');
        try built.writer.print("{{\"id\":{d},\"name\":\"host-{d}\",\"state\":\"running\",\"labels\":[\"a\",\"b\"]}}", .{ i, i % 17 });
    }
    try built.writer.writeByte(']');
    return built.toOwnedSlice();
}

/// `canned` served once, and `call` made to it: the body, copied out, or the
/// error. The head of the request is in `canned` after.
fn get(io: std.Io, canned: *Canned, gpa: std.mem.Allocator, call: fetch.Client.Call) ![]u8 {
    var served = try io.concurrent(Canned.serveOne, .{canned});
    defer served.cancel(io) catch {};
    var client = try started(io);
    defer client.deinit();
    var scope: core.Run = .init(testing.allocator);
    defer scope.deinit();
    var buf: [64]u8 = undefined;
    const res = try client.get(&scope, try canned.url(&buf), call);
    return gpa.dupe(u8, res.body.view());
}

test "this root reads zstd and gzip" {
    try testing.expect(fetch.reads_zstd);
    try testing.expect(fetch.reads_gzip);
    try testing.expectEqualStrings("zstd, gzip, identity", fetch.accepted_encodings);
}

test "a server that zstds regardless of identity is read as plain bytes" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            const plain = try json(testing.allocator, 100);
            defer testing.allocator.free(plain);
            var wire: [16 << 10]u8 = undefined;

            var canned = try Canned.open(io);
            defer canned.close();
            try canned.replyZstd(&wire, "200 OK", "Content-Type: application/json\r\n", plain);
            try testing.expect(canned.body_len < plain.len / 4);

            const got = try get(io, &canned, testing.allocator, .{
                .headers = &.{.{ .name = "accept-encoding", .value = "identity" }},
            });
            defer testing.allocator.free(got);
            try testing.expectEqualStrings(plain, got);
        }
    }.run);
}

test "a call that says nothing about encodings advertises zstd before gzip and gets the body" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            const plain = try json(testing.allocator, 5000);
            defer testing.allocator.free(plain);
            const wire = try testing.allocator.alloc(u8, 256 << 10);
            defer testing.allocator.free(wire);

            var canned = try Canned.open(io);
            defer canned.close();
            try canned.replyZstd(wire, "200 OK", "", plain);

            const got = try get(io, &canned, testing.allocator, .{});
            defer testing.allocator.free(got);
            try testing.expectEqualStrings(plain, got);
            try testing.expect(std.mem.indexOf(u8, canned.request(), "accept-encoding: zstd, gzip, identity") != null);
        }
    }.run);
}

test "a gzip answer and a plain one are still read in a build that reads zstd too" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            const plain = try json(testing.allocator, 100);
            defer testing.allocator.free(plain);
            var wire: [16 << 10]u8 = undefined;

            var gz = try Canned.open(io);
            defer gz.close();
            try gz.replyGzip(&wire, "200 OK", "", plain);
            const from_gzip = try get(io, &gz, testing.allocator, .{});
            defer testing.allocator.free(from_gzip);
            try testing.expectEqualStrings(plain, from_gzip);

            var text = try Canned.open(io);
            defer text.close();
            text.reply("200 OK", "", "just text");
            const from_text = try get(io, &text, testing.allocator, .{});
            defer testing.allocator.free(from_text);
            try testing.expectEqualStrings("just text", from_text);
        }
    }.run);
}

test "an empty body under a zstd header is an empty answer" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.reply("200 OK", "Content-Encoding: zstd\r\n", "");
            const got = try get(io, &canned, testing.allocator, .{});
            defer testing.allocator.free(got);
            try testing.expectEqual(@as(usize, 0), got.len);
        }
    }.run);
}

test "max_body counts the decoded bytes, so a small zstd answer cannot inflate past it" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            // Eight megabytes of one letter is a few hundred bytes of zstd.
            const plain = try testing.allocator.alloc(u8, 8 << 20);
            defer testing.allocator.free(plain);
            @memset(plain, 'a');
            var wire: [16 << 10]u8 = undefined;

            var canned = try Canned.open(io);
            defer canned.close();
            try canned.replyZstd(&wire, "200 OK", "", plain);
            try testing.expect(canned.body_len < 1 << 10);

            try testing.expectError(error.BodyTooLarge, get(io, &canned, testing.allocator, .{ .max_body = 64 << 10 }));
        }
    }.run);
}

test "a body at the ceiling is read whole even when the wire was a thousand times smaller" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            const plain = try testing.allocator.alloc(u8, 1 << 20);
            defer testing.allocator.free(plain);
            @memset(plain, 'b');
            var wire: [16 << 10]u8 = undefined;

            var canned = try Canned.open(io);
            defer canned.close();
            try canned.replyZstd(&wire, "200 OK", "", plain);

            const got = try get(io, &canned, testing.allocator, .{ .max_body = 1 << 20 });
            defer testing.allocator.free(got);
            try testing.expectEqual(@as(usize, 1 << 20), got.len);
        }
    }.run);
}

test "bytes that are not zstd under a zstd header are an error that says so" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            var canned = try Canned.open(io);
            defer canned.close();
            canned.reply("200 OK", "Content-Encoding: zstd\r\n", "<html>an error page from a proxy</html>");
            try testing.expectError(error.BodyEncodingInvalid, get(io, &canned, testing.allocator, .{}));
        }
    }.run);
}

test "a corrupt zstd frame, one that stops early and one that asks for too much window are errors" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            const plain = try json(testing.allocator, 400);
            defer testing.allocator.free(plain);
            var wire: [16 << 10]u8 = undefined;

            for ([_]enum { flipped, cut, window }{ .flipped, .cut, .window }) |damage| {
                var canned = try Canned.open(io);
                defer canned.close();
                try canned.replyZstd(&wire, "200 OK", "", plain);
                switch (damage) {
                    // A byte in the middle of the frame: a block that no
                    // longer decodes, or a checksum that no longer matches.
                    .flipped => wire[canned.body_len / 2] ^= 0xff,
                    // The checksum and a little more gone, as a connection
                    // cut in the middle of a body would leave it.
                    .cut => canned.reply(canned.status, canned.headers, canned.body.?[0 .. canned.body_len - 12]),
                    // Magic, a frame header with no single segment flag, and a
                    // window descriptor of 2^27: more than the 8 MB every
                    // HTTP decoder is required to give and no more.
                    .window => canned.reply("200 OK", "Content-Encoding: zstd\r\n", &[_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x88, 0x01, 0x00, 0x00 }),
                }
                testing.expectError(error.BodyEncodingInvalid, get(io, &canned, testing.allocator, .{})) catch |err| {
                    std.debug.print("damage {s}\n", .{@tagName(damage)});
                    return err;
                };
            }
        }
    }.run);
}

test "readInto, stream and the reader of an Exchange all read the decoded body" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            const plain = try json(testing.allocator, 3000);
            defer testing.allocator.free(plain);
            const wire = try testing.allocator.alloc(u8, 128 << 10);
            defer testing.allocator.free(wire);

            for ([_]enum { read_into, stream, reader }{ .read_into, .stream, .reader }) |how| {
                var canned = try Canned.open(io);
                defer canned.close();
                try canned.replyZstd(wire, "200 OK", "", plain);
                var served = try io.concurrent(Canned.serveOne, .{&canned});
                defer served.cancel(io) catch {};

                var client = try started(io);
                defer client.deinit();
                var url_buf: [64]u8 = undefined;
                var ex: fetch.Exchange = .idle;
                defer ex.end();
                _ = try ex.begin(&client, .{ .method = .GET, .url = try canned.url(&url_buf), .stall_ms = 5_000, .decode = true });

                const got = try testing.allocator.alloc(u8, plain.len);
                defer testing.allocator.free(got);
                switch (how) {
                    .read_into => try ex.readInto(got),
                    .reader => try ex.reader.?.readSliceAll(got),
                    .stream => {
                        var out: std.Io.Writer = .fixed(got);
                        while (try ex.stream(&out, .limited(1000)) != 0) {}
                        try testing.expectEqual(plain.len, out.end);
                    },
                }
                try testing.expectEqualStrings(plain, got);
            }
        }
    }.run);
}

test "an Exchange pipes the decoded body, under a stall bound as well" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            const plain = try json(testing.allocator, 3000);
            defer testing.allocator.free(plain);
            const wire = try testing.allocator.alloc(u8, 128 << 10);
            defer testing.allocator.free(wire);

            var canned = try Canned.open(io);
            defer canned.close();
            try canned.replyZstd(wire, "200 OK", "", plain);
            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io);
            defer client.deinit();
            var url_buf: [64]u8 = undefined;
            var ex: fetch.Exchange = .idle;
            defer ex.end();
            const head = try ex.begin(&client, .{ .method = .GET, .url = try canned.url(&url_buf), .stall_ms = 5_000, .decode = true });
            // The length on the wire, which is not the length of the body.
            try testing.expectEqual(@as(?u64, canned.body_len), head.content_length);

            var out: std.Io.Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            const n = try ex.pipe(&out.writer);
            try testing.expectEqual(@as(u64, plain.len), n);
            try testing.expectEqualStrings(plain, out.written());
        }
    }.run);
}

test "an Exchange that did not ask to decode is handed zstd as an error, as before" {
    try withIo(struct {
        fn run(io: std.Io) !void {
            const plain = try json(testing.allocator, 50);
            defer testing.allocator.free(plain);
            var wire: [8 << 10]u8 = undefined;

            var canned = try Canned.open(io);
            defer canned.close();
            try canned.replyZstd(&wire, "200 OK", "", plain);
            var served = try io.concurrent(Canned.serveOne, .{&canned});
            defer served.cancel(io) catch {};

            var client = try started(io);
            defer client.deinit();
            var url_buf: [64]u8 = undefined;
            var ex: fetch.Exchange = .idle;
            defer ex.end();
            try testing.expectError(error.HttpContentEncodingUnsupported, ex.begin(&client, .{ .method = .GET, .url = try canned.url(&url_buf) }));
        }
    }.run);
}
