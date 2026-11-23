//! Runs the viewer: applies commands to the viewport and keeps the terminal
//! showing the right crop of the right page image, or the table of contents.
const App = @This();

const std = @import("std");
const Document = @import("Document.zig");
const Index = @import("Index.zig");
const PageCache = @import("PageCache.zig");
const Tty = @import("Tty.zig");
const Viewport = @import("Viewport.zig");
const clipboard = @import("clipboard.zig");
const highlight = @import("highlight.zig");
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
/// What `Tty.enter`'s mouse reports count.
mouse_units: Tty.MouseUnits,
/// The image whose placement is on screen.
shown: ?PageCache.Entry = null,
mode: Mode = .page,
/// Made on the first `Tab`, so a document whose outline is never opened
/// does not load it. Kept after closing, with its expanded entries.
index: ?Index = null,
/// Replaces the status line until the next command.
notice: ?Notice = null,
/// Text being or last selected with the mouse. Drawn while its page is on
/// screen; a new press or Escape drops it.
selection: ?Selection = null,
/// The terminal holds the highlight tile.
highlight_sent: bool = false,
/// Highlight placements are on screen.
highlight_shown: bool = false,
/// The selection changed since the last `draw`.
redraw: bool = false,
decoder: input.Decoder = .{},
parser: input.Parser = .{},

const Mode = enum { page, index };
const Next = enum { run, quit };

const Notice = union(enum) {
    text: []const u8,
    /// Characters sent to the clipboard.
    copied: usize,
};

/// Kept in page points, so it stays on the same text across scrolling,
/// zoom, and resizes.
const Selection = struct {
    page: u32,
    /// Where the drag started.
    anchor: Document.Point,
    /// Where it is now, or ended.
    head: Document.Point,
    dragging: bool,
};

/// Highlight rectangles per frame. One per selected line, so a full pane of
/// small print fits.
const highlight_rects_max = 512;

pub const Error = Document.Error || kitty.Error;

/// Probes the terminal, so the tty must already be in the alternate screen.
pub fn init(tty: Tty, out: *std.Io.Writer, doc: Document, title: []const u8, first_page: u32) Error!App {
    const size = try tty.size();
    const medium: kitty.Medium = try .probe(tty, out);
    const mouse_units = try tty.probeMouseUnits();
    return .{
        .tty = tty,
        .out = out,
        .doc = doc,
        .title = title,
        .medium = medium,
        .mouse_units = mouse_units,
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
    if (self.highlight_sent) {
        kitty.delete(self.out, .highlight) catch {};
        self.medium.remove(.highlight);
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
                if (keys.mouse) |event| try self.mouse(event);
                const key = keys.byte orelse continue;
                const next = switch (self.mode) {
                    .page => try self.pageKey(key),
                    .index => try self.indexKey(key),
                };
                if (next == .quit) return;
            }
            if (self.decoder.flush()) try self.escapeKey();
            // A drag reports every pixel moved, so the highlight is
            // redrawn once per read rather than once per report.
            if (self.redraw) try self.draw();
        },
    };
}

/// Escape closes the index or drops the selection, and in either mode
/// drops a pending `g`.
fn escapeKey(self: *App) Error!void {
    self.parser.reset();
    switch (self.mode) {
        .index => try self.closeIndex(),
        .page => {
            if (self.selection == null) return;
            self.selection = null;
        },
    }
    self.notice = null;
    try self.draw();
}

fn mouse(self: *App, event: input.Mouse) Error!void {
    switch (event.action) {
        .wheel_up, .wheel_down => try self.wheel(event.action == .wheel_up),
        .press, .drag, .release => try self.selectText(event),
    }
}

/// Scrolls like `k` and `j`, or moves the index selection.
fn wheel(self: *App, up: bool) Error!void {
    self.parser.reset();
    self.notice = null;
    switch (self.mode) {
        .page => self.viewport.apply(if (up) .scroll_up else .scroll_down),
        .index => self.index.?.apply(if (up) .up else .down),
    }
    try self.draw();
}

/// A press starts a selection on the page shown, a drag extends it, and
/// the release copies its text. Redrawn after the read, by `run`.
fn selectText(self: *App, event: input.Mouse) Error!void {
    if (self.mode != .page) return;
    const image = self.shown orelse return;
    const point = self.pagePoint(event, image.scale);
    switch (event.action) {
        .press => {
            self.parser.reset();
            self.notice = null;
            self.selection = .{ .page = image.page, .anchor = point, .head = point, .dragging = true };
        },
        .drag, .release => {
            const selection = if (self.selection) |*selection| selection else return;
            if (!selection.dragging) return;
            if (selection.page != image.page) {
                // A key turned the page mid-drag.
                self.selection = null;
            } else {
                selection.head = point;
                if (event.action == .release) {
                    selection.dragging = false;
                    try self.copySelection();
                }
            }
        },
        .wheel_up, .wheel_down => unreachable, // `mouse` handles the wheel.
    }
    self.redraw = true;
}

/// Sends the finished selection's text to the clipboard. A click without a
/// drag, or a drag over no text, just drops the selection.
fn copySelection(self: *App) Error!void {
    const selection = self.selection.?;
    assert(!selection.dragging);
    if (selection.anchor.x == selection.head.x and selection.anchor.y == selection.head.y) {
        self.selection = null;
        return;
    }
    var text = self.doc.copy(selection.page, selection.anchor, selection.head) catch |err| switch (err) {
        error.TextFailed => {
            self.selection = null;
            self.notice = .{ .text = text_failed };
            return;
        },
    };
    defer text.deinit(self.doc);
    if (text.bytes.len == 0) {
        self.selection = null;
        self.notice = .{ .text = "no text selected" };
        return;
    }
    if (text.bytes.len > clipboard.bytes_max) {
        self.notice = .{ .text = "selection too long to copy" };
        return;
    }
    try clipboard.write(self.out, text.bytes);
    self.notice = .{ .copied = clipboard.countChars(text.bytes) };
}

const text_failed = "cannot read the text on this page";

/// The page position under a mouse report, through the image on screen.
fn pagePoint(self: *App, event: input.Mouse, scale: f32) Document.Point {
    assert(scale > 0);
    const pane: Viewport.Point = switch (self.mouse_units) {
        // Taken as 1-based like cells. A terminal counting from 0 puts the
        // point one pixel off, which no selection notices.
        .pixels => .{ .x = event.x -| 1, .y = event.y -| 1 },
        .cells => self.viewport.cellCentre(event.x, event.y),
    };
    const pixel = self.viewport.imagePoint(pane);
    // The pixel's centre.
    return .{
        .x = (@as(f32, @floatFromInt(pixel.x)) + 0.5) / scale,
        .y = (@as(f32, @floatFromInt(pixel.y)) + 0.5) / scale,
    };
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
                self.notice = .{ .text = "cannot read the table of contents" };
                return;
            },
        };
        if (items.len == 0) {
            self.notice = .{ .text = "no table of contents" };
            return;
        }
        self.index = .init(items);
    }
    self.index.?.reveal(self.viewport.page);
    self.mode = .index;
    self.parser.reset();
    // The index ignores the mouse, so an unfinished drag would never see
    // its release.
    if (self.selection) |selection| {
        if (selection.dragging) self.selection = null;
    }
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
        self.notice = .{ .text = "this entry points outside the document" };
        return;
    }
    const page: u32 = @intCast(item.page);
    const size = self.doc.pageSize(page) catch |err| switch (err) {
        // A damaged page should not end the session: the index stays open
        // so another entry can be picked.
        error.PageFailed => {
            self.notice = .{ .text = "cannot open this entry's page" };
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
    self.redraw = false;
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
        if (shown.id != image.id) try kitty.unplace(self.out, shown.id);
    }
    try self.out.print("\x1b[1;{d}H", .{crop.column});
    try kitty.place(self.out, image.id, crop.rect);
    self.shown = image;
    try self.drawHighlight(image);
}

/// Covers the selected text on the page shown, replacing any earlier
/// highlight. `fit` must have run for `image`.
fn drawHighlight(self: *App, image: PageCache.Entry) Error!void {
    try self.clearHighlight();
    const selection = self.selection orelse return;
    if (selection.page != image.page) return;
    var rects: [highlight_rects_max]Document.Rect = undefined;
    const found = self.doc.highlight(image.page, selection.anchor, selection.head, &rects) catch |err| switch (err) {
        error.TextFailed => {
            self.selection = null;
            self.notice = .{ .text = text_failed };
            return;
        },
    };
    if (found.len == 0) return;
    if (!self.highlight_sent) {
        try highlight.transmit(self.out, self.medium);
        self.highlight_sent = true;
    }
    var placement: u32 = 1;
    for (found) |rect| {
        const pane = self.viewport.paneRect(imageRect(rect, image)) orelse continue;
        placement = try highlight.place(self.out, pane, self.viewport.cell.width, self.viewport.cell.height, placement);
    }
    self.highlight_shown = placement > 1;
}

fn clearHighlight(self: *App) Error!void {
    if (!self.highlight_shown) return;
    try kitty.unplaceAll(self.out, .highlight);
    self.highlight_shown = false;
}

/// `rect`, in page points, as whole pixels of `image`: rounded outwards
/// and clamped to the image.
fn imageRect(rect: Document.Rect, image: PageCache.Entry) kitty.Rect {
    const x0 = toPixel(@floor(rect.x0 * image.scale), image.width);
    const y0 = toPixel(@floor(rect.y0 * image.scale), image.height);
    const x1 = toPixel(@ceil(rect.x1 * image.scale), image.width);
    const y1 = toPixel(@ceil(rect.y1 * image.scale), image.height);
    assert(x0 <= x1);
    assert(y0 <= y1);
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}

/// `value` clamped to 0 through `limit`. Handles an infinite product of a
/// huge coordinate and the scale.
fn toPixel(value: f32, limit: u32) u32 {
    if (!(value > 0)) return 0;
    if (value >= @as(f32, @floatFromInt(limit))) return limit;
    return @intFromFloat(value);
}

/// One entry per row above the status line. The page image is hidden but
/// stays in the terminal for when the index closes.
fn drawIndex(self: *App) Error!void {
    try self.clearHighlight();
    if (self.shown) |shown| {
        try kitty.unplace(self.out, shown.id);
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
        if (self.shown) |shown| {
            if (shown.id == id) self.shown = null;
        }
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
    if (self.notice) |notice| switch (notice) {
        .text => |text| status.print(" {s}", .{text}) catch {},
        .copied => |count| status.print(" copied {d} character{s}", .{ count, if (count == 1) "" else "s" }) catch {},
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

test imageRect {
    const image: PageCache.Entry = .{ .id = @fromBackingInt(3), .page = 0, .scale = 2, .width = 100, .height = 50 };
    try std.testing.expectEqual(
        kitty.Rect{ .x = 2, .y = 4, .width = 9, .height = 7 },
        imageRect(.{ .x0 = 1.2, .y0 = 2, .x1 = 5.4, .y1 = 5.1 }, image),
    );
    // Clamped to the image, including an infinite product.
    try std.testing.expectEqual(
        kitty.Rect{ .x = 0, .y = 40, .width = 100, .height = 10 },
        imageRect(.{ .x0 = -3, .y0 = 20, .x1 = std.math.floatMax(f32), .y1 = 99 }, image),
    );
    try std.testing.expectEqual(
        kitty.Rect{ .x = 100, .y = 50, .width = 0, .height = 0 },
        imageRect(.{ .x0 = 60, .y0 = 30, .x1 = 70, .y1 = 40 }, image),
    );
}
