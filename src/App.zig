//! Runs the viewer: applies commands to the viewport and keeps the terminal
//! showing the right crop of the right page image, or the table of contents.
const App = @This();

const std = @import("std");
const Document = @import("Document.zig");
const Index = @import("Index.zig");
const PageCache = @import("PageCache.zig");
const Tty = @import("Tty.zig");
const Viewport = @import("Viewport.zig");
const input = @import("input.zig");
const kitty = @import("kitty.zig");
const assert = std.debug.assert;

tty: Tty,
out: *std.Io.Writer,
doc: Document,
/// Shown in the status line.
title: []const u8,
medium: kitty.Medium,
size: Tty.Size,
viewport: Viewport,
cache: PageCache = .{},
/// The image whose placement is on screen.
shown: ?kitty.ImageId = null,
mode: Mode = .page,
/// Made on the first `Tab`, so a document whose outline is never opened
/// does not load it. Kept after closing, with its expanded entries.
index: ?Index = null,
/// Replaces the status line until the next command.
notice: ?[]const u8 = null,
decoder: input.Decoder = .{},
parser: input.Parser = .{},

const Mode = enum { page, index };
const Next = enum { run, quit };

pub const Error = Document.Error || kitty.Error;

/// Probes the terminal, so the tty must already be in the alternate screen.
pub fn init(tty: Tty, out: *std.Io.Writer, doc: Document, title: []const u8, first_page: u32) Error!App {
    const size = try tty.size();
    return .{
        .tty = tty,
        .out = out,
        .doc = doc,
        .title = title,
        .medium = try .probe(tty, out),
        .size = size,
        .viewport = .init(first_page, doc.page_count, size),
    };
}

/// Frees the terminal's images and removes any object it has not consumed.
pub fn deinit(self: *App) void {
    for (self.cache.entries) |slot| {
        const entry = slot orelse continue;
        // Best effort on the way out: the terminal may already be gone.
        kitty.delete(self.out, entry.id) catch {};
        self.medium.remove(entry.id);
    }
    self.out.flush() catch {};
}

pub fn run(self: *App) Error!void {
    try self.draw();
    var buffer: [64]u8 = undefined;
    while (true) switch (try self.tty.wait()) {
        .quit => return,
        .resize => {
            try self.resize();
            try self.draw();
        },
        .input => {
            const bytes = try self.tty.read(&buffer);
            if (bytes.len == 0) return; // The terminal hung up.
            for (bytes) |byte| {
                const keys = self.decoder.feed(byte);
                if (keys.escape) try self.escapeKey();
                const key = keys.byte orelse continue;
                const next = switch (self.mode) {
                    .page => try self.pageKey(key),
                    .index => try self.indexKey(key),
                };
                if (next == .quit) return;
            }
            if (self.decoder.flush()) try self.escapeKey();
        },
    };
}

/// Escape closes the index, and in either mode drops a pending `g`.
fn escapeKey(self: *App) Error!void {
    self.parser.reset();
    if (self.mode != .index) return;
    self.notice = null;
    try self.closeIndex();
    try self.draw();
}

fn pageKey(self: *App, byte: u8) Error!Next {
    const command = self.parser.feed(byte) orelse return .run;
    self.notice = null;
    switch (command) {
        .quit => return .quit,
        .open_index => try self.openIndex(),
        else => self.viewport.apply(command),
    }
    try self.draw();
    return .run;
}

fn indexKey(self: *App, byte: u8) Error!Next {
    const command = self.parser.feedIndex(byte) orelse return .run;
    self.notice = null;
    switch (command) {
        .quit => return .quit,
        .close => try self.closeIndex(),
        .select => try self.select(),
        else => self.index.?.apply(command),
    }
    try self.draw();
    return .run;
}

/// Shows the table of contents with the current page's entry selected, or
/// a notice if the document has none.
fn openIndex(self: *App) Error!void {
    if (self.index == null) {
        const items = self.doc.outline() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OutlineFailed => {
                self.notice = "cannot read the table of contents";
                return;
            },
        };
        if (items.len == 0) {
            self.notice = "no table of contents";
            return;
        }
        self.index = .init(items);
    }
    self.index.?.reveal(self.viewport.page);
    self.mode = .index;
    self.parser.reset();
}

fn closeIndex(self: *App) Error!void {
    self.mode = .page;
    self.parser.reset();
    // A page narrower than the pane would leave index text at its sides.
    try self.clearRows();
}

/// Jumps to the selected entry's target and closes the index.
fn select(self: *App) Error!void {
    const item = self.index.?.selectedItem();
    if (item.page < 0) {
        self.notice = "this entry points outside the document";
        return;
    }
    const page: u32 = @intCast(item.page);
    const size = self.doc.pageSize(page) catch |err| switch (err) {
        // A damaged page should not end the session: the index stays open
        // so another entry can be picked.
        error.PageFailed => {
            self.notice = "cannot open this entry's page";
            return;
        },
        else => return err,
    };
    // `draw` gets the same scale for this page, so the offset matches its
    // image. Bounded by the image height, so it fits in a u32.
    const scale = self.viewport.scale(size);
    const y_pt = @min(item.y, size.height);
    self.viewport.jump(page, @intFromFloat(y_pt * scale));
    try self.closeIndex();
}

fn resize(self: *App) Error!void {
    self.size = try self.tty.size();
    self.viewport.resize(self.size);
    // Erase stale text such as the old status line.
    try self.clearRows();
}

/// Erases every row, one at a time: clearing the screen with ED would also
/// delete the images.
fn clearRows(self: *App) Error!void {
    try self.out.writeAll("\x1b[H");
    for (0..self.size.rows) |_| try self.out.writeAll("\x1b[2K\x1b[B");
}

fn draw(self: *App) Error!void {
    switch (self.mode) {
        .page => try self.drawPage(),
        .index => try self.drawIndex(),
    }
    try self.drawStatus();
    try self.out.flush();
}

fn drawPage(self: *App) Error!void {
    const image = try self.pageImage();
    const crop = self.viewport.fit(.{ .width = image.width, .height = image.height });
    if (self.shown) |shown| {
        if (shown != image.id) try kitty.unplace(self.out, shown);
    }
    try self.out.print("\x1b[1;{d}H", .{crop.column});
    try kitty.place(self.out, image.id, crop.rect);
    self.shown = image.id;
}

/// One entry per row above the status line. The page image is hidden but
/// stays in the terminal for when the index closes.
fn drawIndex(self: *App) Error!void {
    if (self.shown) |shown| {
        try kitty.unplace(self.out, shown);
        self.shown = null;
    }
    const index = &self.index.?;
    const rows = self.size.rows - 1;
    index.scrollIntoView(rows);
    // Autowrap off, so a title with wide characters cannot spill onto the
    // next row.
    try self.out.writeAll("\x1b[?7l");
    var entry: ?usize = index.top;
    for (1..rows + 1) |row| {
        try self.out.print("\x1b[{d};1H\x1b[2K", .{row});
        const current = entry orelse continue;
        try drawEntry(self.out, index.*, current, self.size.cols);
        entry = index.nextVisible(current);
    }
    try self.out.writeAll("\x1b[?7h");
}

/// Indent, a marker if the entry has children, the title, and the page
/// number at the right edge. The selected entry is in reverse video.
fn drawEntry(out: *std.Io.Writer, index: Index, entry: usize, cols: u16) std.Io.Writer.Error!void {
    const item = index.items[entry];
    const selected = entry == index.selected;
    var label_buffer: [16]u8 = undefined;
    const label = if (item.page < 0) "" else std.fmt.bufPrint(&label_buffer, "{d}", .{item.page + 1}) catch
        unreachable; // A c_int has at most 10 digits.

    var line: Line = .{ .out = out, .columns = cols };
    if (selected) try out.writeAll("\x1b[7m");
    for (0..@intCast(item.depth)) |_| try line.write("  ", line.columns);
    const marker = if (!index.hasChildren(entry)) "  " else if (index.isExpanded(entry)) "\u{25be} " else "\u{25b8} ";
    try line.write(marker, line.columns);
    // One column stays free between the title and the page number.
    try line.write(std.mem.span(item.title), line.columns -| (label.len + 1));
    try line.padTo(label.len);
    try line.write(label, line.columns);
    if (selected) try out.writeAll("\x1b[27m");
}

/// Text for one row, cut to its width. Wide characters count as two
/// columns and everything else as one, so combining marks are over-counted:
/// the row then ends a little short, which is harmless, where under-counting
/// would push the page number off the edge.
const Line = struct {
    out: *std.Io.Writer,
    /// Columns left in the row.
    columns: usize,

    /// Writes `text`, cut to `columns_max` columns. Control characters,
    /// which a title could use to send escape sequences, become spaces, and
    /// invalid UTF-8 becomes U+FFFD.
    fn write(self: *Line, text: []const u8, columns_max: usize) std.Io.Writer.Error!void {
        var budget = @min(columns_max, self.columns);
        var rest = text;
        while (rest.len > 0) {
            const char = nextChar(rest);
            const width = columnWidth(char.code_point);
            // A wide character in the last free column would overflow it.
            if (width > budget) break;
            switch (char.code_point) {
                0x00...0x1f, 0x7f...0x9f => try self.out.writeByte(' '),
                std.unicode.replacement_character => try self.out.writeAll("\u{fffd}"),
                else => try self.out.writeAll(rest[0..char.len]),
            }
            rest = rest[char.len..];
            budget -= width;
            self.columns -= width;
        }
    }

    /// Writes spaces until `columns` columns are left.
    fn padTo(self: *Line, columns: usize) std.Io.Writer.Error!void {
        while (self.columns > columns) : (self.columns -= 1) try self.out.writeByte(' ');
    }
};

const Char = struct {
    /// U+FFFD for invalid UTF-8.
    code_point: u21,
    /// Bytes used, at least 1.
    len: usize,
};

/// Decodes the first character of `text`, which is not empty. Invalid
/// UTF-8 uses its lead byte and any continuation bytes after it, up to the
/// length the lead byte claims, so a valid character right after a bad lead
/// byte is not swallowed.
fn nextChar(text: []const u8) Char {
    assert(text.len > 0);
    const bad: Char = .{ .code_point = std.unicode.replacement_character, .len = 1 };
    // utf8Decode does not check single bytes, so a byte that cannot start a
    // sequence must not reach it.
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return bad;
    if (len <= text.len) {
        if (std.unicode.utf8Decode(text[0..len])) |code_point| {
            return .{ .code_point = code_point, .len = len };
        } else |_| {}
    }
    var used: usize = 1;
    while (used < len and used < text.len and text[used] & 0xc0 == 0x80) used += 1;
    return .{ .code_point = bad.code_point, .len = used };
}

/// Columns a terminal gives `code_point`: 2 for East Asian Wide and
/// Fullwidth characters and wide emoji, else 1. The ranges cover the main
/// blocks rather than every assigned code point. Where they are loose they
/// err toward 2, which costs a column of padding instead of the page number.
fn columnWidth(code_point: u21) usize {
    // Sorted and disjoint (checked below), so the scan can stop early.
    for (wide_ranges) |range| {
        if (code_point < range[0]) return 1;
        if (code_point <= range[1]) return 2;
    }
    return 1;
}

/// Inclusive code point ranges that `columnWidth` counts as two columns.
const wide_ranges = [_][2]u21{
    .{ 0x1100, 0x115f }, // Hangul Jamo initial consonants.
    .{ 0x231a, 0x231b }, // Watch, hourglass.
    .{ 0x2329, 0x232a }, // Angle brackets.
    .{ 0x23e9, 0x23f3 }, // Media control emoji.
    .{ 0x25fd, 0x25fe },
    .{ 0x2614, 0x2615 },
    .{ 0x2648, 0x2653 }, // Zodiac.
    .{ 0x26a1, 0x26a1 },
    .{ 0x26bd, 0x26be },
    .{ 0x26c4, 0x26c5 },
    .{ 0x26d4, 0x26d4 },
    .{ 0x26ea, 0x26ea },
    .{ 0x26f2, 0x26f5 },
    .{ 0x26fa, 0x26fd },
    .{ 0x2705, 0x2705 },
    .{ 0x270a, 0x270b },
    .{ 0x2728, 0x2728 },
    .{ 0x274c, 0x274e },
    .{ 0x2753, 0x2757 },
    .{ 0x2795, 0x2797 },
    .{ 0x27b0, 0x27bf },
    .{ 0x2b1b, 0x2b1c },
    .{ 0x2b50, 0x2b55 },
    .{ 0x2e80, 0x303e }, // CJK radicals through CJK punctuation.
    .{ 0x3041, 0x33ff }, // Kana, Bopomofo, Hangul compatibility, CJK compatibility.
    .{ 0x3400, 0x4dbf }, // CJK extension A.
    .{ 0x4e00, 0x9fff }, // CJK unified ideographs.
    .{ 0xa000, 0xa4cf }, // Yi.
    .{ 0xa960, 0xa97f }, // Hangul Jamo extended A.
    .{ 0xac00, 0xd7a3 }, // Hangul syllables.
    .{ 0xf900, 0xfaff }, // CJK compatibility ideographs.
    .{ 0xfe10, 0xfe19 }, // Vertical forms.
    .{ 0xfe30, 0xfe6f }, // CJK compatibility forms, small forms.
    .{ 0xff00, 0xff60 }, // Fullwidth forms.
    .{ 0xffe0, 0xffe6 },
    .{ 0x16fe0, 0x16fe4 },
    .{ 0x17000, 0x18cff }, // Tangut, Khitan.
    .{ 0x1aff0, 0x1b2ff }, // Kana supplement and extensions, Nushu.
    .{ 0x1f004, 0x1f004 },
    .{ 0x1f0cf, 0x1f0cf },
    .{ 0x1f18e, 0x1f18e },
    .{ 0x1f191, 0x1f19a },
    .{ 0x1f200, 0x1f2ff }, // Enclosed ideographic supplement.
    .{ 0x1f300, 0x1f64f }, // Pictographs and emoticons.
    .{ 0x1f680, 0x1f6ff }, // Transport and map symbols.
    .{ 0x1f7e0, 0x1f7eb },
    .{ 0x1f90c, 0x1f9ff }, // Supplemental symbols and pictographs.
    .{ 0x1fa70, 0x1faff },
    .{ 0x20000, 0x2fffd }, // CJK extensions B and later.
    .{ 0x30000, 0x3fffd },
};

comptime {
    for (wide_ranges) |range| assert(range[0] <= range[1]);
    for (wide_ranges[0 .. wide_ranges.len - 1], wide_ranges[1..]) |range, next| assert(range[1] < next[0]);
}

/// The current page's image at the current zoom, rendered and transmitted
/// first if the terminal does not have it.
fn pageImage(self: *App) Error!PageCache.Entry {
    const page = self.viewport.page;
    const scale = self.viewport.scale(try self.doc.pageSize(page));
    if (self.cache.get(page, scale)) |entry| return entry;

    var pixmap = try self.doc.render(page, scale);
    defer pixmap.deinit(self.doc);
    const entry, const evicted = self.cache.insert(page, scale, pixmap.width, pixmap.height);
    if (evicted) |id| {
        try kitty.delete(self.out, id);
        if (self.shown == id) self.shown = null;
    }
    const image: kitty.Image = .{ .pixels = pixmap.pixels, .width = pixmap.width, .height = pixmap.height };
    try kitty.transmit(self.out, self.medium, entry.id, image, .quiet);
    return entry;
}

fn drawStatus(self: *App) Error!void {
    var buffer: [256]u8 = undefined;
    var status: std.Io.Writer = .fixed(&buffer);
    // A title too long for the buffer is cut off, which the pane width
    // would do anyway.
    if (self.notice) |notice| {
        status.print(" {s}", .{notice}) catch {};
    } else switch (self.mode) {
        .page => status.print(" {s}  {d} / {d}  {d:.0}%", .{
            self.title,
            self.viewport.page + 1,
            self.viewport.page_count,
            self.viewport.zoom * 100,
        }) catch {},
        .index => status.print(" {s}  contents", .{self.title}) catch {},
    }
    const text = truncate(status.buffered(), self.size.cols);
    try self.out.print("\x1b[{d};1H\x1b[2K{s}", .{ self.size.rows, text });
}

/// Cuts `text` to at most `len` bytes without splitting a UTF-8 sequence.
fn truncate(text: []const u8, len: usize) []const u8 {
    if (text.len <= len) return text;
    var end = len;
    while (end > 0 and text[end] & 0xc0 == 0x80) end -= 1;
    return text[0..end];
}

test truncate {
    try std.testing.expectEqualStrings("abc", truncate("abc", 5));
    try std.testing.expectEqualStrings("ab", truncate("abc", 2));
    try std.testing.expectEqualStrings("a", truncate("a\u{e9}b", 2));
    try std.testing.expectEqualStrings("a\u{e9}", truncate("a\u{e9}b", 3));
    try std.testing.expectEqualStrings("", truncate("abc", 0));
}

fn testLine(text: []const u8, cols: usize, label_len: usize) ![]const u8 {
    const state = struct {
        var buffer: [64]u8 = undefined;
    };
    var out: std.Io.Writer = .fixed(&state.buffer);
    var line: Line = .{ .out = &out, .columns = cols };
    try line.write(text, line.columns -| (label_len + 1));
    try line.padTo(label_len);
    return out.buffered();
}

test Line {
    try std.testing.expectEqualStrings("ab   ", try testLine("ab", 5, 0));
    try std.testing.expectEqualStrings("abc ", try testLine("abcdef", 5, 1));
    try std.testing.expectEqualStrings("a\u{e9}cd ", try testLine("a\u{e9}cdef", 5, 0));
    try std.testing.expectEqualStrings("a b c ", try testLine("a\x1bb\u{9b}c", 6, 0));
    try std.testing.expectEqualStrings("\u{fffd}x ", try testLine("\xffx", 3, 0));
    try std.testing.expectEqualStrings("", try testLine("abc", 0, 0));
    try std.testing.expectEqualStrings("", try testLine("abc", 2, 3));
}

test "Line keeps the characters after invalid UTF-8" {
    // 0xE9 is Latin-1 é and claims a 3-byte sequence here.
    try std.testing.expectEqualStrings("\u{fffd}ab ", try testLine("\xe9ab", 4, 0));
    try std.testing.expectEqualStrings("Caf\u{fffd} au ", try testLine("Caf\xe9 au lait", 8, 0));
    // A cut-short sequence is one replacement, not one per byte.
    try std.testing.expectEqualStrings("\u{fffd}x ", try testLine("\xe2\x82x", 3, 0));
    // So is a sequence cut off by the end of the text.
    try std.testing.expectEqualStrings("a\u{fffd}  ", try testLine("a\xe2\x82", 4, 0));
    // A stray continuation byte.
    try std.testing.expectEqualStrings("\u{fffd}\u{fffd}a ", try testLine("\x80\xbfa", 4, 0));
}

test "Line counts wide characters as two columns" {
    // Two columns each, so three fit in 6 and the pad is one space.
    try std.testing.expectEqualStrings("\u{7b2c}\u{4e00}\u{7ae0} ", try testLine("\u{7b2c}\u{4e00}\u{7ae0}\u{6982}", 7, 0));
    // A wide character never takes the last free column.
    try std.testing.expectEqualStrings("a\u{7b2c}  ", try testLine("a\u{7b2c}\u{4e00}", 5, 0));
    // The label's columns stay free.
    try std.testing.expectEqualStrings("\u{7b2c}\u{4e00} ", try testLine("\u{7b2c}\u{4e00}\u{7ae0}", 8, 3));
}

test columnWidth {
    try std.testing.expectEqual(1, columnWidth('a'));
    try std.testing.expectEqual(1, columnWidth(0xe9));
    try std.testing.expectEqual(1, columnWidth(0x25b8)); // The index marker.
    try std.testing.expectEqual(2, columnWidth(0x4e00));
    try std.testing.expectEqual(2, columnWidth(0xac00));
    try std.testing.expectEqual(2, columnWidth(0xff21)); // Fullwidth A.
    try std.testing.expectEqual(2, columnWidth(0x1f600)); // Grinning face.
    try std.testing.expectEqual(2, columnWidth(0x20000));
    try std.testing.expectEqual(1, columnWidth(0x10ffff));
}
