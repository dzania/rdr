//! Turns key bytes into commands. Bindings follow zathura and vim.

const std = @import("std");

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
    open_index,
};

/// Commands while the table of contents is shown, as in zathura's index mode.
pub const IndexCommand = enum {
    quit,
    close,
    /// Jumps to the selected entry and closes the index.
    select,
    down,
    up,
    /// Collapses the selected entry, or selects its parent.
    collapse,
    expand,
    collapse_all,
    expand_all,
    first,
    last,
};

const ctrl_c = 0x03;
const tab = 0x09;
const enter = 0x0d; // Raw mode leaves ICRNL off, so Enter sends CR.
const bel = 0x07;
const esc = 0x1b;

/// What one input byte yields: an Escape key press, then a key byte, each
/// possibly absent. Escape comes first when both are set. A mouse event
/// ends a sequence, so it never comes with either.
pub const Keys = struct {
    escape: bool = false,
    byte: ?u8 = null,
    mouse: ?Mouse = null,
};

/// A mouse report in SGR form (mode 1006), for the left button and the
/// wheel. Other buttons are dropped. `x` and `y` are as the terminal sent
/// them: 1-based cells, or pixels in SGR-pixel mode (1016).
pub const Mouse = struct {
    action: Action,
    x: u32,
    y: u32,

    pub const Action = enum { press, drag, release, wheel_up, wheel_down };
};

/// Splits terminal input into key bytes and Escape presses, and drops
/// escape sequences (arrow keys, terminal replies) so their bytes are not
/// taken for commands. Keeps its state between reads, so a sequence split
/// across two reads is still dropped whole.
///
/// ESC starts a sequence when the next byte is `[` (CSI), `O` (SS3), or
/// one of `P ] X ^ _` (strings such as kitty's graphics replies). Before
/// any other byte it is the Escape key, and that byte is a key of its own.
/// An ESC that ends a read is the Escape key too: terminals write a whole
/// sequence at once, so its next byte would already be there.
///
/// A CSI starting with `<` is an SGR mouse report, `ESC [ < b ; x ; y M`
/// for a press or motion and `... m` for a release, and becomes a `Mouse`.
pub const Decoder = struct {
    state: State = .ground,
    /// Bytes read so far in the current string sequence.
    string_len: usize = 0,
    /// The mouse report being read.
    report: Report = .{},

    /// A string sequence longer than this is given up on, and the bytes
    /// after it are keys again. kitty's replies are well under 100 bytes;
    /// the cap keeps an unterminated string from swallowing every key.
    pub const string_len_max = 4096;

    const State = enum { ground, escape, csi_start, csi, mouse, ss3, string, string_escape };

    /// The parameters of a mouse report: button, x, and y.
    const Report = struct {
        params: [3]u32 = @splat(0),
        /// The parameter being read.
        index: usize = 0,
        /// Cleared by anything a well-formed report cannot contain, such as
        /// a fourth parameter or a number that overflows.
        valid: bool = true,
    };

    pub fn feed(self: *Decoder, byte: u8) Keys {
        switch (self.state) {
            .ground => {
                if (byte == esc) {
                    self.state = .escape;
                    return .{};
                }
                return .{ .byte = byte };
            },
            .escape => switch (byte) {
                '[' => self.state = .csi_start,
                'O' => self.state = .ss3,
                'P', ']', 'X', '^', '_' => {
                    self.state = .string;
                    self.string_len = 0;
                },
                // Escape, and this ESC may start a sequence.
                esc => return .{ .escape = true },
                else => {
                    self.state = .ground;
                    return .{ .escape = true, .byte = byte };
                },
            },
            .csi_start => {
                if (byte == '<') {
                    self.state = .mouse;
                    self.report = .{};
                    return .{};
                }
                self.state = .csi;
                return self.feed(byte);
            },
            .csi => switch (byte) {
                // Parameter and intermediate bytes.
                0x20...0x3f => {},
                // The final byte.
                0x40...0x7e => self.state = .ground,
                // Not part of a CSI: the sequence was cut short, and this
                // byte is a key or the start of the next sequence.
                else => {
                    self.state = .ground;
                    return self.feed(byte);
                },
            },
            .mouse => return self.feedMouse(byte),
            .ss3 => self.state = .ground,
            .string, .string_escape => return self.feedString(byte),
        }
        return .{};
    }

    fn feedMouse(self: *Decoder, byte: u8) Keys {
        const report = &self.report;
        switch (byte) {
            '0'...'9' => {
                const param = &report.params[report.index];
                const scaled = std.math.mul(u32, param.*, 10) catch return self.invalidMouse();
                param.* = std.math.add(u32, scaled, byte - '0') catch return self.invalidMouse();
            },
            ';' => {
                if (report.index + 1 < report.params.len) {
                    report.index += 1;
                } else {
                    report.valid = false;
                }
            },
            'M', 'm' => {
                self.state = .ground;
                if (!report.valid or report.index + 1 != report.params.len) return .{};
                const action = mouseAction(report.params[0], byte == 'm') orelse return .{};
                return .{ .mouse = .{ .action = action, .x = report.params[1], .y = report.params[2] } };
            },
            // Other parameter, intermediate, and final bytes: not a report
            // rdr understands, but the sequence still runs to its end.
            0x20...0x2f, 0x3a, 0x3c...0x3f => report.valid = false,
            0x40...0x4c, 0x4e...0x6c, 0x6e...0x7e => self.state = .ground,
            // Cut short, as in `.csi`.
            else => {
                self.state = .ground;
                return self.feed(byte);
            },
        }
        return .{};
    }

    fn invalidMouse(self: *Decoder) Keys {
        self.report.valid = false;
        return .{};
    }

    /// Ends a read. True if it ended with a lone ESC, the Escape key.
    pub fn flush(self: *Decoder) bool {
        if (self.state != .escape) return false;
        self.state = .ground;
        return true;
    }

    fn feedString(self: *Decoder, byte: u8) Keys {
        // BEL or ESC \ ends the string.
        if (byte == bel or (self.state == .string_escape and byte == '\\')) {
            self.state = .ground;
            return .{};
        }
        self.state = if (byte == esc) .string_escape else .string;
        self.string_len += 1;
        if (self.string_len >= string_len_max) self.state = .ground;
        return .{};
    }
};

/// The action an SGR button parameter stands for, or null for buttons rdr
/// ignores. The low two bits name the button (0 is left), 32 marks motion,
/// 64 the wheel, and 4, 8, and 16 are Shift, Meta, and Control.
fn mouseAction(button: u32, release: bool) ?Mouse.Action {
    const button_mask = 0b11;
    const motion = 32;
    const wheel = 64;
    // Buttons 8 to 11 set 128 and are not used.
    if (button >= 128) return null;
    const low = button & button_mask;
    if (button & wheel != 0) {
        if (release) return null;
        return switch (low) {
            0 => .wheel_up,
            1 => .wheel_down,
            else => null, // Horizontal wheel.
        };
    }
    if (low != 0) return null;
    if (release) return .release;
    return if (button & motion != 0) .drag else .press;
}

pub const Parser = struct {
    /// A `g` was typed and a second one would complete `gg`.
    pending_g: bool = false,

    pub fn feed(self: *Parser, byte: u8) ?Command {
        if (self.completesGg(byte)) return .first_page;
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
            tab => .open_index,
            'g' => {
                self.pending_g = true;
                return null;
            },
            else => null,
        };
    }

    pub fn feedIndex(self: *Parser, byte: u8) ?IndexCommand {
        if (self.completesGg(byte)) return .first;
        return switch (byte) {
            'q', ctrl_c => .quit,
            tab => .close,
            ' ', enter => .select,
            'j' => .down,
            'k' => .up,
            'h' => .collapse,
            'l' => .expand,
            'H' => .collapse_all,
            'L' => .expand_all,
            'G' => .last,
            'g' => {
                self.pending_g = true;
                return null;
            },
            else => null,
        };
    }

    /// Forgets a pending `g`, so a key typed in one mode cannot complete a
    /// command in another.
    pub fn reset(self: *Parser) void {
        self.pending_g = false;
    }

    /// Consumes a pending `g`. True if `byte` completes `gg`.
    fn completesGg(self: *Parser, byte: u8) bool {
        if (!self.pending_g) return false;
        self.pending_g = false;
        return byte == 'g';
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

test "index keys" {
    var parser: Parser = .{};
    try testing.expectEqual(Command.open_index, parser.feed(tab));
    try testing.expectEqual(IndexCommand.close, parser.feedIndex(tab));
    try testing.expectEqual(IndexCommand.select, parser.feedIndex(enter));
    try testing.expectEqual(IndexCommand.select, parser.feedIndex(' '));
    try testing.expectEqual(IndexCommand.down, parser.feedIndex('j'));
    try testing.expectEqual(IndexCommand.quit, parser.feedIndex('q'));
    try testing.expectEqual(null, parser.feedIndex('J'));
    try testing.expectEqual(null, parser.feedIndex('g'));
    try testing.expectEqual(IndexCommand.first, parser.feedIndex('g'));
    try testing.expectEqual(null, parser.feedIndex('g'));
    try testing.expectEqual(IndexCommand.collapse, parser.feedIndex('h'));
}

test "reset drops a pending g" {
    var parser: Parser = .{};
    try testing.expectEqual(null, parser.feedIndex('g'));
    parser.reset();
    try testing.expectEqual(null, parser.feed('g'));
    try testing.expectEqual(Command.first_page, parser.feed('g'));
}

/// Feeds `reads` one read at a time and writes what comes out: key bytes
/// as they are, and Escape as `E`.
fn testDecode(reads: []const []const u8) ![]const u8 {
    const state = struct {
        var buffer: [64]u8 = undefined;
    };
    var out: @import("std").Io.Writer = .fixed(&state.buffer);
    var decoder: Decoder = .{};
    for (reads) |read| {
        for (read) |byte| {
            const keys = decoder.feed(byte);
            if (keys.escape) try out.writeByte('E');
            if (keys.byte) |key| try out.writeByte(key);
        }
        if (decoder.flush()) try out.writeByte('E');
    }
    return out.buffered();
}

test "decoder passes plain keys through" {
    try testing.expectEqualStrings("jk\tq", try testDecode(&.{"jk\tq"}));
    try testing.expectEqualStrings("", try testDecode(&.{""}));
}

test "decoder finds Escape wherever it is in a read" {
    try testing.expectEqualStrings("E", try testDecode(&.{"\x1b"}));
    try testing.expectEqualStrings("Ej", try testDecode(&.{"\x1bj"}));
    try testing.expectEqualStrings("jE", try testDecode(&.{"j\x1b"}));
    try testing.expectEqualStrings("EE", try testDecode(&.{"\x1b\x1b"}));
    try testing.expectEqualStrings("EEk", try testDecode(&.{ "\x1b", "\x1bk" }));
}

test "decoder drops escape sequences" {
    // Arrow keys, in CSI and SS3 form, and a CSI with parameters.
    try testing.expectEqualStrings("jk", try testDecode(&.{"j\x1b[A\x1bOBk"}));
    try testing.expectEqualStrings("q", try testDecode(&.{"\x1b[1;5Cq"}));
    // A kitty graphics reply, ended by ESC \, and an OSC ended by BEL.
    try testing.expectEqualStrings("jk", try testDecode(&.{"j\x1b_Gi=1;EINVAL\x1b\\k"}));
    try testing.expectEqualStrings("j", try testDecode(&.{"\x1b]11;rgb:0/0/0\x07j"}));
}

test "decoder drops a sequence split across reads" {
    try testing.expectEqualStrings("k", try testDecode(&.{ "\x1b[1;", "5Ck" }));
    try testing.expectEqualStrings("k", try testDecode(&.{ "\x1b_Gi=1;", "OK\x1b", "\\k" }));
}

test "decoder recovers from a cut-short CSI" {
    // A control byte cannot be inside a CSI, so it ends the sequence and
    // is read as a key.
    try testing.expectEqualStrings("\tj", try testDecode(&.{"\x1b[1\tj"}));
    try testing.expectEqualStrings("Ej", try testDecode(&.{"\x1b[1\x1bj"}));
}

test "decoder gives up on an unterminated string" {
    var decoder: Decoder = .{};
    try testing.expectEqual(Keys{}, decoder.feed(esc));
    try testing.expectEqual(Keys{}, decoder.feed('_'));
    for (0..Decoder.string_len_max) |_| try testing.expectEqual(Keys{}, decoder.feed('x'));
    try testing.expectEqual(Keys{ .byte = 'j' }, decoder.feed('j'));
    try testing.expect(!decoder.flush());
}

/// Feeds `bytes` and returns the mouse events, at most 8.
fn testMouse(bytes: []const u8) ![]const Mouse {
    const state = struct {
        var events: [8]Mouse = undefined;
    };
    var len: usize = 0;
    var decoder: Decoder = .{};
    for (bytes) |byte| {
        const keys = decoder.feed(byte);
        try testing.expect(!keys.escape);
        try testing.expectEqual(null, keys.byte);
        const mouse = keys.mouse orelse continue;
        try testing.expect(len < state.events.len);
        state.events[len] = mouse;
        len += 1;
    }
    try testing.expect(!decoder.flush());
    return state.events[0..len];
}

test "decoder reads a left-button drag" {
    const events = try testMouse("\x1b[<0;10;20M\x1b[<32;11;21M\x1b[<0;12;22m");
    try testing.expectEqualSlices(Mouse, &.{
        .{ .action = .press, .x = 10, .y = 20 },
        .{ .action = .drag, .x = 11, .y = 21 },
        .{ .action = .release, .x = 12, .y = 22 },
    }, events);
}

test "decoder reads the wheel and ignores modifiers" {
    const events = try testMouse("\x1b[<64;1;1M\x1b[<65;2;3M\x1b[<4;5;6M\x1b[<48;7;8M");
    try testing.expectEqualSlices(Mouse, &.{
        .{ .action = .wheel_up, .x = 1, .y = 1 },
        .{ .action = .wheel_down, .x = 2, .y = 3 },
        // Shift-press and Control-drag.
        .{ .action = .press, .x = 5, .y = 6 },
        .{ .action = .drag, .x = 7, .y = 8 },
    }, events);
}

test "decoder drops other buttons" {
    // Middle and right press and release, horizontal wheel, button 8, and
    // motion with no button held.
    const bytes = "\x1b[<1;1;1M\x1b[<2;1;1m\x1b[<66;1;1M\x1b[<128;1;1M\x1b[<35;1;1M";
    try testing.expectEqual(0, (try testMouse(bytes)).len);
}

test "decoder drops malformed mouse reports" {
    // Too few and too many parameters, an overflowing coordinate, a colon,
    // and an unexpected final byte.
    const bytes = "\x1b[<0;1M\x1b[<0;1;2;3M\x1b[<0;99999999999;1M\x1b[<0:1;1;1M\x1b[<0;1;1H";
    try testing.expectEqual(0, (try testMouse(bytes)).len);
    // The decoder is back in the ground state afterwards.
    const events = try testMouse("\x1b[<0;1;1M\x1b[<0;4294967295;1M");
    try testing.expectEqualSlices(Mouse, &.{
        .{ .action = .press, .x = 1, .y = 1 },
        .{ .action = .press, .x = 4294967295, .y = 1 },
    }, events);
}

test "decoder reads a mouse report split across reads" {
    var decoder: Decoder = .{};
    for ("\x1b[<0;3") |byte| try testing.expectEqual(Keys{}, decoder.feed(byte));
    try testing.expect(!decoder.flush());
    for (";4") |byte| try testing.expectEqual(Keys{}, decoder.feed(byte));
    const keys = decoder.feed('M');
    try testing.expectEqual(Mouse{ .action = .press, .x = 3, .y = 4 }, keys.mouse.?);
}

test "decoder keeps keys around mouse reports" {
    try testing.expectEqualStrings("jk", try testDecode(&.{"j\x1b[<0;1;1Mk"}));
}
