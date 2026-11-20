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
/// possibly absent. Escape comes first when both are set.
pub const Keys = struct {
    escape: bool = false,
    byte: ?u8 = null,
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
pub const Decoder = struct {
    state: State = .ground,
    /// Bytes read so far in the current string sequence.
    string_len: usize = 0,

    /// A string sequence longer than this is given up on, and the bytes
    /// after it are keys again. kitty's replies are well under 100 bytes;
    /// the cap keeps an unterminated string from swallowing every key.
    pub const string_len_max = 4096;

    const State = enum { ground, escape, csi, ss3, string, string_escape };

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
                '[' => self.state = .csi,
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
            .ss3 => self.state = .ground,
            .string, .string_escape => return self.feedString(byte),
        }
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
