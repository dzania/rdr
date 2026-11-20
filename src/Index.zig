//! The table of contents view: which entries are expanded, which one is
//! selected, and which one is in the top row.
//!
//! Pure state with no I/O. The outline is a flat pre-order list (see
//! `doc_outline_item` in `shim.h`), so an entry's children are the deeper
//! entries right after it and no tree has to be built. An entry is visible
//! when all its ancestors are expanded. Moves walk the list, so each costs
//! at most one pass over it.
const Index = @This();

const std = @import("std");
const assert = std.debug.assert;
const Command = @import("input.zig").IndexCommand;
const Document = @import("Document.zig");

const Item = Document.OutlineItem;

/// Not empty. The `open` fields are this view's expanded flags.
items: []Item,
/// Always visible.
selected: usize = 0,
/// The entry in the top row. Always visible.
top: usize = 0,

pub fn init(items: []Item) Index {
    assert(items.len > 0);
    assert(items[0].depth == 0);
    for (items[0 .. items.len - 1], items[1..]) |item, next| {
        assert(next.depth >= 0);
        assert(next.depth <= item.depth + 1);
    }
    return .{ .items = items };
}

/// Selects the entry with the latest start at or before `page`, expanding
/// its ancestors so it shows. Of entries on the same page, the last one in
/// reading order wins, which is the innermost for a nested outline. Keeps
/// the selection if no entry qualifies. Outlines need not be in page order:
/// a cover or index can point far ahead of the entries after it.
pub fn reveal(self: *Index, page: u32) void {
    var found: ?usize = null;
    for (self.items, 0..) |item, index| {
        if (item.page < 0) continue;
        if (item.page > page) continue;
        if (found) |best| {
            if (item.page < self.items[best].page) continue;
        }
        found = index;
    }
    const target = found orelse return;
    var child = target;
    while (self.parent(child)) |ancestor| : (child = ancestor) self.items[ancestor].open = 1;
    self.selected = target;
}

pub fn apply(self: *Index, command: Command) void {
    switch (command) {
        .quit, .close, .select => unreachable, // The caller handles them.
        .down => self.selected = self.nextVisible(self.selected) orelse self.selected,
        .up => self.selected = self.previousVisible(self.selected) orelse self.selected,
        .collapse => {
            if (self.isExpanded(self.selected)) {
                self.items[self.selected].open = 0;
            } else if (self.parent(self.selected)) |up| {
                self.selected = up;
            }
        },
        .expand => {
            if (self.hasChildren(self.selected)) self.items[self.selected].open = 1;
        },
        .collapse_all => {
            for (self.items) |*item| item.open = 0;
            self.selected = self.visibleAncestor(self.selected);
            self.top = self.visibleAncestor(self.top);
        },
        .expand_all => for (self.items) |*item| {
            item.open = 1;
        },
        .first => self.selected = 0,
        .last => self.selected = self.lastVisible(),
    }
    // Collapsing can hide the top row, never the selection.
    self.top = self.visibleAncestor(self.top);
    assert(self.visibleAncestor(self.selected) == self.selected);
}

pub fn selectedItem(self: Index) Item {
    return self.items[self.selected];
}

/// Moves `top` so the selection is within `rows` rows of it.
///
/// Walks forward only: `lead` goes from `top` to the selection, and the new
/// `top` trails it by at most `rows - 1` rows. Each `nextVisible` call moves
/// forward past what it scans, so both walks together read each entry at
/// most twice. Walking back with `previousVisible` instead would scan for a
/// parent on every step, which is quadratic in a wide, flat outline.
pub fn scrollIntoView(self: *Index, rows: usize) void {
    assert(rows > 0);
    if (self.selected < self.top) {
        self.top = self.selected;
        return;
    }
    var lead = self.top;
    var trail = self.top;
    // Rows from `trail` down to `lead`.
    var distance: usize = 0;
    while (lead != self.selected) {
        // Both are visible and the selection is after `lead`.
        lead = self.nextVisible(lead) orelse unreachable;
        assert(lead <= self.selected);
        if (distance + 1 < rows) {
            distance += 1;
        } else {
            trail = self.nextVisible(trail) orelse unreachable; // `lead` is after it.
        }
    }
    assert(distance < rows);
    self.top = trail;
}

pub fn hasChildren(self: Index, index: usize) bool {
    assert(index < self.items.len);
    return index + 1 < self.items.len and self.items[index + 1].depth > self.items[index].depth;
}

pub fn isExpanded(self: Index, index: usize) bool {
    return self.hasChildren(index) and self.items[index].open != 0;
}

/// The visible entry after `index`, which must be visible.
pub fn nextVisible(self: Index, index: usize) ?usize {
    if (self.isExpanded(index)) return index + 1;
    // Skip the hidden subtree. The next entry at the same depth or above
    // shares the visible ancestors of `index`, so it is visible.
    var next = index + 1;
    while (next < self.items.len and self.items[next].depth > self.items[index].depth) next += 1;
    return if (next < self.items.len) next else null;
}

fn previousVisible(self: Index, index: usize) ?usize {
    if (index == 0) return null;
    return self.visibleAncestor(index - 1);
}

fn lastVisible(self: Index) usize {
    return self.visibleAncestor(self.items.len - 1);
}

/// `index` if it is visible, or else its outermost collapsed ancestor,
/// which is: every ancestor above that one is expanded.
fn visibleAncestor(self: Index, index: usize) usize {
    var result = index;
    var child = index;
    while (self.parent(child)) |ancestor| : (child = ancestor) {
        if (self.items[ancestor].open == 0) result = ancestor;
    }
    return result;
}

fn parent(self: Index, index: usize) ?usize {
    const depth = self.items[index].depth;
    if (depth == 0) return null;
    var candidate = index;
    while (candidate > 0) {
        candidate -= 1;
        if (self.items[candidate].depth < depth) return candidate;
    }
    unreachable; // The first entry has depth 0.
}

const testing = std.testing;

/// 0 Part 1          p1
/// 1   Chapter 1     p2
/// 2     Section 1.1 p3
/// 3   Chapter 2     p5
/// 4 Part 2          p7
/// 5   Chapter 3     -
/// 6 Appendix        p9
fn testItems() [7]Item {
    const shape = [_]struct { c_int, c_int }{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 }, .{ 1, 4 }, .{ 0, 6 }, .{ 1, -1 }, .{ 0, 8 } };
    var items: [shape.len]Item = undefined;
    for (&items, shape) |*item, entry| {
        item.* = .{ .title = "", .page = entry[1], .y = 0, .depth = entry[0], .open = 0 };
    }
    return items;
}

test "collapsed entries hide their children" {
    var items = testItems();
    var index: Index = .init(&items);
    index.apply(.down);
    try testing.expectEqual(4, index.selected);
    index.apply(.down);
    index.apply(.down);
    try testing.expectEqual(6, index.selected);
    index.apply(.up);
    try testing.expectEqual(4, index.selected);
    index.apply(.first);
    index.apply(.up);
    try testing.expectEqual(0, index.selected);
}

test "expand and collapse" {
    var items = testItems();
    var index: Index = .init(&items);
    index.apply(.expand);
    index.apply(.down);
    try testing.expectEqual(1, index.selected);
    index.apply(.expand);
    index.apply(.down);
    try testing.expectEqual(2, index.selected);

    // A leaf has nothing to expand or collapse: h selects the parent.
    index.apply(.expand);
    index.apply(.collapse);
    try testing.expectEqual(1, index.selected);
    index.apply(.collapse);
    try testing.expectEqual(1, index.selected);
    index.apply(.down);
    try testing.expectEqual(3, index.selected);
    index.apply(.up);
    index.apply(.up);
    try testing.expectEqual(0, index.selected);
}

test "collapse all moves the selection to its top-level entry" {
    var items = testItems();
    var index: Index = .init(&items);
    index.apply(.expand_all);
    index.apply(.last);
    try testing.expectEqual(6, index.selected);
    index.apply(.up);
    try testing.expectEqual(5, index.selected);
    index.apply(.collapse_all);
    try testing.expectEqual(4, index.selected);
    index.apply(.first);
    index.apply(.last);
    try testing.expectEqual(6, index.selected);
}

test "reveal selects the entry for a page and expands its ancestors" {
    var items = testItems();
    var index: Index = .init(&items);
    index.reveal(3);
    try testing.expectEqual(2, index.selected);
    try testing.expect(index.isExpanded(0));
    try testing.expect(index.isExpanded(1));
    try testing.expect(!index.isExpanded(4));

    // Entries without a page are skipped.
    index.reveal(7);
    try testing.expectEqual(4, index.selected);
    index.reveal(0);
    try testing.expectEqual(0, index.selected);
}

test "reveal handles an outline out of page order" {
    // 0 Cover     p1
    // 1 Index     p300
    // 2 Chapter 1 p5
    // 3 Chapter 2 p20
    // 4 Glossary  p2
    var items: [5]Item = undefined;
    for (&items, [_]c_int{ 0, 299, 4, 19, 1 }) |*item, page| {
        item.* = .{ .title = "", .page = page, .y = 0, .depth = 0, .open = 0 };
    }
    var index: Index = .init(&items);
    index.reveal(24);
    try testing.expectEqual(3, index.selected);
    index.reveal(299);
    try testing.expectEqual(1, index.selected);
    index.reveal(2);
    try testing.expectEqual(4, index.selected);
    index.reveal(0);
    try testing.expectEqual(0, index.selected);

    // No entry starts at or before page 0 here, so the selection stays.
    items[0].page = 3;
    index.selected = 2;
    index.reveal(0);
    try testing.expectEqual(2, index.selected);
}

test "scrolling keeps the selection on screen" {
    var items = testItems();
    var index: Index = .init(&items);
    index.apply(.expand_all);
    index.scrollIntoView(3);
    try testing.expectEqual(0, index.top);
    index.apply(.last);
    index.scrollIntoView(3);
    try testing.expectEqual(4, index.top);
    index.apply(.up);
    index.apply(.up);
    index.scrollIntoView(3);
    try testing.expectEqual(4, index.top);
    index.apply(.up);
    index.scrollIntoView(3);
    try testing.expectEqual(3, index.top);
    index.apply(.first);
    index.scrollIntoView(3);
    try testing.expectEqual(0, index.top);
}

test "scrolling skips collapsed entries" {
    var items = testItems();
    var index: Index = .init(&items);
    // Visible: 0, 4, 6.
    index.apply(.last);
    index.scrollIntoView(2);
    try testing.expectEqual(4, index.top);
    index.scrollIntoView(1);
    try testing.expectEqual(6, index.top);
    index.scrollIntoView(5);
    try testing.expectEqual(6, index.top);
}

test "scrolling a wide outline takes one pass" {
    // One root with the most children the shim allows. Walking back from
    // the last child to the root used to scan for a parent on every step,
    // about 2e9 reads, which hangs this test.
    const items = try testing.allocator.alloc(Item, 65536);
    defer testing.allocator.free(items);
    for (items, 0..) |*item, position| {
        const depth: c_int = if (position == 0) 0 else 1;
        item.* = .{ .title = "", .page = 0, .y = 0, .depth = depth, .open = 0 };
    }
    var index: Index = .init(items);
    index.apply(.expand);
    index.apply(.last);
    try testing.expectEqual(items.len - 1, index.selected);
    index.scrollIntoView(40);
    try testing.expectEqual(items.len - 40, index.top);
    // Tab on a late page reveals its entry while `top` is still the root.
    index.top = 0;
    index.reveal(0);
    index.scrollIntoView(40);
    try testing.expectEqual(items.len - 40, index.top);
}

test "collapsing the top row's parent keeps the top row visible" {
    var items = testItems();
    var index: Index = .init(&items);
    index.apply(.expand_all);
    index.reveal(2);
    index.top = 2;
    index.apply(.collapse_all);
    try testing.expectEqual(0, index.top);
    try testing.expectEqual(0, index.selected);
}

test "a single entry" {
    var items = [_]Item{.{ .title = "", .page = 0, .y = 0, .depth = 0, .open = 1 }};
    var index: Index = .init(&items);
    for (std.enums.values(Command)) |command| switch (command) {
        .quit, .close, .select => {},
        else => index.apply(command),
    };
    index.scrollIntoView(1);
    try testing.expectEqual(0, index.selected);
    try testing.expectEqual(0, index.top);
    try testing.expect(!index.isExpanded(0));
}
