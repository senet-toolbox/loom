const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Poller = @import("Poller.zig").Backend;
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
poller: *Poller,

socket: posix.socket_t,
address: std.Io.net.IpAddress,

/// Dense connection index in `0..config.max`, handed out by the server on
/// accept and returned to the free list on close.
///
/// Stable for the lifetime of the connection and never shared with
/// another live connection, so downstream layers can use it to key their
/// own per-connection state without any bookkeeping of their own.
slot: usize = 0,

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

/// This connection's own read buffer.
///
/// Starts at `Config.initial_read_size` and doubles, up to
/// `Config.max_read_size`, whenever a read comes back completely full —
/// which is the signal that the peer had more queued than would fit.
/// Growing is deferred to the start of the next read so that the slice
/// handed to the handler is never reallocated out from under it.
read_buf: []u8 = &.{},
max_read_size: usize = 0,
grow_read_buf: bool = false,

/// Allocator that owns `read_buf`. Held so the buffer can grow without
/// the read path having to reach back into the server.
arena: Allocator = undefined,
/// Largest payload `write` will accept. 0 means unlimited.
max_body_size: usize = 0,

/// Overflow tail of an in-flight send. While non-null, the client is
/// mid-async-send and refuses new writes.
///
/// Points into `pending_buf` for `write`, and into caller memory for
/// `writeBorrowed`.
pending: ?[]const u8 = null,

/// Client-owned storage for the part of a `write` payload that did not
/// fit in the writer buffer.
///
/// The whole point of copying: a parked send outlives the call that
/// started it, so anything still referenced when the handler returns has
/// to belong to the client. Grown to fit and reused across requests,
/// since only one send is ever in flight per connection.
pending_buf: []u8 = &.{},
// In-flight file send. Owned by the client while non-null — closed
// on EOF, on error, or when the client disconnects. Drained by the
// pump after `pending` (so a `write(headers); sendFile(file)`
// sequence sends in the right order).
pending_file: ?std.Io.File = null,

pub fn init(
    arena: Allocator,
    io: std.Io,
    socket: posix.socket_t,
    address: std.Io.net.IpAddress,
    poller: *Poller,
    initial_read_size: usize,
    max_read_size: usize,
    max_body_size: usize,
) !Client {
    const writer = try Writer.init(arena, 4096);
    errdefer writer.deinit(arena);

    const read_buf = try arena.alloc(u8, initial_read_size);
    errdefer arena.free(read_buf);

    return .{
        .poller = poller,
        .socket = socket,
        .address = address,
        .msg = "",
        .writer = writer,
        .response = "",
        .read_timeout = 0, // let the server set this
        .io = io,
        .read_buf = read_buf,
        .max_read_size = max_read_size,
        .max_body_size = max_body_size,
        .arena = arena,
    };
}

pub fn deinit(self: *Client, arena: Allocator) void {
    if (self.read_buf.len != 0) {
        arena.free(self.read_buf);
        self.read_buf = &.{};
    }
    if (self.pending_buf.len != 0) {
        arena.free(self.pending_buf);
        self.pending_buf = &.{};
    }
    self.pending = null;
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

/// Read whatever has arrived, into this connection's own buffer.
///
/// The returned slice stays valid until the next read *on this
/// connection*. Nothing another connection does can disturb it.
pub fn readMessage(self: *Client) ![]const u8 {
    // Deferred from the previous read: growing here, before the read,
    // means the slice handed out last time was never invalidated.
    if (self.grow_read_buf) {
        self.grow_read_buf = false;
        self.growReadBuf();
    }

    const rv = try posix.read(self.socket, self.read_buf);
    if (rv == 0) {
        return error.Closed;
    }

    // A read that filled the buffer exactly almost always means the peer
    // had more waiting. Take the hint and read bigger next time.
    if (rv == self.read_buf.len and self.read_buf.len < self.max_read_size) {
        self.grow_read_buf = true;
    }

    return self.read_buf[0..rv];
}

/// Double the read buffer, capped at `max_read_size`.
///
/// Best-effort: if the allocation fails the connection keeps its current
/// buffer and simply reads in smaller pieces, which is slower but
/// correct. Failing to grow is not a reason to drop a live connection.
fn growReadBuf(self: *Client) void {
    const target = @min(self.read_buf.len *| 2, self.max_read_size);
    if (target <= self.read_buf.len) return;
    if (self.arena.realloc(self.read_buf, target)) |bigger| {
        self.read_buf = bigger;
    } else |_| {}
}

/// True while a previous send is still draining — either there's
/// overflow waiting in `pending`, or the writer buffer hasn't been
/// fully flushed yet. New writes are rejected in this state.
pub fn isWriting(self: *const Client) bool {
    return self.pending != null or self.pending_file != null or self.writer.offset < self.writer.pos;
}

/// Send `msg`, copying anything that does not fit in the writer buffer
/// so the caller keeps no obligations once this returns.
///
/// Returns synchronously in two cases:
///   - Everything went out in one go (the fast path for small
///     responses, which never allocates or copies beyond the writer
///     buffer).
///   - The kernel returned EAGAIN. The poller has been asked to report
///     writability and the event loop resumes the send later.
///
/// Returns `error.WriteInProgress` if a previous send is still draining,
/// and `error.ResponseTooLarge` if `msg` exceeds `Config.max_body_size`.
///
/// Lifetime: none. `msg` may be a stack buffer, arena memory reset
/// immediately afterwards, or anything else — the client owns a copy of
/// whatever is still outstanding. Use `writeBorrowed` to skip that copy
/// when the payload is genuinely stable.
pub fn write(self: *Client, msg: []const u8) !void {
    if (self.pending != null or self.pending_file != null) return error.WriteInProgress;
    if (self.max_body_size != 0 and msg.len > self.max_body_size) {
        return error.ResponseTooLarge;
    }

    const room = self.writer.buf.len - self.writer.pos;
    const take = @min(msg.len, room);
    try self.writer.fillWriteBuffer(msg[0..take]);

    if (take < msg.len) {
        // The tail outlives this call, so it has to be ours. Only one
        // send is in flight at a time, so the buffer is reused rather
        // than reallocated per response.
        const tail = msg[take..];
        if (self.pending_buf.len < tail.len) {
            self.pending_buf = try self.arena.realloc(self.pending_buf, tail.len);
        }
        @memcpy(self.pending_buf[0..tail.len], tail);
        self.pending = self.pending_buf[0..tail.len];
    }

    try self.pumpWrite();
}

/// Send `msg` without copying it.
///
/// The caller guarantees `msg` stays valid and unchanged until the send
/// completes — which may be several event-loop iterations after this
/// returns, once the payload is larger than the writer buffer. Getting
/// that wrong corrupts responses intermittently under load, and only
/// under load, so this is strictly for memory that genuinely outlives
/// the request: string literals, `comptime` data, or a buffer the caller
/// owns for the lifetime of the connection.
///
/// When in doubt use `write`, which copies.
pub fn writeBorrowed(self: *Client, msg: []const u8) !void {
    if (self.pending != null or self.pending_file != null) return error.WriteInProgress;
    if (self.max_body_size != 0 and msg.len > self.max_body_size) {
        return error.ResponseTooLarge;
    }

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
/// write), asks the poller to report writability so the event loop
/// can resume the send. Used internally by `write`
/// and `continueWrite`.
fn pumpWrite(self: *Client) !void {
    while (true) {
        // Drain whatever is currently in the writer buffer.
        self.writer.writeMessage(self.socket) catch |err| switch (err) {
            error.WouldBlock => {
                // Either kernel EAGAIN or a partial write. Park the
                // rest until the socket is writable. EVFILT.WRITE is
                // level-triggered for this client so a single arm is
                // enough — the poller keeps reporting writability as
                // long as there's send-buffer space.
                try self.poller.writeMode(self);
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

/// Called by the event loop when this client becomes writable. Drives the write state machine and, on completion, flips
/// the client back to read mode for the next request (HTTP/1.1
/// keep-alive).
pub fn continueWrite(self: *Client) !void {
    try self.pumpWrite();
    if (!self.isWriting()) {
        try self.poller.readMode(self);
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

/// Writing to a socket whose peer has gone raises SIGPIPE, and the
/// default disposition of SIGPIPE kills the process. Each platform
/// suppresses that differently:
///
///   * Darwin/BSD set `SO_NOSIGPIPE` once, per accepted socket, so an
///     ordinary `write` is already safe (see `Loom.setNoSigPipe`).
///   * Linux has no such option and needs `MSG_NOSIGNAL` on every call,
///     which means going through `send` rather than `write`.
///
/// Either way the failure comes back as EPIPE and the client is dropped.
const use_send_nosignal = builtin.os.tag == .linux;

fn posixWrite(fd: i32, buf: []const u8) !usize {
    // `send` with no address is `sendto` with a null one; Linux's raw
    // syscall layer only exposes the latter.
    const rc = if (use_send_nosignal)
        posix.system.sendto(fd, buf.ptr, buf.len, posix.MSG.NOSIGNAL, null, 0)
    else
        posix.system.write(fd, buf.ptr, buf.len);
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

test "writing to a hung-up peer reports EPIPE instead of killing the process" {
    // Guards the SIGPIPE suppression, which each platform does
    // differently and which is fatal to get wrong: the default
    // disposition of SIGPIPE terminates the process, so a single client
    // hanging up mid-response would take the whole server down.
    //
    // Deterministic where the socket-level race is not: a socketpair with
    // one end closed puts the write path in exactly the state that
    // raises SIGPIPE, with no timing involved. If suppression is broken
    // on either platform, this test process dies rather than failing.
    var fds: [2]posix.socket_t = undefined;
    const rc = posix.system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (posix.errno(rc) != .SUCCESS) return error.SkipZigTest;
    defer _ = posix.system.close(fds[0]);

    // Darwin suppresses per socket, exactly as the server does on accept.
    // Linux has no such option and relies on MSG_NOSIGNAL per write,
    // which `posixWrite` applies itself.
    if (@hasDecl(std.c.SO, "NOSIGPIPE")) {
        const on: c_int = 1;
        _ = posix.system.setsockopt(
            fds[0],
            posix.SOL.SOCKET,
            std.c.SO.NOSIGPIPE,
            &on,
            @sizeOf(c_int),
        );
    }

    // Peer goes away.
    _ = posix.system.close(fds[1]);

    // Keep writing until the failure surfaces. The first write after a
    // close can still succeed into the socket buffer, so one attempt is
    // not enough to prove anything.
    const payload = [_]u8{'x'} ** 4096;
    var attempts: usize = 0;
    while (attempts < 1000) : (attempts += 1) {
        _ = posixWrite(fds[0], &payload) catch |err| {
            try std.testing.expect(
                err == error.BrokenPipe or
                    err == error.ConnectionReset or
                    err == error.WouldBlock,
            );
            return;
        };
    }
    return error.WriteNeverFailed;
}
