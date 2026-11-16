//! rdr: a minimal terminal PDF viewer.
//!
//! MuPDF renders each page once and the image goes to the terminal through
//! the kitty graphics protocol. Scrolling only re-places a different crop of
//! that image, so it sends no pixels.
const std = @import("std");
const App = @import("App.zig");
const Document = @import("Document.zig");
const Tty = @import("Tty.zig");

const log = std.log;

const usage = "usage: rdr <file> [page]";

/// A panic skips every defer, so the terminal is restored here before the
/// default handler prints the message and aborts.
pub const panic = std.debug.FullPanic(struct {
    fn call(message: []const u8, first_trace_address: ?usize) noreturn {
        Tty.restoreAfterPanic();
        std.debug.defaultPanic(message, first_trace_address);
    }
}.call);

// Errors return from `main` instead of calling `std.process.fatal`, because
// `exit` skips defers and a skipped `tty.restore` leaves the shell in raw mode.
pub fn main(init: std.process.Init.Minimal) u8 {
    var args = init.args.iterate();
    _ = args.skip();
    const path = args.next() orelse {
        log.err(usage, .{});
        return 1;
    };
    const page_arg = args.next();
    if (args.next() != null) {
        log.err(usage, .{});
        return 1;
    }

    var message: [256]u8 = undefined;
    const doc = Document.open(path, &message) catch {
        log.err("{s}: {s}", .{ path, std.mem.sliceTo(&message, 0) });
        return 1;
    };
    defer doc.close();

    const first_page = if (page_arg) |text| parsePage(text, doc.page_count) orelse {
        log.err("page must be between 1 and {d}, got \"{s}\"", .{ doc.page_count, text });
        return 1;
    } else 0;

    view(doc, std.fs.path.basename(path), first_page) catch |err| {
        log.err("{s}", .{describe(err)});
        return 1;
    };
    return 0;
}

fn view(doc: Document, title: []const u8, first_page: u32) App.Error!void {
    // Single-threaded and without an allocator: rdr needs no heap of its own.
    var threaded: std.Io.Threaded = .init_single_threaded;
    var tty: Tty = try .open(threaded.io());
    defer tty.close();
    // Fail on a terminal without pixel sizes before touching the screen.
    _ = try tty.size();
    try tty.enter();
    defer tty.restore();

    var buffer: [4096]u8 = undefined;
    var writer = tty.writer(&buffer);
    var app: App = try .init(tty, &writer.interface, doc, title, first_page);
    defer app.deinit();
    try app.run();
}

/// Turns a 1-based page argument into a page index.
fn parsePage(text: []const u8, page_count: u32) ?u32 {
    const page = std.fmt.parseInt(u32, text, 10) catch return null;
    if (page < 1 or page > page_count) return null;
    return page - 1;
}

fn describe(err: App.Error) []const u8 {
    return switch (err) {
        error.TtyUnavailable => "cannot use the terminal (/dev/tty)",
        error.TerminalTooSmall => "the terminal needs at least two rows",
        error.NoPixelSize => "the terminal reports no pixel size (TIOCGWINSZ pixel fields are 0)",
        error.SignalSetupFailed => "cannot watch for signals",
        error.WriteFailed => "cannot write to the terminal",
        error.NoReply => "the terminal did not answer the kitty graphics query",
        error.NoMedium => "the terminal accepts neither shared memory nor temp file images",
        error.StoreFailed => "cannot create the shared memory object or temp file for a page",
        error.OutOfMemory => "out of memory",
        error.PageFailed => "MuPDF cannot load the page",
        error.RenderFailed => "MuPDF cannot render the page",
    };
}

test parsePage {
    try std.testing.expectEqual(0, parsePage("1", 5));
    try std.testing.expectEqual(4, parsePage("5", 5));
    try std.testing.expectEqual(null, parsePage("0", 5));
    try std.testing.expectEqual(null, parsePage("6", 5));
    try std.testing.expectEqual(null, parsePage("-1", 5));
    try std.testing.expectEqual(null, parsePage("x", 5));
    try std.testing.expectEqual(null, parsePage("", 5));
}

test {
    _ = @import("App.zig");
    _ = @import("PageCache.zig");
    _ = @import("Tty.zig");
    _ = @import("Viewport.zig");
    _ = @import("input.zig");
}
