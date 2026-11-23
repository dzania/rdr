//! A document opened with MuPDF through the C shim in `shim.c`.
const Document = @This();

const std = @import("std");
const assert = std.debug.assert;
const shim = @import("shim");

handle: *shim.doc,
page_count: u32,

pub const OpenError = error{ OutOfMemory, OpenFailed };
pub const Error = error{ OutOfMemory, PageFailed, RenderFailed };
pub const OutlineError = error{ OutOfMemory, OutlineFailed };
/// MuPDF could not extract the page's text.
pub const TextError = error{TextFailed};

/// A position on a page in points from its top-left corner, the space
/// `pageSize` measures. Multiply by a render scale to get image pixels.
pub const Point = shim.doc_point;
/// An area of a page in the same space as `Point`.
pub const Rect = shim.doc_rect;

/// Selected text: NUL-terminated UTF-8 owned by MuPDF.
pub const Text = struct {
    bytes: [:0]const u8,
    raw: [*c]u8,

    pub fn deinit(self: *Text, doc: Document) void {
        shim.doc_text_drop(doc.handle, self.raw);
        self.* = undefined;
    }
};

/// A table of contents entry. See `doc_outline_item` in `shim.h`.
pub const OutlineItem = shim.doc_outline_item;

/// Page size in points (1/72 inch).
pub const PageSize = struct {
    width: f32,
    height: f32,
};

/// A rendered page: packed 8-bit RGB, 3 bytes per pixel, no row padding.
pub const Pixmap = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
    raw: shim.doc_pixmap,

    pub fn deinit(self: *Pixmap, doc: Document) void {
        shim.doc_pixmap_drop(doc.handle, &self.raw);
    }
};

/// Opens `path`. On failure, MuPDF's reason is left in `message` as a
/// NUL-terminated string.
pub fn open(path: [:0]const u8, message: []u8) OpenError!Document {
    var handle: ?*shim.doc = null;
    var page_count: c_int = 0;
    switch (shim.doc_open(path.ptr, &handle, &page_count, message.ptr, message.len)) {
        shim.DOC_OK => {},
        shim.DOC_E_NOMEM => return error.OutOfMemory,
        else => return error.OpenFailed,
    }
    assert(page_count >= 1);
    return .{ .handle = handle.?, .page_count = @intCast(page_count) };
}

pub fn close(self: Document) void {
    shim.doc_close(self.handle);
}

pub fn pageSize(self: Document, page: u32) Error!PageSize {
    assert(page < self.page_count);
    var size: PageSize = undefined;
    try check(shim.doc_page_size(self.handle, @intCast(page), &size.width, &size.height));
    assert(size.width > 0);
    assert(size.height > 0);
    return size;
}

/// The table of contents in reading order, empty if the document has none.
/// Loaded on the first call; the items live until `close`. Their `open`
/// fields belong to the caller.
pub fn outline(self: Document) OutlineError![]OutlineItem {
    var items: [*c]OutlineItem = null;
    var count: c_int = 0;
    switch (shim.doc_outline(self.handle, &items, &count)) {
        shim.DOC_OK => {},
        shim.DOC_E_NOMEM => return error.OutOfMemory,
        shim.DOC_E_OUTLINE => return error.OutlineFailed,
        else => unreachable, // doc_outline returns no other status.
    }
    assert(count >= 0);
    assert(count <= shim.DOC_OUTLINE_ITEMS_MAX);
    if (count == 0) return &.{};
    const result = items[0..@intCast(count)];
    for (result) |item| {
        assert(item.title != null);
        assert(item.page >= -1);
        assert(item.page < self.page_count);
        assert(item.y >= 0);
    }
    return result;
}

/// Renders `page` at `scale` pixels per point. Release with `Pixmap.deinit`.
pub fn render(self: Document, page: u32, scale: f32) Error!Pixmap {
    assert(page < self.page_count);
    assert(scale > 0);
    var raw: shim.doc_pixmap = undefined;
    try check(shim.doc_render(self.handle, @intCast(page), scale, &raw));
    const width: u32 = @intCast(raw.w);
    const height: u32 = @intCast(raw.h);
    assert(width > 0);
    assert(height > 0);
    return .{ .pixels = raw.samples[0 .. @as(usize, width) * height * 3], .width = width, .height = height, .raw = raw };
}

/// Rectangles covering the text from `a` to `b` on `page` in reading order,
/// roughly one per line. A selection needing more than `rects.len` is cut
/// short. Extracts the page's text on the first call for that page.
pub fn highlight(self: Document, page: u32, a: Point, b: Point, rects: []Rect) TextError![]Rect {
    assert(page < self.page_count);
    assert(rects.len > 0);
    assert(rects.len <= std.math.maxInt(c_int));
    assertFinite(a);
    assertFinite(b);
    var count: c_int = 0;
    try checkText(shim.doc_highlight(self.handle, @intCast(page), a, b, rects.ptr, @intCast(rects.len), &count));
    assert(count >= 0);
    assert(count <= rects.len);
    const result = rects[0..@intCast(count)];
    for (result) |rect| {
        assert(rect.x0 <= rect.x1);
        assert(rect.y0 <= rect.y1);
    }
    return result;
}

/// The text from `a` to `b` on `page` in reading order, with "\n" line
/// endings; empty when the selection holds no text. Release with
/// `Text.deinit`.
pub fn copy(self: Document, page: u32, a: Point, b: Point) TextError!Text {
    assert(page < self.page_count);
    assertFinite(a);
    assertFinite(b);
    var raw: [*c]u8 = null;
    try checkText(shim.doc_copy(self.handle, @intCast(page), a, b, &raw));
    assert(raw != null);
    return .{ .bytes = std.mem.span(@as([*:0]const u8, @ptrCast(raw))), .raw = raw };
}

fn assertFinite(point: Point) void {
    assert(std.math.isFinite(point.x));
    assert(std.math.isFinite(point.y));
}

fn checkText(status: c_int) TextError!void {
    return switch (status) {
        shim.DOC_OK => {},
        shim.DOC_E_TEXT => error.TextFailed,
        else => unreachable, // doc_highlight and doc_copy return no other status.
    };
}

fn check(status: c_int) Error!void {
    return switch (status) {
        shim.DOC_OK => {},
        shim.DOC_E_NOMEM => error.OutOfMemory,
        shim.DOC_E_PAGE => error.PageFailed,
        shim.DOC_E_RENDER => error.RenderFailed,
        else => unreachable, // doc_page_size and doc_render return no other status.
    };
}
