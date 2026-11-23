//! Draws the text selection as translucent rectangles over the page.
//!
//! kitty shows an image at its native pixel size or stretched to whole
//! cells, so a rectangle of arbitrary pixel size cannot come from one small
//! scaled image. Instead one translucent tile is sent once, and each
//! rectangle is covered by placements of crops of it, one per tile-sized
//! piece. Selected lines are short and wide, so the tile is too.
const std = @import("std");
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const kitty = @import("kitty.zig");

pub const tile_width = 512;
pub const tile_height = 64;

/// Translucent blue, not premultiplied.
const colour = [4]u8{ 0x3d, 0x7e, 0xff, 0x60 };

/// Placements per frame, so a huge selection at a high zoom cannot flood
/// the terminal. A full pane of selected lines needs far fewer.
pub const placements_max = 1024;

/// Above the page image, which is at z 0.
const z = 1;

/// Sends the tile as image `kitty.ImageId.highlight`.
pub fn transmit(out: *Writer, medium: kitty.Medium) (Writer.Error || error{StoreFailed})!void {
    // 128 KiB on the stack, once per run.
    var pixels: [tile_width * tile_height * colour.len]u8 = undefined;
    for (0..tile_width * tile_height) |index| pixels[index * colour.len ..][0..colour.len].* = colour;
    const image: kitty.Image = .{ .pixels = &pixels, .width = tile_width, .height = tile_height, .format = .rgba };
    try kitty.transmit(out, medium, .highlight, image, .quiet);
}

/// One placement: a crop of the tile drawn at a pixel position.
pub const Tile = struct {
    /// 1-based cell holding the top-left pixel.
    row: u32,
    column: u32,
    offset: kitty.Offset,
    /// The crop of the tile.
    rect: kitty.Rect,
};

/// Splits a pane rectangle, in pixels, into tile placements, left to
/// right and then top to bottom.
pub const Tiles = struct {
    rect: kitty.Rect,
    cell_width: u32,
    cell_height: u32,
    /// The next tile's top-left corner, relative to `rect`.
    x: u32 = 0,
    y: u32 = 0,

    pub fn init(rect: kitty.Rect, cell_width: u32, cell_height: u32) Tiles {
        assert(cell_width > 0);
        assert(cell_height > 0);
        return .{ .rect = rect, .cell_width = cell_width, .cell_height = cell_height };
    }

    pub fn next(self: *Tiles) ?Tile {
        if (self.rect.width == 0 or self.y >= self.rect.height) return null;
        const x = self.rect.x + self.x;
        const y = self.rect.y + self.y;
        const width = @min(tile_width, self.rect.width - self.x);
        const height = @min(tile_height, self.rect.height - self.y);
        self.x += width;
        if (self.x >= self.rect.width) {
            self.x = 0;
            self.y += height;
        }
        return .{
            .row = y / self.cell_height + 1,
            .column = x / self.cell_width + 1,
            .offset = .{ .x = x % self.cell_width, .y = y % self.cell_height, .z = z },
            .rect = .{ .x = 0, .y = 0, .width = width, .height = height },
        };
    }
};

/// Places tiles covering `rect`, a pane rectangle in pixels, numbering the
/// placements from `placement`. Returns the next free number. Stops at
/// `placements_max`.
pub fn place(out: *Writer, rect: kitty.Rect, cell_width: u32, cell_height: u32, placement: u32) Writer.Error!u32 {
    assert(placement > 0);
    var next = placement;
    var tiles: Tiles = .init(rect, cell_width, cell_height);
    while (next <= placements_max) : (next += 1) {
        const tile = tiles.next() orelse break;
        try out.print("\x1b[{d};{d}H", .{ tile.row, tile.column });
        try kitty.placeOverlay(out, .highlight, next, tile.rect, tile.offset);
    }
    return next;
}

const testing = std.testing;

fn collect(rect: kitty.Rect, cell_width: u32, cell_height: u32, tiles: []Tile) ![]Tile {
    var iterator: Tiles = .init(rect, cell_width, cell_height);
    var len: usize = 0;
    while (iterator.next()) |tile| {
        try testing.expect(len < tiles.len);
        tiles[len] = tile;
        len += 1;
    }
    return tiles[0..len];
}

test "a small rectangle is one cropped tile with in-cell offsets" {
    var buffer: [4]Tile = undefined;
    const tiles = try collect(.{ .x = 25, .y = 47, .width = 100, .height = 12 }, 10, 20, &buffer);
    try testing.expectEqual(1, tiles.len);
    try testing.expectEqual(Tile{
        .row = 3,
        .column = 3,
        .offset = .{ .x = 5, .y = 7, .z = z },
        .rect = .{ .x = 0, .y = 0, .width = 100, .height = 12 },
    }, tiles[0]);
}

test "a large rectangle is covered by tiles without gaps or overlap" {
    var buffer: [16]Tile = undefined;
    const rect: kitty.Rect = .{ .x = 3, .y = 5, .width = tile_width * 2 + 7, .height = tile_height + 1 };
    const tiles = try collect(rect, 7, 13, &buffer);
    try testing.expectEqual(6, tiles.len);
    var area: u64 = 0;
    for (tiles, 0..) |tile, index| {
        const column = index % 3;
        const row = index / 3;
        const x = rect.x + @as(u32, @intCast(column)) * tile_width;
        const y = rect.y + @as(u32, @intCast(row)) * tile_height;
        try testing.expectEqual(x / 7 + 1, tile.column);
        try testing.expectEqual(x % 7, tile.offset.x);
        try testing.expectEqual(y / 13 + 1, tile.row);
        try testing.expectEqual(y % 13, tile.offset.y);
        area += @as(u64, tile.rect.width) * tile.rect.height;
    }
    try testing.expectEqual(@as(u64, rect.width) * rect.height, area);
}

test "place stops at the placement cap" {
    var buffer: [256]u8 = undefined;
    var out: Writer = .fixed(&buffer);
    const rect: kitty.Rect = .{ .x = 0, .y = 0, .width = tile_width * 2, .height = 1 };
    try testing.expectEqual(placements_max + 1, try place(&out, rect, 10, 20, placements_max));
    try testing.expectEqual(placements_max + 1, try place(&out, rect, 10, 20, placements_max + 1));
}
