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
    return self.shownCrop();
}

/// The part of the image on screen, as `fit` last returned it.
fn shownCrop(self: Viewport) Crop {
    assert(self.image.width > 0);
    assert(self.image.height > 0);
    const width = @min(self.image.width, self.area.width);
    const height = @min(self.image.height, self.area.height);
    assert(self.x + width <= self.image.width);
    assert(self.y + height <= self.image.height);
    return .{
        // A page narrower than the pane is centred to the nearest cell.
        .column = (self.area.width - width) / 2 / self.cell.width + 1,
        .rect = .{ .x = self.x, .y = self.y, .width = width, .height = height },
    };
}

/// A position on the pane in pixels from its top-left corner.
pub const Point = struct {
    x: u32,
    y: u32,
};

/// The centre of the cell at 1-based `column` and `row`.
pub fn cellCentre(self: Viewport, column: u32, row: u32) Point {
    return .{
        .x = (column -| 1) *| self.cell.width +| self.cell.width / 2,
        .y = (row -| 1) *| self.cell.height +| self.cell.height / 2,
    };
}

/// The image pixel under `point`, clamped to the part of the image on
/// screen, so a point beside the page or on the status line gives the
/// nearest pixel shown. `fit` must have run.
pub fn imagePoint(self: Viewport, point: Point) Point {
    const shown = self.shownCrop();
    const left = (shown.column - 1) * self.cell.width;
    const x = std.math.clamp(point.x, left, left + shown.rect.width - 1) - left;
    const y = @min(point.y, shown.rect.height - 1);
    return .{ .x = shown.rect.x + x, .y = shown.rect.y + y };
}

/// The part of `rect`, in image pixels, that is on screen, in pane pixels.
/// Null if none of it is. `fit` must have run.
pub fn paneRect(self: Viewport, rect: kitty.Rect) ?kitty.Rect {
    const shown = self.shownCrop();
    const x0 = @max(rect.x, shown.rect.x);
    const y0 = @max(rect.y, shown.rect.y);
    const x1 = @min(rect.x +| rect.width, shown.rect.x + shown.rect.width);
    const y1 = @min(rect.y +| rect.height, shown.rect.y + shown.rect.height);
    if (x0 >= x1 or y0 >= y1) return null;
    const left = (shown.column - 1) * self.cell.width;
    const result: kitty.Rect = .{ .x = left + x0 - shown.rect.x, .y = y0 - shown.rect.y, .width = x1 - x0, .height = y1 - y0 };
    assert(result.x + result.width <= self.area.width);
    assert(result.y + result.height <= self.area.height);
    return result;
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

test "imagePoint follows the scroll offset and clamps to the crop" {
    var viewport = testViewport(0);
    _ = viewport.fit(.{ .width = 150, .height = 300 });
    viewport.apply(.scroll_right);
    viewport.apply(.scroll_down);
    _ = viewport.fit(.{ .width = 150, .height = 300 });
    try testing.expectEqual(Point{ .x = 30 + 12, .y = 60 + 34 }, viewport.imagePoint(.{ .x = 12, .y = 34 }));
    // The status line row and beyond clamp to the last shown pixel.
    try testing.expectEqual(Point{ .x = 30 + 99, .y = 60 + 199 }, viewport.imagePoint(.{ .x = 500, .y = 205 }));
}

test "imagePoint and paneRect account for a centred page" {
    var viewport = testViewport(0);
    // 40 px wide in a 100 px area: drawn from column 4, pixel 30.
    _ = viewport.fit(.{ .width = 40, .height = 100 });
    try testing.expectEqual(Point{ .x = 0, .y = 0 }, viewport.imagePoint(.{ .x = 0, .y = 0 }));
    try testing.expectEqual(Point{ .x = 5, .y = 7 }, viewport.imagePoint(.{ .x = 35, .y = 7 }));
    try testing.expectEqual(Point{ .x = 39, .y = 99 }, viewport.imagePoint(.{ .x = 99, .y = 150 }));
    const rect = viewport.paneRect(.{ .x = 5, .y = 7, .width = 10, .height = 3 }).?;
    try testing.expectEqual(kitty.Rect{ .x = 35, .y = 7, .width = 10, .height = 3 }, rect);
}

test "paneRect clips to the crop and drops what is off screen" {
    var viewport = testViewport(0);
    _ = viewport.fit(.{ .width = 150, .height = 300 });
    viewport.apply(.half_page_down);
    _ = viewport.fit(.{ .width = 150, .height = 300 });
    // Shown: x 0..100, y 100..300.
    const clipped = viewport.paneRect(.{ .x = 90, .y = 90, .width = 20, .height = 20 }).?;
    try testing.expectEqual(kitty.Rect{ .x = 90, .y = 0, .width = 10, .height = 10 }, clipped);
    try testing.expectEqual(null, viewport.paneRect(.{ .x = 0, .y = 0, .width = 100, .height = 100 }));
    try testing.expectEqual(null, viewport.paneRect(.{ .x = 100, .y = 150, .width = 50, .height = 10 }));
    try testing.expectEqual(null, viewport.paneRect(.{ .x = 10, .y = 150, .width = 0, .height = 10 }));
}
