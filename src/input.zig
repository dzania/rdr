//! Turns key bytes into commands. Bindings follow zathura and vim.

pub const Command = enum {
    quit,
    scroll_down,
    scroll_up,
    half_page_down,
    half_page_up,
    scroll_left,
    scroll_right,
    next_page,
    previous_page,
    first_page,
    last_page,
    zoom_in,
    zoom_out,
    fit_width,
};

const ctrl_c = 0x03;

pub const Parser = struct {
    /// A `g` was typed and a second one would complete `gg`.
    pending_g: bool = false,

    pub fn feed(self: *Parser, byte: u8) ?Command {
        if (self.pending_g) {
            self.pending_g = false;
            if (byte == 'g') return .first_page;
        }
        return switch (byte) {
            'q', ctrl_c => .quit,
            'j' => .scroll_down,
            'k' => .scroll_up,
            'd' => .half_page_down,
            'u' => .half_page_up,
            'h' => .scroll_left,
            'l' => .scroll_right,
            'J', ' ' => .next_page,
            'K', 'b' => .previous_page,
            'G' => .last_page,
            '+' => .zoom_in,
            '-' => .zoom_out,
            '=' => .fit_width,
            'g' => {
                self.pending_g = true;
                return null;
            },
            else => null,
        };
    }
};

const testing = @import("std").testing;

test "single keys" {
    var parser: Parser = .{};
    try testing.expectEqual(Command.scroll_down, parser.feed('j'));
    try testing.expectEqual(Command.next_page, parser.feed(' '));
    try testing.expectEqual(Command.quit, parser.feed(ctrl_c));
    try testing.expectEqual(null, parser.feed('x'));
}

test "gg goes to the first page" {
    var parser: Parser = .{};
    try testing.expectEqual(null, parser.feed('g'));
    try testing.expectEqual(Command.first_page, parser.feed('g'));
    try testing.expectEqual(null, parser.feed('g'));
}

test "another key after g cancels gg and still runs" {
    var parser: Parser = .{};
    try testing.expectEqual(null, parser.feed('g'));
    try testing.expectEqual(Command.scroll_down, parser.feed('j'));
    try testing.expectEqual(null, parser.feed('g'));
    try testing.expectEqual(null, parser.feed('x'));
    try testing.expectEqual(Command.scroll_up, parser.feed('k'));
}
