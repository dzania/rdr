//! Writes to the system clipboard through the terminal with OSC 52, which
//! also works over SSH. kitty accepts it by default (`clipboard_control`).
//! The terminal gives no reply, so a refused write goes unnoticed.
const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;

/// Largest text sent, in bytes. A page holds a few kilobytes of text; the
/// cap bounds what a hostile document can make rdr send.
pub const bytes_max = 1 << 20;

/// Bytes encoded per chunk. A multiple of 3, so chunks need no padding
/// until the last one.
const chunk_len = 3 * 1024;
const encoder = std.base64.standard.Encoder;

/// Puts `text` on the clipboard. Base64 keeps the text's bytes, including
/// any control characters, from reaching the terminal as sequences.
pub fn write(out: *Writer, text: []const u8) Writer.Error!void {
    assert(text.len <= bytes_max);
    try out.writeAll("\x1b]52;c;");
    var encoded: [encoder.calcSize(chunk_len)]u8 = undefined;
    var rest = text;
    while (rest.len > 0) {
        const chunk = rest[0..@min(chunk_len, rest.len)];
        try out.writeAll(encoder.encode(&encoded, chunk));
        rest = rest[chunk.len..];
    }
    try out.writeAll("\x1b\\");
}

/// Characters in valid UTF-8 `text`, for the status line.
pub fn countChars(text: []const u8) usize {
    var count: usize = 0;
    for (text) |byte| {
        if (byte & 0xc0 != 0x80) count += 1;
    }
    return count;
}

const testing = std.testing;

test write {
    var buffer: [64]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    try write(&out, "hi\n");
    try testing.expectEqualStrings("\x1b]52;c;aGkK\x1b\\", out.buffered());

    out = .fixed(&buffer);
    try write(&out, "");
    try testing.expectEqualStrings("\x1b]52;c;\x1b\\", out.buffered());
}

test "write encodes across chunks like one encode" {
    var text: [chunk_len * 2 + 1]u8 = undefined;
    for (&text, 0..) |*byte, index| byte.* = @truncate(index * 7);
    var expected: [encoder.calcSize(text.len)]u8 = undefined;
    var buffer: [16 + expected.len]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    try write(&out, &text);
    const written = out.buffered();
    try testing.expectEqualStrings(encoder.encode(&expected, &text), written[7 .. written.len - 2]);
}
