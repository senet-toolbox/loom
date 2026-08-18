const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const KQueue = @import("KQueue.zig");
const Loom = @import("Loom.zig");
const Websocket = @import("Websocket.zig");

const State = enum {
    Open,
    Closed,
    Error,
    Timeout,
    Handshake,
    Connected,
    Ready,
    Idle,
    Busy,
    Paused,
    Suspended,
    Resumed,
    Shutdown,
    Terminated,
};

const ConnectionType = enum {
    HTTP,
    WebSocket,
};

/// Deadline-ordered list of connections, maintained by the server.
pub const ClientList = std.DoublyLinkedList;

pub const Client = @This();
kqueue: *KQueue,

socket: posix.socket_t,
address: std.Io.net.IpAddress,

/// Dense connection-slot index in `0..config.max`, handed out by the
/// server on accept and returned to the free list on close. Stable for
/// the lifetime of the connection, so downstream layers can use it to
/// key their own per-connection state.
///
/// Named for the fiber pool it used to index; kept for API
/// compatibility and due for a rename to `slot`.
fiber_index: usize = 0,

/// Set the moment the server decides this connection is done. The
/// client stays allocated until the end of the current event batch, so
/// any further events in that batch can be recognised as stale and
/// skipped instead of touching a freed client.
closing: bool = false,

// Used to read length-prefixed messages
msg: []const u8,

// Used to write messages
writer: Writer,
response: []const u8,

/// Absolute time, in milliseconds, past which this connection is dropped
/// if it has made no progress. Refreshed by the server on every read and
/// on every write that drains.
read_timeout: i64,

/// Intrusive link into the server's deadline-ordered timeout list.
///
/// Embedded rather than separately allocated: the node's lifetime is
/// exactly the client's, so a side allocation bought nothing but an
/// extra pool and one more thing to forget to free.
timeout_node: ClientList.Node = .{},

client_type: ConnectionType = .HTTP,
state: State = .Open,
ws: ?*Websocket = null,
io: std.Io = undefined,
// Overflow tail of an in-flight slice send. While non-null, the
// client is mid-async-send and refuses new writes.
pending: ?[]const u8 = null,
// In-flight file send. Owned by the client while non-null — closed
// on EOF, on error, or when the client disconnects. Drained by the
// pump after `pending` (so a `write(headers); sendFile(file)`
// sequence sends in the right order).
pending_file: ?std.Io.File = null,

pub fn init(arena: Allocator, io: std.Io, socket: posix.socket_t, address: std.Io.net.IpAddress, kqueue: *KQueue) !Client {
    // const reader = try Reader.init(arena, 4096);
    // errdefer reader.deinit(arena);

    const writer = try Writer.init(arena, 4096);
    errdefer writer.deinit(arena);

    // const write_buf = try arena.alloc(u8, 4096);
    // errdefer arena.free(write_buf);

    return .{
        .kqueue = kqueue,
        .socket = socket,
        .address = address,
        .msg = "",
        .writer = writer,
        .response = "",
        .read_timeout = 0, // let the server set this
        .io = io,
    };
}

pub fn deinit(_: *const Client, _: Allocator) void {
    // self.writer.deinit(arena);
}

fn findEndOfHeaders(buffer: []const u8) ?usize {
    // Need at least 4 bytes for \r\n\r\n
    if (buffer.len < 4) return null;

    // Use a sliding window of 4 bytes
    var i: usize = 0;
    while (i <= buffer.len - 4) : (i += 1) {
        // Check all 4 bytes at once
        if (buffer[i] == '\r' and
            buffer[i + 1] == '\n' and
            buffer[i + 2] == '\r' and
            buffer[i + 3] == '\n')
        {
            return i + 4; // Return position after the sequence
        }
    }
    return null;
}

pub fn findCRLFCRLF(payload: []const u8) ?usize {
    if (payload.len < 4) return null;

    if (payload.len >= 32) {
        const V = @Vector(32, u8);
        const cr_pattern: V = @splat('\r');
        var i: usize = 0;

        while (i + 32 <= payload.len) : (i += 32) {
            const chunk: V = payload[i..][0..32].*;
            const cr_matches = chunk == cr_pattern;
            const cr_mask: u32 = @bitCast(cr_matches);

            if (cr_mask != 0) {
                var mask = cr_mask;
                while (mask != 0) {
                    const pos = i + @ctz(mask);
                    if (pos + 3 < payload.len and
                        payload[pos + 1] == '\n' and
                        payload[pos + 2] == '\r' and
                        payload[pos + 3] == '\n')
                    {
                        return pos;
                    }
                    mask &= mask - 1;
                }
            }
        }

        // Check remaining bytes after last 32-byte chunk
        i -= 3; // Ensure we check overlapping with the last chunk's end
        while (i < payload.len - 3) : (i += 1) {
            if (payload[i] == '\r' and
                payload[i + 1] == '\n' and
                payload[i + 2] == '\r' and
                payload[i + 3] == '\n')
            {
                return i;
            }
        }
        return null;
    }

    // Non-SIMD path for small payloads
    var i: usize = 0;
    while (i <= payload.len - 4) : (i += 1) {
        if (payload[i] == '\r' and
            payload[i + 1] == '\n' and
            payload[i + 2] == '\r' and
            payload[i + 3] == '\n')
        {
            return i;
        }
    }
    return null;
}

/// Scratch buffer every client reads into, sized from
/// `Config.max_read_size` and owned by the server.
///
/// NOTE: process-global and therefore shared by every connection. The
/// slice handed to the handler stays valid only until the next read on
/// any client — see the lifetime note on `write`.
pub var reader_buf: []u8 = &.{};
pub fn readMessage(self: *Client) ![]const u8 {
    // return self.reader.readMessage(self.socket) catch |err| {
    //     // try Loom.logger.err("Read msg {any}", .{err}, @src());
    //     switch (err) {
    //         error.WouldBlock => return null,
    //         else => return err,
    //     }
    // };

    const rv = try posix.read(self.socket, reader_buf);
    if (rv == 0) {
        return error.Closed;
    }

    // var end = buf[0..rv].len;
    // std.debug.print("{s}\n", .{buf[0..rv]});
    // if (buf[end - 1] != 10) {
    //     // std.debug.print("H\n", .{});
    //     end = findCRLFCRLF(buf[0..rv]).?;
    //     // std.debug.print("{any}\n", .{end});
    // }

    return reader_buf[0..rv];
}

/// True while a previous send is still draining — either there's
/// overflow waiting in `pending`, or the writer buffer hasn't been
/// fully flushed yet. New writes are rejected in this state.
pub fn isWriting(self: *const Client) bool {
    return self.pending != null or self.pending_file != null or self.writer.offset < self.writer.pos;
}

/// Append `msg` to the writer buffer (overflow goes into `pending`)
/// then drive the write state machine forward as far as the kernel
/// will accept right now.
///
/// Returns synchronously in two cases:
///   - Everything sent in one go (fast path for small responses).
///   - Kernel returned EAGAIN; `EVFILT.WRITE` has been armed and the
///     event loop will resume the send via `continueWrite` when the
///     socket becomes writable.
///
/// Returns `error.WriteInProgress` if a previous async send is still
/// in flight — the caller must wait for it to drain before queuing
/// the next message.
///
/// Lifetime: the caller must ensure `msg` outlives the write. If
/// `msg` does not fit in the writer buffer, a slice into it is
/// stashed as `pending` until later draining. For dynamically
/// allocated payloads, hold the backing storage until the next
/// READ event arrives on this client (which guarantees the previous
/// response has been fully sent).
pub fn write(self: *Client, msg: []const u8) !void {
    if (self.pending != null or self.pending_file != null) return error.WriteInProgress;

    const room = self.writer.buf.len - self.writer.pos;
    const take = @min(msg.len, room);
    try self.writer.fillWriteBuffer(msg[0..take]);
    if (take < msg.len) {
        self.pending = msg[take..];
    }

    try self.pumpWrite();
}

/// Alias for `write`. Both functions transparently chunk arbitrarily
/// large payloads through the fixed-size writer buffer; the name is
/// kept for callers that want to make streaming intent explicit.
pub fn chunked(self: *Client, payload: []const u8) !void {
    return self.write(payload);
}

/// Append `msg` to the writer buffer without triggering a send.
/// Useful when coalescing multiple small writes (e.g. a websocket
/// frame header followed by its payload) into a single syscall —
/// pair with a subsequent `write(...)` call to flush.
pub fn fillWriteBuffer(self: *Client, msg: []const u8) !void {
    if (self.pending != null or self.pending_file != null) return error.WriteInProgress;
    return self.writer.fillWriteBuffer(msg);
}

/// Begin asynchronously streaming a file through the write pump.
/// Ownership transfers to the client on success and the file is
/// closed on EOF, on send error, or when the client disconnects.
pub fn sendFile(self: *Client, file: std.Io.File) !void {
    if (self.pending_file != null) return error.WriteInProgress;

    self.pending_file = file;
    errdefer {
        if (self.pending_file) |f| {
            f.close(self.io);
            self.pending_file = null;
        }
    }

    try self.pumpWrite();
}

/// Drive the writer state machine forward. On EAGAIN (or partial
/// write), arms `EVFILT.WRITE` so the event loop will resume the
/// send when the socket is writable. Used internally by `write`
/// and `continueWrite`.
fn pumpWrite(self: *Client) !void {
    while (true) {
        // Drain whatever is currently in the writer buffer.
        self.writer.writeMessage(self.socket) catch |err| switch (err) {
            error.WouldBlock => {
                // Either kernel EAGAIN or a partial write. Park the
                // rest until the socket is writable. EVFILT.WRITE is
                // level-triggered for this client so a single arm is
                // enough — kqueue will keep firing as long as there's
                // send-buffer space.
                try self.kqueue.writeMode(self);
                return;
            },
            else => return err,
        };
        // Writer fully drained. If there's overflow in `pending`,
        // refill the writer buffer and try to drain again.
        if (self.pending) |p| {
            const take = @min(p.len, self.writer.buf.len);
            try self.writer.fillWriteBuffer(p[0..take]);
            self.pending = if (take < p.len) p[take..] else null;
            continue;
        }
        // If there's no slice overflow left, pull the next chunk
        // directly from an in-flight file transfer.
        if (self.pending_file) |*file| {
            const chunk_len = file.readStreaming(self.io, &.{self.writer.buf[0..]}) catch |err| switch (err) {
                error.EndOfStream => {
                    file.close(self.io);
                    self.pending_file = null;
                    return;
                },
                else => {
                    file.close(self.io);
                    self.pending_file = null;
                    return err;
                },
            };
            if (chunk_len == 0) {
                file.close(self.io);
                self.pending_file = null;
                return;
            }
            self.writer.pos = chunk_len;
            self.writer.offset = 0;
            continue;
        }
        return; // nothing more to send
    }
}

/// Called by the event loop when `EVFILT.WRITE` fires for this
/// client. Drives the write state machine and, on completion, flips
/// the client back to read mode for the next request (HTTP/1.1
/// keep-alive).
pub fn continueWrite(self: *Client) !void {
    try self.pumpWrite();
    if (!self.isWriting()) {
        try self.kqueue.readMode(self);
    }
}

const Reader = struct {
    buf: [4096]u8 = [_]u8{0} ** 4096,
    pos: usize = 0,
    start: usize = 0,

    pub fn init(_: Allocator, _: usize) !Reader {
        // const buf = try arena.alloc(u8, size);
        return .{
            .pos = 0,
            .start = 0,
            // .buf = buf,
        };
    }

    pub fn deinit(_: *const Reader, _: Allocator) void {
        // arena.free(self.buf);
    }

    // !!!!!!!!!!!!!!!This process of adding is extremely heavy
    // self.pos += rv;
    pub fn readMessage(self: *Reader, socket: posix.socket_t) ![]u8 {
        var buf = self.buf;
        const start = self.start;

        const rv = try posix.read(socket, buf[start..]);
        if (rv == 0) {
            return error.Closed;
        }

        self.pos = rv;
        std.debug.assert(self.pos >= start);
        const msg = buf[start..self.pos];
        self.start += msg.len;
        return msg;
    }
};

fn posixWrite(fd: i32, buf: []const u8) !usize {
    const rc = posix.system.write(fd, buf.ptr, buf.len);
    const e = posix.system.errno(rc);
    if (e != .SUCCESS) return switch (e) {
        .AGAIN => error.WouldBlock,
        .PIPE => error.BrokenPipe,
        .CONNRESET => error.ConnectionReset,
        .INTR => error.Interrupted,
        else => error.Unexpected,
    };
    if (rc == 0) return error.Closed;
    return @intCast(rc);
}

fn posixRead(fd: i32, buf: []u8) !usize {
    const rc = posix.system.read(fd, buf.ptr, buf.len);
    const e = posix.system.errno(rc);
    if (e != .SUCCESS) return switch (e) {
        .AGAIN => error.WouldBlock,
        .CONNRESET => error.ConnectionReset,
        .INTR => error.Interrupted,
        else => error.Unexpected,
    };
    if (rc == 0) return error.Closed;
    return @intCast(rc);
}

const Writer = struct {
    buf: [65536]u8 = undefined,
    pos: usize = 0, // Current write position in buffer
    offset: usize = 0, // How much we've sent from the buffer

    pub fn init(_: Allocator, _: usize) !Writer {
        return .{
            .pos = 0,
            .offset = 0,
        };
    }

    pub fn deinit(_: *const Writer, _: Allocator) void {}

    pub fn fillWriteBuffer(self: *Writer, msg: []const u8) !void {
        // Check if we have space (optional safety check)
        if (self.pos + msg.len > self.buf.len) {
            return error.BufferFull;
        }

        // Copy data into buffer at current position
        @memcpy(self.buf[self.pos..][0..msg.len], msg);
        self.pos += msg.len;
    }

    pub fn writeMessage(self: *Writer, socket: posix.socket_t) !void {
        // Nothing to write
        if (self.offset >= self.pos) {
            return;
        }

        // Try to write remaining data
        const wv = posixWrite(socket, self.buf[self.offset..self.pos]) catch |err| {
            switch (err) {
                error.WouldBlock => return error.WouldBlock,
                else => return err,
            }
        };
        if (wv == 0) {
            return error.Closed;
        }

        // Update how much we've sent
        self.offset += wv;

        // Check if we've sent everything
        if (self.offset < self.pos) {
            // Still have data to send
            return error.WouldBlock;
        } else {
            // All data sent, reset for next message
            self.pos = 0;
            self.offset = 0;
        }
    }

    // Helper to check if write is complete
    pub fn isComplete(self: *const Writer) bool {
        return self.offset >= self.pos;
    }

    // Helper to reset without completing a write
    pub fn reset(self: *Writer) void {
        self.pos = 0;
        self.offset = 0;
    }
};
