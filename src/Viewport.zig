//! Which part of which page is on screen, and how commands move it.
//!
//! Pure state with no I/O. Offsets are pixels of the rendered page image.
//! Scroll limits come from the image on screen, so the caller must call
//! `fit` with the current page's image after every `apply`.
const Viewport = @This();

const std = @import("std");
const assert = std.debug.assert;
const Command = @import("input.zig").Command;
const Document = @import("Document.zig");
const Tty = @import("Tty.zig");
const kitty = @import("kitty.zig");

pub const zoom_step = 1.2;
pub const zoom_min = 0.1;
pub const zoom_max = 16.0;

/// Largest page image in bytes. Caps the zoom on large pages so a single
/// image cannot exhaust the terminal's image quota.
pub const image_bytes_max = 128 << 20;

/// Lines moved by `j` and `k`, and columns moved by `h` and `l`.
const scroll_cells = 3;

pub const Size = struct {
    width: u32,
    height: u32,
};

/// `rect` of the page image, drawn from the first row at `column` (1-based).
pub const Crop = struct {
    column: u32,
    rect: kitty.Rect,
};

page: u32,
page_count: u32,
/// Relative to fit-width: 1.0 makes the page as wide as the pane.
zoom: f32 = 1.0,
x: u32 = 0,
y: u32 = 0,
cell: Size,
/// The pane above the status line, in pixels.
area: Size,
/// The current page's rendered size, as last passed to `fit`.
image: Size = .{ .width = 0, .height = 0 },

pub fn init(page: u32, page_count: u32, pane: Tty.Size) Viewport {
    assert(page < page_count);
    var viewport: Viewport = .{
        .page = page,
        .page_count = page_count,
        .cell = undefined,
        .area = undefined,
    };
    viewport.resize(pane);
    return viewport;
}

pub fn resize(self: *Viewport, pane: Tty.Size) void {
    assert(pane.rows >= 2);
    self.cell = .{ .width = pane.cell_width, .height = pane.cell_height };
    self.area = .{
        .width = @as(u32, pane.cols) * pane.cell_width,
        .height = @as(u32, pane.rows - 1) * pane.cell_height,
    };
}

/// Render scale for the current page, in pixels per point. Lowers `zoom`
/// when the image would exceed `image_bytes_max`. The result is always
/// `zoom * fit_width`, so repeated calls return the same value and the page
/// cache keeps hitting.
pub fn scale(self: *Viewport, page: Document.PageSize) f32 {
    const fit_width = @as(f32, @floatFromInt(self.area.width)) / page.width;
    const scale_max = @sqrt(image_bytes_max / (3 * page.width * page.height));
    if (self.zoom * fit_width > scale_max) self.zoom = scale_max / fit_width;
    return self.zoom * fit_width;
}

/// Records the current page's rendered size, clamps the offsets to it, and
/// returns the part to show.
pub fn fit(self: *Viewport, image: Size) Crop {
    self.image = image;
    const width = @min(image.width, self.area.width);
    const height = @min(image.height, self.area.height);
    self.x = @min(self.x, image.width - width);
    self.y = @min(self.y, image.height - height);
    return .{
        // A page narrower than the pane is centred to the nearest cell.
        .column = (self.area.width - width) / 2 / self.cell.width + 1,
        .rect = .{ .x = self.x, .y = self.y, .width = width, .height = height },
    };
}

pub fn apply(self: *Viewport, command: Command) void {
    const line = scroll_cells * self.cell.height;
    const half_page = self.area.height / 2;
    switch (command) {
        .quit, .open_index => unreachable, // The caller handles them.
        .scroll_down => self.scrollDown(line),
        .scroll_up => self.scrollUp(line),
        .half_page_down => self.scrollDown(half_page),
        .half_page_up => self.scrollUp(half_page),
        .scroll_left => self.x -|= scroll_cells * self.cell.width,
        .scroll_right => self.x +|= scroll_cells * self.cell.width,
        .next_page => self.goTo(@min(self.page + 1, self.page_count - 1)),
        .previous_page => self.goTo(self.page -| 1),
        .first_page => self.goTo(0),
        .last_page => self.goTo(self.page_count - 1),
        .zoom_in => self.setZoom(self.zoom * zoom_step),
        .zoom_out => self.setZoom(self.zoom / zoom_step),
        .fit_width => {
            self.setZoom(1.0);
            self.x = 0;
        },
    }
}

/// Scrolls within the page, or moves to the top of the next page when
/// already at the bottom.
fn scrollDown(self: *Viewport, step: u32) void {
    const y_max = self.image.height -| self.area.height;
    if (self.y < y_max) {
        self.y = @min(self.y +| step, y_max);
    } else if (self.page + 1 < self.page_count) {
        self.page += 1;
        self.y = 0;
    }
}

/// Scrolls within the page, or moves to the bottom of the previous page
/// when already at the top.
fn scrollUp(self: *Viewport, step: u32) void {
    if (self.y > 0) {
        self.y -|= step;
    } else if (self.page > 0) {
        self.page -= 1;
        self.y = std.math.maxInt(u32); // `fit` clamps it to the bottom.
    }
}

fn goTo(self: *Viewport, page: u32) void {
    assert(page < self.page_count);
    if (page != self.page) self.y = 0;
    self.page = page;
}

/// Shows `page` from `y` pixels down its image at the current zoom. `fit`
/// clamps `y` to the image.
pub fn jump(self: *Viewport, page: u32, y: u32) void {
    assert(page < self.page_count);
    self.page = page;
    self.y = y;
}

/// Keeps the same point of the page at the top-left corner.
fn setZoom(self: *Viewport, zoom: f32) void {
    const clamped = std.math.clamp(zoom, zoom_min, zoom_max);
    const ratio = clamped / self.zoom;
    self.x = @intFromFloat(@as(f32, @floatFromInt(self.x)) * ratio);
    self.y = @intFromFloat(@as(f32, @floatFromInt(self.y)) * ratio);
    self.zoom = clamped;
}

const testing = std.testing;

/// A 100x200 px page area: 10 columns and 10 page rows of 10x20 px cells.
fn testViewport(page: u32) Viewport {
    const pane: Tty.Size = .{ .rows = 11, .cols = 10, .cell_width = 10, .cell_height = 20 };
    return .init(page, 5, pane);
}

test "the status line row is not part of the area" {
    const viewport = testViewport(0);
    try testing.expectEqual(Size{ .width = 100, .height = 200 }, viewport.area);
}

test "scrolling down stops at the page bottom, then turns the page" {
    var viewport = testViewport(0);
    _ = viewport.fit(.{ .width = 100, .height = 350 });
    viewport.apply(.half_page_down);
    try testing.expectEqual(100, viewport.y);
    viewport.apply(.half_page_down);
    try testing.expectEqual(150, viewport.y);
    try testing.expectEqual(0, viewport.page);
    viewport.apply(.scroll_down);
    try testing.expectEqual(1, viewport.page);
    try testing.expectEqual(0, viewport.y);
}

test "scrolling up from the top shows the bottom of the previous page" {
    var viewport = testViewport(2);
    _ = viewport.fit(.{ .width = 100, .height = 300 });
    viewport.apply(.scroll_up);
    try testing.expectEqual(1, viewport.page);
    const crop = viewport.fit(.{ .width = 100, .height = 300 });
    try testing.expectEqual(100, crop.rect.y);
    try testing.expectEqual(200, crop.rect.height);
}

test "scrolling stops at the first and last page" {
    var viewport = testViewport(0);
    _ = viewport.fit(.{ .width = 100, .height = 200 });
    viewport.apply(.scroll_up);
    try testing.expectEqual(0, viewport.page);
    viewport.apply(.last_page);
    viewport.apply(.scroll_down);
    viewport.apply(.next_page);
    try testing.expectEqual(4, viewport.page);
}

test "page jumps reset the vertical offset" {
    var viewport = testViewport(1);
    _ = viewport.fit(.{ .width = 100, .height = 300 });
    viewport.apply(.scroll_down);
    viewport.apply(.next_page);
    try testing.expectEqual(2, viewport.page);
    try testing.expectEqual(0, viewport.y);
    viewport.apply(.first_page);
    try testing.expectEqual(0, viewport.page);
}

test "fit clamps horizontal scrolling and centres narrow pages" {
    var viewport = testViewport(0);
    for (0..10) |_| viewport.apply(.scroll_right);
    const wide = viewport.fit(.{ .width = 150, .height = 200 });
    try testing.expectEqual(50, wide.rect.x);
    try testing.expectEqual(1, wide.column);

    const narrow = viewport.fit(.{ .width = 40, .height = 200 });
    try testing.expectEqual(0, narrow.rect.x);
    try testing.expectEqual(40, narrow.rect.width);
    try testing.expectEqual(4, narrow.column);
}

test "zoom keeps the top-left point and fit-width resets it" {
    var viewport = testViewport(0);
    _ = viewport.fit(.{ .width = 100, .height = 400 });
    viewport.apply(.scroll_down);
    viewport.apply(.zoom_in);
    try testing.expectApproxEqAbs(1.2, viewport.zoom, 1e-6);
    try testing.expectEqual(72, viewport.y);
    viewport.apply(.fit_width);
    try testing.expectEqual(1.0, viewport.zoom);
    try testing.expectEqual(0, viewport.x);
}

test "scale fits the page width and caps large images" {
    var viewport = testViewport(0);
    const a4: Document.PageSize = .{ .width = 595, .height = 842 };
    try testing.expectApproxEqAbs(100.0 / 595.0, viewport.scale(a4), 1e-6);

    viewport.zoom = zoom_max;
    const huge: Document.PageSize = .{ .width = 10, .height = 10_000 };
    const capped = viewport.scale(huge);
    try testing.expect(viewport.zoom < zoom_max);
    try testing.expectEqual(capped, viewport.scale(huge));
    const bytes = 3 * (10 * capped) * (10_000 * capped);
    try testing.expect(bytes <= image_bytes_max * 1.001);
}

test "jump keeps the horizontal offset and fit clamps the target" {
    var viewport = testViewport(0);
    _ = viewport.fit(.{ .width = 150, .height = 300 });
    viewport.apply(.scroll_right);
    viewport.jump(3, 1000);
    try testing.expectEqual(3, viewport.page);
    const crop = viewport.fit(.{ .width = 150, .height = 300 });
    try testing.expectEqual(100, crop.rect.y);
    try testing.expectEqual(30, crop.rect.x);
}
