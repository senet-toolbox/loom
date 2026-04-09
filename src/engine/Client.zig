const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const KQueue = @import("KQueue.zig");
const Loom = @import("Loom.zig");
const Fiber = @import("async/Fiber.zig");
const Stack = @import("async/types.zig").Stack;
const Scheduler = @import("async/Scheduler.zig");
const xsuspend = Scheduler.xsuspend;
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

pub const ClientList = std.DoublyLinkedList;
pub const ClientNode = struct {
    node: ClientList.Node,
    data: *Client,
};

pub const Client = @This();
kqueue: *KQueue,

socket: posix.socket_t,
address: std.net.Address,
fiber: ?*Fiber = null,
fiber_index: usize = 0,
stack: ?Stack = undefined,

// Used to read length-prefixed messages
msg: []const u8,

// Used to write messages
writer: Writer,
response: []const u8,

// absolute time, in millisecond, when this client should timeout if
// a message isn't received
read_timeout: i64,

// Node containing this client in the server's read_timeout_list
read_timeout_node: *ClientNode,

client_type: ConnectionType = .HTTP,
state: State = .Open,
ws: ?*Websocket = null,
pending: ?[]const u8 = null,


pub fn init(arena: Allocator, socket: posix.socket_t, address: std.net.Address, kqueue: *KQueue) !Client {
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
        .read_timeout_node = undefined, // hack/ugly, let the server set this when init returns
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

// pub var reader_buf: [2097152]u8 = [_]u8{0} ** 2097152;
pub var reader_buf: []u8 = undefined;
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

pub fn writeMessage(self: *Client) !void {
    self.writer.writeMessage(self.socket) catch |err| {
        switch (err) {
            error.WouldBlock => {
                // Arm for WRITE notifications
                return err;
            },
            error.BrokenPipe, error.ConnectionResetByPeer => {
                // std.debug.print("client disconnected\n", .{});
                // Client disconnected - DON'T try to resume
                // Just return the error and let the event loop clean up
                return err;
            },
            else => return err,
        }
    };
    return; // This is the success (void) case
}

pub fn sendFile(self: *Client, file: std.fs.File) !void {
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try file.read(buf[0..]);
        if (n == 0) break; // EOF reached

        // Fill the write buffer with the chunk
        try self.fillWriteBuffer(buf[0..n]);

        // Keep trying to write THIS chunk until complete
        while (true) {
            self.writeMessage() catch |err| {
                switch (err) {
                    error.WouldBlock => {
                        continue; // Stay in inner loop, retry the SAME chunk
                    },
                    else => {
                        return err;
                    },
                }
            };
            // Write completed, move to next chunk
            break;
        }
    }
}

pub fn write(self: *Client, msg: []const u8) !void {
    try self.fillWriteBuffer(msg);
    while (true) {
        self.writeMessage() catch |err| {
            switch (err) {
                error.WouldBlock => {
                    continue;
                },
                else => {
                    return err;
                },
            }
        };
        // Write completed, move to next chunk
        break;
    }
}

pub fn chunked(self: *Client, payload: []const u8) !void {
    var pos: usize = 0;
    outer: while (pos < payload.len) {
        // Calculate how much we can fit in the buffer
        const remaining = payload.len - pos;
        const buffer_capacity = self.writer.buf.len;
        const chunk_size = @min(remaining, buffer_capacity);

        // Fill the write buffer with the chunk
        self.fillWriteBuffer(payload[pos .. pos + chunk_size]) catch |err| {
            std.debug.print("Fill write buffer error: {any}\n", .{err});
        };

        // Keep trying to write this chunk until complete
        while (true) {
            self.writeMessage() catch |err| {
                switch (err) {
                    error.WouldBlock => {
                        continue :outer;
                    },
                    else => {
                        return err;
                    },
                }
            };
            // Write completed, move to next chunk
            break;
        }
        pos += chunk_size;
    }
}

pub fn fillWriteBuffer(self: *Client, msg: []const u8) !void {
    self.writer.fillWriteBuffer(msg) catch |err| {
        try Loom.logger.err("Fill write buffer {any}", .{err}, @src());
        return err;
    };
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

pub var writer_buf: []u8 = undefined;

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
        const wv = posix.write(socket, self.buf[self.offset..self.pos]) catch |err| {
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
