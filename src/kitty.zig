//! The subset of the kitty graphics protocol that rdr uses: transmit an RGB
//! image through shared memory or a temp file, show a crop of it, delete it.
//!
//! https://sw.kovidgoyal.net/kitty/graphics-protocol/
const std = @import("std");
const assert = std.debug.assert;
const c = std.c;
const posix = std.posix;
const Writer = std.Io.Writer;
const Tty = @import("Tty.zig");

/// Image ids are nonzero. `probe` is used once at startup; page images take
/// the ids after it.
pub const ImageId = enum(u32) {
    probe = 1,
    _,
};

/// Packed 8-bit RGB pixels.
pub const Image = struct {
    pixels: []const u8,
    width: u32,
    height: u32,
};

/// A rectangle of an image, in pixels.
pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const Error = error{ StoreFailed, NoReply, NoMedium } || Writer.Error || Tty.Error;

/// Where the pixels travel. The terminal reads the object and deletes it.
pub const Medium = enum {
    shm,
    file,

    /// Picks the first medium the terminal accepts by sending a 1x1 image
    /// and reading the reply. Must run after `Tty.enter`, because switching
    /// to the alternate screen clears images.
    pub fn probe(tty: Tty, out: *Writer) Error!Medium {
        const black: Image = .{ .pixels = &.{ 0, 0, 0 }, .width = 1, .height = 1 };
        for ([_]Medium{ .shm, .file }) |medium| {
            defer medium.remove(.probe);
            transmit(out, medium, .probe, black, .reply) catch |err| switch (err) {
                error.StoreFailed => continue,
                else => |e| return e,
            };
            if (try readReply(tty)) {
                try delete(out, .probe);
                try out.flush();
                return medium;
            }
        }
        return error.NoMedium;
    }

    /// Removes the object for image `id` if the terminal has not consumed
    /// it. The terminal normally has, so ENOENT is expected and ignored.
    pub fn remove(self: Medium, id: ImageId) void {
        var buffer: [64]u8 = undefined;
        const name = self.objectName(id, &buffer);
        _ = switch (self) {
            .shm => c.shm_unlink(name),
            .file => c.unlink(name),
        };
    }

    /// The name depends only on the pid and image id, so cleanup can
    /// recompute it. Shared memory names must start with "/" and fit in 31
    /// bytes on macOS. The terminal only accepts temp files whose name
    /// contains "tty-graphics-protocol".
    fn objectName(self: Medium, id: ImageId, buffer: *[64]u8) [:0]const u8 {
        const prefix = switch (self) {
            .shm => "/",
            .file => "/tmp/tty-graphics-protocol-",
        };
        const args = .{ prefix, c.getpid(), @backingInt(id) };
        return std.fmt.bufPrintSentinel(buffer, "{s}rdr-{d}-{d}", args, 0) catch
            unreachable; // The longest prefix plus two u32s fits in 64 bytes.
    }

    fn key(self: Medium) u8 {
        return switch (self) {
            .shm => 's',
            .file => 't',
        };
    }

    fn store(self: Medium, name: [:0]const u8, pixels: []const u8) error{StoreFailed}!void {
        const flags: c.O = .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .CLOEXEC = true };
        const mode: c_uint = 0o600;
        const fd = switch (self) {
            .shm => shm_open(name, @bitCast(flags), mode),
            .file => c.open(name, flags, mode),
        };
        if (fd < 0) return error.StoreFailed;
        defer _ = c.close(fd);

        if (c.ftruncate(fd, @intCast(pixels.len)) != 0) return error.StoreFailed;
        const protection: posix.PROT = .{ .READ = true, .WRITE = true };
        const map = posix.mmap(null, pixels.len, protection, .{ .TYPE = .SHARED }, fd, 0) catch
            return error.StoreFailed;
        defer posix.munmap(map);
        @memcpy(map, pixels);
    }
};

pub const Response = enum { quiet, reply };

/// Stores `image` in a `medium` object and tells the terminal to load it as
/// image `id`. Flushes `out`.
pub fn transmit(out: *Writer, medium: Medium, id: ImageId, image: Image, response: Response) (Writer.Error || error{StoreFailed})!void {
    assert(image.width > 0);
    assert(image.height > 0);
    assert(image.pixels.len == @as(usize, image.width) * image.height * 3);

    var name_buffer: [64]u8 = undefined;
    const name = medium.objectName(id, &name_buffer);
    medium.remove(id); // A crashed run with a recycled pid may have left one.
    errdefer medium.remove(id);
    try medium.store(name, image.pixels);

    var encoded: [std.base64.standard.Encoder.calcSize(name_buffer.len)]u8 = undefined;
    try out.print("\x1b_Ga=t,i={d},f=24,s={d},v={d},t={c}{s};{s}\x1b\\", .{
        @backingInt(id),
        image.width,
        image.height,
        medium.key(),
        if (response == .quiet) ",q=2" else "",
        std.base64.standard.Encoder.encode(&encoded, name),
    });
    try out.flush();
}

/// Shows `rect` of image `id` at the cursor, at native pixel size, without
/// moving the cursor. Placement id 1 is reused, so the terminal replaces the
/// image's previous placement without flicker.
pub fn place(out: *Writer, id: ImageId, rect: Rect) Writer.Error!void {
    try out.print("\x1b_Ga=p,i={d},p=1,x={d},y={d},w={d},h={d},C=1,q=2\x1b\\", .{
        @backingInt(id), rect.x, rect.y, rect.width, rect.height,
    });
}

/// Removes the placement of image `id` but keeps the image for later use.
pub fn unplace(out: *Writer, id: ImageId) Writer.Error!void {
    try out.print("\x1b_Ga=d,d=i,i={d},p=1,q=2\x1b\\", .{@backingInt(id)});
}

/// Deletes image `id` and its placements, freeing the terminal's copy.
pub fn delete(out: *Writer, id: ImageId) Writer.Error!void {
    try out.print("\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{@backingInt(id)});
}

/// Reads one reply, "ESC _G i=<id>;OK ESC \" on success. Each read times out
/// on its own (see `Tty.read`).
fn readReply(tty: Tty) Error!bool {
    var buffer: [256]u8 = undefined;
    var len: usize = 0;
    while (len < buffer.len) {
        const bytes = try tty.read(buffer[len..]);
        if (bytes.len == 0) return error.NoReply;
        len += bytes.len;
        const reply = buffer[0..len];
        if (std.mem.indexOf(u8, reply, "\x1b\\") != null) {
            return std.mem.indexOf(u8, reply, ";OK") != null;
        }
    }
    return false;
}

// shm_open is variadic in Darwin's libc, and std.c declares it with a fixed
// arity. On arm64, variadic arguments go on the stack, so the fixed-arity
// prototype would pass a garbage mode.
extern "c" fn shm_open(name: [*:0]const u8, flags: c_int, ...) c_int;
