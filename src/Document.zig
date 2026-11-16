//! A document opened with MuPDF through the C shim in `shim.c`.
const Document = @This();

const std = @import("std");
const assert = std.debug.assert;
const shim = @import("shim");

handle: *shim.doc,
page_count: u32,

pub const OpenError = error{ OutOfMemory, OpenFailed };
pub const Error = error{ OutOfMemory, PageFailed, RenderFailed };

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

fn check(status: c_int) Error!void {
    return switch (status) {
        shim.DOC_OK => {},
        shim.DOC_E_NOMEM => error.OutOfMemory,
        shim.DOC_E_PAGE => error.PageFailed,
        shim.DOC_E_RENDER => error.RenderFailed,
        else => unreachable, // doc_page_size and doc_render return no other status.
    };
}
