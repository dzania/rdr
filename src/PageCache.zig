//! Page images held by the terminal, keyed by page and render scale.
//!
//! A full-pane page image is 8 to 17 MB and the terminal's image quota is
//! finite, so at most `capacity` images are kept: about the current page and
//! its neighbours. The least recently used one is evicted.
const PageCache = @This();

const std = @import("std");
const kitty = @import("kitty.zig");

pub const capacity = 3;

pub const Entry = struct {
    id: kitty.ImageId,
    page: u32,
    scale: f32,
    width: u32,
    height: u32,
};

/// Most recently used first; empty slots are at the end.
entries: [capacity]?Entry = @splat(null),
next_id: u32 = @backingInt(kitty.ImageId.highlight) + 1,

pub fn get(self: *PageCache, page: u32, scale: f32) ?Entry {
    for (self.entries, 0..) |slot, index| {
        const entry = slot orelse return null;
        if (entry.page == page and entry.scale == scale) {
            std.mem.rotate(?Entry, self.entries[0 .. index + 1], index);
            return entry;
        }
    }
    return null;
}

/// Adds the image of `page` at `scale` under a fresh id and returns it with
/// the evicted image, if any. The caller transmits the new image and deletes
/// the evicted one.
pub fn insert(self: *PageCache, page: u32, scale: f32, width: u32, height: u32) struct { Entry, ?kitty.ImageId } {
    const evicted = if (self.entries[capacity - 1]) |old| old.id else null;
    std.mem.copyBackwards(?Entry, self.entries[1..], self.entries[0 .. capacity - 1]);
    const entry: Entry = .{ .id = @fromBackingInt(self.next_id), .page = page, .scale = scale, .width = width, .height = height };
    self.next_id += 1;
    self.entries[0] = entry;
    return .{ entry, evicted };
}

const testing = std.testing;

test "get finds an image only at the same page and scale" {
    var cache: PageCache = .{};
    const entry, const evicted = cache.insert(4, 1.5, 100, 200);
    try testing.expectEqual(null, evicted);
    try testing.expectEqual(entry.id, cache.get(4, 1.5).?.id);
    try testing.expectEqual(null, cache.get(4, 2.0));
    try testing.expectEqual(null, cache.get(5, 1.5));
}

test "ids are fresh and never a reserved id" {
    var cache: PageCache = .{};
    const first = cache.insert(0, 1, 1, 1)[0].id;
    const second = cache.insert(1, 1, 1, 1)[0].id;
    try testing.expect(first != kitty.ImageId.probe);
    try testing.expect(first != kitty.ImageId.highlight);
    try testing.expect(first != second);
}

test "a full cache evicts the least recently used image" {
    var cache: PageCache = .{};
    const page0 = cache.insert(0, 1, 1, 1)[0].id;
    const page1 = cache.insert(1, 1, 1, 1)[0].id;
    _ = cache.insert(2, 1, 1, 1);
    _ = cache.get(0, 1); // Page 1 is now the oldest.

    try testing.expectEqual(page1, cache.insert(3, 1, 1, 1)[1]);
    try testing.expectEqual(null, cache.get(1, 1));
    try testing.expectEqual(page0, cache.get(0, 1).?.id);
}
