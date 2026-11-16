//! Runs the viewer: applies commands to the viewport and keeps the terminal
//! showing the right crop of the right page image.
const App = @This();

const std = @import("std");
const Document = @import("Document.zig");
const PageCache = @import("PageCache.zig");
const Tty = @import("Tty.zig");
const Viewport = @import("Viewport.zig");
const input = @import("input.zig");
const kitty = @import("kitty.zig");

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
    var parser: input.Parser = .{};
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
            // Escape sequences (arrow keys, stray replies) are dropped whole
            // so their bytes are not taken for commands.
            if (bytes[0] == 0x1b) continue;
            for (bytes) |byte| {
                const command = parser.feed(byte) orelse continue;
                if (command == .quit) return;
                self.viewport.apply(command);
                try self.draw();
            }
        },
    };
}

fn resize(self: *App) Error!void {
    self.size = try self.tty.size();
    self.viewport.resize(self.size);
    // Erase stale text such as the old status line, one row at a time:
    // clearing the screen with ED would also delete the images.
    try self.out.writeAll("\x1b[H");
    for (0..self.size.rows) |_| try self.out.writeAll("\x1b[2K\x1b[B");
}

fn draw(self: *App) Error!void {
    const image = try self.pageImage();
    const crop = self.viewport.fit(.{ .width = image.width, .height = image.height });
    if (self.shown) |shown| {
        if (shown != image.id) try kitty.unplace(self.out, shown);
    }
    try self.out.print("\x1b[1;{d}H", .{crop.column});
    try kitty.place(self.out, image.id, crop.rect);
    try self.drawStatus();
    try self.out.flush();
    self.shown = image.id;
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
    status.print(" {s}  {d} / {d}  {d:.0}%", .{
        self.title,
        self.viewport.page + 1,
        self.viewport.page_count,
        self.viewport.zoom * 100,
    }) catch {};
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
