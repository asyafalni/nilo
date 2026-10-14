//! Whether a run of bytes is UTF-8, a block at a time, whatever the bytes are.
//!
//! `std.unicode.utf8ValidateSlice` clears 32 bytes of ASCII with one vector
//! compare and hands everything from the first byte over 0x7f to a decoder that
//! takes one byte at a time. A response in Japanese, Russian or Arabic is
//! nearly all such bytes, and a kilobyte of `é` cost 2,404ns against 10ns for
//! the same kilobyte of ASCII (`bench/result/http.md`, "What validating a
//! string as UTF-8 costs"; ADR 096). `json.zig` asks this question of every
//! string it writes, so the answer for non-Latin text is paid on every answer.
//!
//! What is here is the shape of Keiser and Lemire's "Validating UTF-8 in less
//! than one instruction per byte": look at each byte together with the three
//! before it, and every way a byte can be wrong is a comparison on those four.
//! Their version finds the answer with three table lookups through `pshufb`;
//! Zig has no vector lookup with a runtime index, and a lowering to scalar
//! code would have no use for one, so the same conditions are written here as
//! compares. They are fewer than they look: a byte is wrong when
//!
//! - it is a continuation (0x80..0xBF) that nothing asked for, or is not one
//!   where the lead byte one, two or three places back asked for it. That is
//!   `must_continue != is_continuation`, and it covers a sequence cut short
//!   and a stray continuation byte;
//! - it is 0xC0 or 0xC1 (a two-byte form of something below 0x80) or 0xF5 and
//!   up (past U+10FFFF);
//! - it follows 0xE0 and is below 0xA0 (a three-byte overlong), follows 0xED
//!   and is 0xA0 or more (a surrogate, U+D800 to U+DFFF), follows 0xF0 and is
//!   below 0x90 (a four-byte overlong), or follows 0xF4 and is 0x90 or more
//!   (above U+10FFFF).
//!
//! That is what `utf8ValidateSlice` refuses, no more and no less, and the test
//! at the bottom holds the two together byte for byte.
//!
//! **Block edges.** A character can start in one block and finish in the next,
//! so the three bytes before a block's first are the last three of the one
//! before it, put in place with `@shuffle` over both. The tail, which is not a
//! whole block, is the last 32 bytes of the input: it overlaps bytes already
//! checked, which is harmless because a byte checked twice with the right
//! bytes before it gives the same answer, and it needs no copy into a padded
//! block, the cost `scan.positionsOf` avoids the same way. The three bytes
//! before it are the real ones, and the end of the input is the end of its
//! last block, where a lead byte with too few after it is the one thing no
//! comparison inside the block can see, so it is asked directly.
//!
//! **A block of ASCII** skips all of it: one compare for the high bit, and one
//! question about whether the block before ended inside a character. An input
//! shorter than a block goes to the standard library, whose decoder is as fast
//! as anything for nine bytes and needs no padding.
//!
//! Only portable vectors, no intrinsics, so it is correct wherever `@Vector`
//! lowers to scalar code; how fast it is there is not claimed.

const std = @import("std");
const scan = @import("scan.zig");

const lanes = scan.lanes;
const Block = scan.Block;
const Flags = @Vector(lanes, bool);

/// Whether `text` is well-formed UTF-8, exactly as
/// `std.unicode.utf8ValidateSlice` decides it.
pub fn valid(text: []const u8) bool {
    if (text.len < lanes) return std.unicode.utf8ValidateSlice(text);

    // ASCII, which nearly every answer is, pays one compare a block and
    // carries nothing from one block to the next, as std's own fast path does:
    // with the checks below on every block the ASCII payload took twice
    // std's time (ADR 096).
    const high: Block = @splat(0x80);
    var i: usize = 0;
    while (i + lanes <= text.len) : (i += lanes) {
        const block: Block = text[i..][0..lanes].*;
        if (@reduce(.Or, block >= high)) break;
    } else {
        if (i == text.len) return true;
        const tail: Block = text[text.len - lanes ..][0..lanes].*;
        if (!@reduce(.Or, tail >= high)) return true;
    }

    // Every byte before `i` is ASCII, so the block before it asks nothing of
    // the bytes after and zeros stand in for it.
    var prev: Block = @splat(0);
    var last: Block = prev;
    while (i + lanes <= text.len) : (i += lanes) {
        const block: Block = text[i..][0..lanes].*;
        if (@reduce(.Or, block >= high)) {
            if (@reduce(.Or, faults(prev, block))) return false;
        } else if (endsInside(prev)) return false;
        prev = block;
        last = block;
    }

    if (i < text.len) {
        // Not a whole block left: the last one, with the three bytes before
        // it put where `prev` keeps them.
        const from = text.len - lanes;
        var raw: [lanes]u8 = @splat(0);
        for (0..@min(3, from)) |k| raw[lanes - 1 - k] = text[from - 1 - k];
        const before: Block = raw;
        const block: Block = text[from..][0..lanes].*;
        if (@reduce(.Or, faults(before, block))) return false;
        last = block;
    }
    return !endsInside(last);
}

/// Whether a block ends partway through a character: its last byte leads one
/// that needs another, or the one before leads one that needs two, or the one
/// before that leads a four-byte one. A lead byte past those (0xF5 and up) is
/// no lead at all and `faults` has already refused it, so `>=` is enough.
fn endsInside(block: Block) bool {
    return block[lanes - 1] >= 0xC0 or block[lanes - 2] >= 0xE0 or block[lanes - 3] >= 0xF0;
}

/// The bytes of `block` that are wrong given the bytes before them, `prev`
/// being the block before it.
fn faults(prev: Block, block: Block) Flags {
    const p1 = behind(1, prev, block);
    const p2 = behind(2, prev, block);
    const p3 = behind(3, prev, block);

    const is_continuation = (block & @as(Block, @splat(0xC0))) == @as(Block, @splat(0x80));
    // A lead byte one back wants one more, two back wants two, three back wants
    // three. 0xC2 and not 0xC0 so that the two it may not be are not asked
    // twice; they are refused below.
    const must_continue = (p1 >= @as(Block, @splat(0xC2))) |
        (p2 >= @as(Block, @splat(0xE0))) |
        (p3 >= @as(Block, @splat(0xF0)));
    var bad = must_continue ^ is_continuation;

    bad |= (block == @as(Block, @splat(0xC0))) | (block == @as(Block, @splat(0xC1))) |
        (block >= @as(Block, @splat(0xF5)));

    bad |= (p1 == @as(Block, @splat(0xE0))) & (block < @as(Block, @splat(0xA0)));
    bad |= (p1 == @as(Block, @splat(0xED))) & (block >= @as(Block, @splat(0xA0)));
    bad |= (p1 == @as(Block, @splat(0xF0))) & (block < @as(Block, @splat(0x90)));
    bad |= (p1 == @as(Block, @splat(0xF4))) & (block >= @as(Block, @splat(0x90)));
    return bad;
}

/// `block` moved `n` places along, the bytes that come in at the front being
/// the last `n` of `prev`: lane *k* holds the byte *n* before lane *k* of
/// `block`.
fn behind(comptime n: usize, prev: Block, block: Block) Block {
    const mask = comptime blk: {
        var m: [lanes]i32 = undefined;
        for (&m, 0..) |*slot, k| {
            // Non-negative picks from the first vector, `~k` from the second.
            slot.* = if (k < n) @as(i32, lanes - n + k) else ~@as(i32, k - n);
        }
        break :blk m;
    };
    return @shuffle(u8, prev, block, mask);
}

const testing = std.testing;

/// Splitmix64, so that a failing case can be named by its seed.
const Rng = struct {
    state: u64,

    fn next(self: *Rng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    fn below(self: *Rng, n: usize) usize {
        return @intCast(self.next() % n);
    }
};

fn agrees(text: []const u8) !void {
    const want = std.unicode.utf8ValidateSlice(text);
    if (valid(text) != want) {
        std.debug.print("disagreement on {any}: std says {}\n", .{ text, want });
        return error.TestUnexpectedResult;
    }
}

test "every way a sequence can be wrong is refused at every offset in a run of ASCII" {
    // Each case is placed at every offset from 0 to 63 in a buffer long enough
    // to hold it with ASCII on both sides, so it falls inside a block, across
    // the edge between two, and against the end of the input.
    const cases = [_][]const u8{
        // Valid, at the edge of each range.
        "\xC2\x80",         "\xDF\xBF",             "\xE0\xA0\x80",         "\xEC\x80\x80",
        "\xED\x9F\xBF",     "\xEE\x80\x80",         "\xEF\xBF\xBF",         "\xF0\x90\x80\x80",
        "\xF3\xBF\xBF\xBF", "\xF4\x8F\xBF\xBF",     "\xC3\xA9",             "\xE3\x81\x82",
        "\xF0\x9F\x98\x80",
        // Overlong.
        "\xC0\x80",         "\xC1\xBF",             "\xE0\x80\x80",         "\xE0\x9F\xBF",
        "\xF0\x80\x80\x80", "\xF0\x8F\xBF\xBF",
        // Surrogates, and the edge either side of them.
        "\xED\xA0\x80",     "\xED\xAF\xBF",         "\xED\xBF\xBF",
        // Past U+10FFFF.
        "\xF4\x90\x80\x80", "\xF4\xBF\xBF\xBF",     "\xF5\x80\x80\x80",     "\xF7\xBF\xBF\xBF",
        "\xF8\x88\x80\x80\x80", "\xFF",             "\xFE",
        // A continuation with nothing before it.
        "\x80",             "\xBF",                 "\x80\x80",
        // Cut short, and followed by a byte that is not a continuation.
        "\xC2",             "\xC2x",                "\xE0\xA0",             "\xE0\xA0x",
        "\xE3\x81",         "\xE3x\x81",            "\xF0\x9F\x98",         "\xF0\x9F\x98x",
        "\xF0\x9Fx\x80",    "\xF0x\x9F\x98",
        // Too many continuations.
        "\xC3\xA9\xA9",     "\xE3\x81\x82\x82",     "\xF0\x9F\x98\x80\x80",
    };
    var buf: [128]u8 = undefined;
    for (cases) |case| {
        for (0..64) |at| {
            @memset(&buf, 'a');
            // The case ends the input for every offset, then sits inside it.
            try agrees(buf[0 .. at + case.len]);
            @memcpy(buf[at..][0..case.len], case);
            try agrees(buf[0 .. at + case.len]);
            try agrees(buf[0 .. at + case.len + 1]);
            try agrees(buf[0 .. at + case.len + 33]);
            try agrees(buf[0..128]);
        }
    }
}

test "text cut at every length is refused or accepted as the standard library does" {
    // A valid mixed string of 1-, 2-, 3- and 4-byte characters, cut at each
    // length, so each of them ends in turn inside every kind of character.
    const unit = "ab\xC3\xA9\xE3\x81\x82\xF0\x9F\x98\x80z";
    var whole: [unit.len * 12]u8 = undefined;
    for (0..12) |k| @memcpy(whole[k * unit.len ..][0..unit.len], unit);
    const text: []const u8 = &whole;
    for (0..text.len + 1) |len| try agrees(text[0..len]);
    // And with the front cut off, so a continuation byte leads.
    for (0..text.len) |from| try agrees(text[from..]);
}

test "a run of two-byte characters, the case that was slow, is accepted" {
    var buf: [1024]u8 = undefined;
    for (0..buf.len / 2) |k| {
        buf[2 * k] = 0xC3;
        buf[2 * k + 1] = 0xA9;
    }
    try testing.expect(valid(&buf));
    try testing.expect(valid(buf[0..1022]));
    try testing.expect(!valid(buf[0..1023]));
    try testing.expect(!valid(buf[1..]));
}

test "random bytes are judged as the standard library judges them" {
    // Debug is the loop, so it runs fewer.
    const rounds: usize = if (@import("builtin").mode == .debug) 40_000 else 300_000;
    var rng: Rng = .{ .state = 0x6E696C6F };
    var buf: [200]u8 = undefined;
    for (0..rounds) |_| {
        const len = rng.below(buf.len + 1);
        // Drawn from the bytes that matter, or UTF-8 would nearly never get
        // past its first few bytes.
        const flavour = rng.below(3);
        for (buf[0..len]) |*b| {
            b.* = switch (flavour) {
                0 => @intCast(rng.next() & 0xFF),
                1 => interesting[rng.below(interesting.len)],
                else => if (rng.below(4) == 0) interesting[rng.below(interesting.len)] else 'a',
            };
        }
        try agrees(buf[0..len]);
    }
}

test "valid text with one byte changed is judged as the standard library judges it" {
    const rounds: usize = if (@import("builtin").mode == .debug) 40_000 else 300_000;
    var rng: Rng = .{ .state = 0x7574663820 };
    var buf: [200]u8 = undefined;
    for (0..rounds) |_| {
        var len: usize = 0;
        // Whole characters until about 150 bytes, so the text is valid.
        const target = 32 + rng.below(buf.len - 32 - 4);
        while (len < target) {
            const cp: u21 = switch (rng.below(4)) {
                0 => @intCast(rng.below(0x80)),
                1 => @intCast(0x80 + rng.below(0x780)),
                2 => blk: {
                    const c: u21 = @intCast(0x800 + rng.below(0xF800));
                    break :blk if (c >= 0xD800 and c <= 0xDFFF) 0x3042 else c;
                },
                else => @intCast(0x10000 + rng.below(0x100000)),
            };
            len += std.unicode.utf8Encode(cp, buf[len..]) catch unreachable;
        }
        const text = buf[0..len];
        try testing.expect(valid(text));

        const at = rng.below(len);
        const was = text[at];
        text[at] = switch (rng.below(3)) {
            0 => @intCast(rng.next() & 0xFF),
            1 => interesting[rng.below(interesting.len)],
            else => was ^ @as(u8, 1) << @intCast(rng.below(8)),
        };
        try agrees(text);
        // And the same text cut short, where the damage is at the very end.
        try agrees(text[0 .. at + 1]);
    }
}

/// The bytes at either side of every boundary the rules draw.
const interesting = [_]u8{
    0x00, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC1, 0xC2,
    0xDF, 0xE0, 0xE1, 0xEC, 0xED, 0xEE, 0xEF, 0xF0, 0xF1, 0xF3, 0xF4,
    0xF5, 0xF8, 0xFF,
};
