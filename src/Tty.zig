//! The controlling terminal: raw mode, the alternate screen, pane size, and
//! waiting for keys or signals.
//!
//! One kqueue watches the terminal and the signals, so nothing runs in a
//! signal handler. kqueue(2) records a signal even when its disposition is
//! SIG_IGN. macOS rejects kqueue reads on /dev/tty, so the terminal is opened
//! by its device name instead.
const Tty = @This();

const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;

/// Signals that end the program. Their default action would kill rdr
/// without restoring the terminal, so they are ignored and read from `kq`.
const quit_signals = [_]posix.SIG{ .INT, .TERM, .HUP };

/// How long a read waits for its first byte, in tenths of a second (VTIME).
/// Only the startup probe ever waits: other reads follow a kqueue event.
const read_timeout_ds = 10;

file: std.Io.File,
io: std.Io,
kq: posix.fd_t,
/// Dispositions of `quit_signals` before `open`, restored by `close`.
saved_actions: [quit_signals.len]posix.Sigaction,
/// Terminal attributes before `enter`, restored by `restore`.
saved_termios: ?posix.termios = null,

pub const Error = error{
    TtyUnavailable,
    TerminalTooSmall,
    NoPixelSize,
    SignalSetupFailed,
};

/// Pane size in cells, and the size of one cell in pixels.
pub const Size = struct {
    rows: u16,
    cols: u16,
    cell_width: u16,
    cell_height: u16,
};

pub const Event = enum { input, resize, quit };

pub fn open(io: std.Io) Error!Tty {
    const name = for ([_]posix.fd_t{ 0, 1, 2 }) |fd| {
        if (ttyname(fd)) |name| break name;
    } else return error.TtyUnavailable;
    const fd = c.open(name, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
    if (fd < 0) return error.TtyUnavailable;
    errdefer _ = c.close(fd);

    const kq = c.kqueue();
    if (kq < 0) return error.SignalSetupFailed;
    errdefer _ = c.close(kq);

    const signals = quit_signals ++ [_]posix.SIG{.WINCH};
    var changes: [signals.len + 1]c.Kevent = undefined;
    for (changes[0..signals.len], signals) |*change, sig| change.* = kevent(@backingInt(sig), c.EVFILT.SIGNAL);
    changes[signals.len] = kevent(@intCast(fd), c.EVFILT.READ);
    if (c.kevent(kq, &changes, changes.len, &changes, 0, null) < 0) return error.SignalSetupFailed;

    var tty: Tty = .{ .file = .{ .handle = fd, .flags = .{ .nonblocking = false } }, .io = io, .kq = kq, .saved_actions = undefined };
    const ignore: posix.Sigaction = .{ .handler = .{ .handler = c.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
    for (quit_signals, &tty.saved_actions) |sig, *saved| posix.sigaction(sig, &ignore, saved);
    return tty;
}

pub fn close(self: *Tty) void {
    assert(self.saved_termios == null);
    for (quit_signals, &self.saved_actions) |sig, *saved| posix.sigaction(sig, saved, null);
    _ = c.close(self.kq);
    _ = c.close(self.file.handle);
}

/// Switches to raw mode and the alternate screen and hides the cursor.
/// `restore` undoes all three.
pub fn enter(self: *Tty) Error!void {
    assert(self.saved_termios == null);
    const saved = posix.tcgetattr(self.file.handle) catch return error.TtyUnavailable;
    var raw = saved;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false; // Ctrl-C arrives as a key.
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.cc[@backingInt(c.V.MIN)] = 0;
    raw.cc[@backingInt(c.V.TIME)] = read_timeout_ds;
    posix.tcsetattr(self.file.handle, .FLUSH, raw) catch return error.TtyUnavailable;
    self.saved_termios = saved;
    assert(entered == null);
    entered = self;

    self.file.writeStreamingAll(self.io, "\x1b[?1049h\x1b[?25l") catch {
        self.restore();
        return error.TtyUnavailable;
    };
}

/// The terminal between `enter` and `restore`, for `restoreAfterPanic`. The
/// `Tty` must not move in between.
var entered: ?*Tty = null;

/// Called by the panic handler, so the panic message lands on the primary
/// screen and the shell gets its terminal back.
pub fn restoreAfterPanic() void {
    if (entered) |tty| tty.restore();
}

pub fn restore(self: *Tty) void {
    const saved = self.saved_termios orelse return;
    // Cleared first: a panic inside this function must not restore again.
    entered = null;
    // Best effort: if the terminal is gone there is nothing to restore.
    self.file.writeStreamingAll(self.io, "\x1b[?25h\x1b[?1049l") catch {};
    posix.tcsetattr(self.file.handle, .FLUSH, saved) catch {};
    self.saved_termios = null;
}

pub fn size(self: Tty) Error!Size {
    var winsize: posix.winsize = undefined;
    if (c.ioctl(self.file.handle, c.T.IOCGWINSZ, &winsize) != 0) return error.TtyUnavailable;
    // One row for the page and one for the status line.
    if (winsize.row < 2 or winsize.col < 1) return error.TerminalTooSmall;
    const cell_width = winsize.xpixel / winsize.col;
    const cell_height = winsize.ypixel / winsize.row;
    if (cell_width == 0 or cell_height == 0) return error.NoPixelSize;
    return .{ .rows = winsize.row, .cols = winsize.col, .cell_width = cell_width, .cell_height = cell_height };
}

/// Blocks until a key arrives or a watched signal is delivered. Quit beats
/// resize, and both beat pending input.
pub fn wait(self: Tty) Error!Event {
    while (true) {
        var events: [8]c.Kevent = undefined;
        const count = c.kevent(self.kq, &events, 0, &events, events.len, null);
        if (count < 0) {
            if (posix.errno(count) == .INTR) continue;
            return error.SignalSetupFailed;
        }
        var result: Event = .input;
        for (events[0..@intCast(count)]) |event| {
            if (event.filter != c.EVFILT.SIGNAL) continue;
            if (event.ident != @backingInt(posix.SIG.WINCH)) return .quit;
            result = .resize;
        }
        return result;
    }
}

/// Reads available input, waiting up to `read_timeout_ds` for the first
/// byte. An empty result after `wait` returned `.input` means the terminal
/// hung up.
pub fn read(self: Tty, buffer: []u8) Error![]u8 {
    const len = posix.read(self.file.handle, buffer) catch return error.TtyUnavailable;
    return buffer[0..len];
}

/// Buffered writer to the terminal. Everything for one frame is printed into
/// the buffer and reaches the terminal with `flush`.
pub fn writer(self: Tty, buffer: []u8) std.Io.File.Writer {
    return self.file.writerStreaming(self.io, buffer);
}

fn kevent(ident: usize, filter: i16) c.Kevent {
    return .{ .ident = ident, .filter = filter, .flags = c.EV.ADD, .fflags = 0, .data = 0, .udata = 0 };
}

// std.c does not declare ttyname.
extern "c" fn ttyname(fd: c_int) ?[*:0]const u8;
