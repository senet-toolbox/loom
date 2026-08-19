//! Test-side plumbing for the integration suite.
//!
//! Servers run in a spawned thread inside the test process. That is
//! deliberate: a panic, an unhandled signal, or a wedged event loop in
//! Loom takes the test process down with it, which is exactly the
//! failure mode we want these tests to catch.
//!
//! The client side talks to the kernel directly rather than going
//! through `std.Io.net`, so the suite exercises Loom over a real socket
//! with no runtime in between, and so it can do things a polite client
//! wouldn't — half-written requests, RST instead of FIN.

const std = @import("std");
const posix = std.posix;
const system = posix.system;

const loom = @import("loom");

/// How long a client waits on a socket before giving up. Any test that
/// hits this fails rather than hanging the suite.
pub const io_timeout_ms: i64 = 5_000;

/// Block the calling thread. `std.Thread.sleep` is gone in 0.16 and its
/// replacement wants an `Io`; tests just need the syscall.
pub fn sleepMs(ms: u64) void {
    const req = posix.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = system.nanosleep(&req, null);
}

/// Wait for a thread to signal completion, then join it.
///
/// Returns `error.ShutdownTimedOut` rather than blocking forever if it
/// never does — a loop that ignores `stop` should fail the test, not hang
/// the suite. The stuck thread is detached on that path so the process
/// can still exit and report.
pub fn joinWithin(thread: std.Thread, done: *std.atomic.Value(bool), timeout_ms: u64) !void {
    const step_ms = 5;
    var waited: u64 = 0;
    while (waited < timeout_ms) : (waited += step_ms) {
        if (done.load(.acquire)) {
            thread.join();
            return;
        }
        sleepMs(step_ms);
    }
    thread.detach();
    return error.ShutdownTimedOut;
}

// ── Allocation tracking ────────────────────────────────────────────

/// Wraps an allocator and tracks how many bytes are outstanding.
///
/// Exists to catch per-connection leaks. A server that never frees
/// something it allocates on accept still passes a start/stop leak check
/// — the leak only shows up as unbounded growth under churn, which is
/// what `outstanding()` makes visible.
///
/// The server allocates from its own thread, so the counters are atomic.
pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    allocated: std.atomic.Value(usize) = .init(0),
    freed: std.atomic.Value(usize) = .init(0),

    pub fn init(backing: std.mem.Allocator) CountingAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn outstanding(self: *const CountingAllocator) usize {
        return self.allocated.load(.monotonic) - self.freed.load(.monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.vtable.alloc(self.backing.ptr, len, alignment, ra);
        if (result != null) _ = self.allocated.fetchAdd(len, .monotonic);
        return result;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.vtable.resize(self.backing.ptr, buf, alignment, new_len, ra)) return false;
        if (new_len >= buf.len) {
            _ = self.allocated.fetchAdd(new_len - buf.len, .monotonic);
        } else {
            _ = self.freed.fetchAdd(buf.len - new_len, .monotonic);
        }
        return true;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const result = self.backing.vtable.remap(self.backing.ptr, buf, alignment, new_len, ra);
        if (result == null) return null;
        if (new_len >= buf.len) {
            _ = self.allocated.fetchAdd(new_len - buf.len, .monotonic);
        } else {
            _ = self.freed.fetchAdd(buf.len - new_len, .monotonic);
        }
        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.vtable.free(self.backing.ptr, buf, alignment, ra);
        _ = self.freed.fetchAdd(buf.len, .monotonic);
    }
};

// ── Server ─────────────────────────────────────────────────────────

/// A Loom instance running its event loop on its own thread.
///
/// Bound to an ephemeral port, so tests never collide with each other or
/// with a stale server left behind by a previous run.
pub fn Server(comptime Handler: type) type {
    return struct {
        loom: *loom.Loom(Handler),
        thread: std.Thread,
        port: u16,
        allocator: std.mem.Allocator,
        done: *std.atomic.Value(bool),

        const Self = @This();

        pub fn start(
            allocator: std.mem.Allocator,
            handler: Handler,
            config: loom.Loom(Handler).Config,
        ) !Self {
            const instance = try allocator.create(loom.Loom(Handler));
            errdefer allocator.destroy(instance);

            var cfg = config;
            cfg.server_addr = "127.0.0.1";
            cfg.server_port = 0; // let the kernel choose

            try instance.new(cfg, allocator, handler);

            // Bind on this thread so the port is known before the loop
            // starts; otherwise the test would have to race it.
            try instance.bindListener();
            const port = try instance.boundPort();

            const done = try allocator.create(std.atomic.Value(bool));
            errdefer allocator.destroy(done);
            done.* = .init(false);

            const thread = try std.Thread.spawn(.{}, runLoop, .{ instance, done });

            return .{
                .loom = instance,
                .thread = thread,
                .port = port,
                .allocator = allocator,
                .done = done,
            };
        }

        fn runLoop(instance: *loom.Loom(Handler), done: *std.atomic.Value(bool)) void {
            instance.serve() catch |err| {
                std.debug.print("server loop exited: {any}\n", .{err});
            };
            done.store(true, .release);
        }

        pub fn connect(self: Self) !Conn {
            return Conn.open(self.port);
        }

        /// Open `n` connections. Caller frees the slice and closes the
        /// connections.
        pub fn connectMany(self: Self, allocator: std.mem.Allocator, n: usize) ![]Conn {
            const conns = try allocator.alloc(Conn, n);
            errdefer allocator.free(conns);
            var opened: usize = 0;
            errdefer for (conns[0..opened]) |c| c.close();
            while (opened < n) : (opened += 1) {
                conns[opened] = try Conn.open(self.port);
            }
            return conns;
        }

        /// Shut the server down and release everything it owns.
        ///
        /// Joins the loop thread, so once this returns the server is
        /// genuinely gone — which is what lets tests assert on leaks
        /// across a whole server lifecycle rather than just across
        /// `new`/`deinit`.
        pub fn stop(self: *Self) void {
            self.loom.stop();
            // Panic rather than block forever: a loop that ignores `stop`
            // is a bug this suite exists to surface, and a hung run
            // reports nothing at all.
            joinWithin(self.thread, self.done, 5_000) catch {
                @panic("server loop did not stop within 5s");
            };
            self.loom.deinit();
            self.allocator.destroy(self.loom);
            self.allocator.destroy(self.done);
        }
    };
}

// ── Client ─────────────────────────────────────────────────────────

pub const Conn = struct {
    fd: posix.socket_t,

    /// Connect to a server on loopback.
    ///
    /// The stress tests drive hundreds of connects and disconnects a
    /// second through the loopback stack, and the local kernel pushes
    /// back: a full listen backlog refuses, the ephemeral port range runs
    /// dry. That is the test hitting a local limit, not the server
    /// misbehaving, so those specific failures are retried on a fresh
    /// socket. Anything else is a real failure and is reported.
    ///
    /// The retry is deliberately narrow. Retrying every error instead
    /// smears the connection burst out over time, and the burst is what
    /// several of these tests rely on to hit their race.
    pub fn open(port: u16) !Conn {
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            return openOnce(port) catch |err| switch (err) {
                error.ConnectBackpressure => {
                    if (attempt >= 400) return error.ConnectFailed;
                    sleepMs(5);
                    continue;
                },
                else => return err,
            };
        }
    }

    fn openOnce(port: u16) !Conn {
        const rc = system.socket(posix.AF.INET, posix.SOCK.STREAM, posix.IPPROTO.TCP);
        if (@intFromEnum(posix.errno(rc)) != 0) return error.SocketFailed;
        const fd: posix.socket_t = @intCast(rc);
        errdefer _ = system.close(fd);

        var addr: posix.sockaddr.in = .{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
            .zero = .{0} ** 8,
        };

        while (true) {
            const crc = system.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
            switch (posix.errno(crc)) {
                .SUCCESS => break,
                // A signal can interrupt `connect` after the handshake has
                // already completed, so the retry reports the socket as
                // being connected. That is success, not a failure.
                .ISCONN => break,
                .INTR => continue,
                // A failed connect leaves the socket unusable on BSD, so
                // `open` discards it and retries with a fresh one.
                .CONNREFUSED, .TIMEDOUT, .AGAIN, .ADDRNOTAVAIL, .CONNRESET => return error.ConnectBackpressure,
                else => return error.ConnectFailed,
            }
        }

        const conn = Conn{ .fd = fd };
        try conn.setTimeouts(io_timeout_ms);
        return conn;
    }

    fn setTimeouts(self: Conn, ms: i64) !void {
        const tv = std.c.timeval{
            .sec = @intCast(@divTrunc(ms, 1000)),
            .usec = @intCast(@mod(ms, 1000) * 1000),
        };
        const bytes = std.mem.asBytes(&tv);
        try posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, bytes);
        try posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, bytes);
    }

    pub fn send(self: Conn, bytes: []const u8) !void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const rc = system.write(self.fd, bytes.ptr + sent, bytes.len - sent);
            switch (posix.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                .AGAIN => return error.SendTimeout,
                .PIPE, .CONNRESET => return error.ConnectionClosed,
                else => return error.SendFailed,
            }
            if (rc <= 0) return error.ConnectionClosed;
            sent += @intCast(rc);
        }
    }

    /// One read. Returns 0 at end of stream.
    pub fn recv(self: Conn, buf: []u8) !usize {
        while (true) {
            const rc = system.read(self.fd, buf.ptr, buf.len);
            switch (posix.errno(rc)) {
                .SUCCESS => return @intCast(rc),
                .INTR => continue,
                .AGAIN => return error.RecvTimeout,
                .CONNRESET => return error.ConnectionReset,
                else => return error.RecvFailed,
            }
        }
    }

    /// Read until exactly `buf.len` bytes have arrived.
    pub fn recvExactly(self: Conn, buf: []u8) !void {
        var got: usize = 0;
        while (got < buf.len) {
            const n = try self.recv(buf[got..]);
            if (n == 0) return error.UnexpectedEof;
            got += n;
        }
    }

    /// Read and discard exactly `n` bytes.
    ///
    /// Prefer this over `drainUntilClose` whenever the response length is
    /// known: Loom keeps connections alive, so waiting for a close would
    /// just hit the socket timeout.
    pub fn drainExactly(self: Conn, n: usize) !void {
        var remaining = n;
        var chunk: [64 * 1024]u8 = undefined;
        while (remaining > 0) {
            const want = @min(remaining, chunk.len);
            const got = try self.recv(chunk[0..want]);
            if (got == 0) return error.UnexpectedEof;
            remaining -= got;
        }
    }

    /// Wait for the server to hang up, up to `timeout_ms`.
    ///
    /// Returns true if it did. Anything the server sends first is
    /// discarded — the question is only whether the connection ends.
    pub fn waitForClose(self: Conn, timeout_ms: i64) !bool {
        try self.setTimeouts(timeout_ms);
        defer self.setTimeouts(io_timeout_ms) catch {};

        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = self.recv(&chunk) catch |err| switch (err) {
                // A reset is a hang-up too.
                error.ConnectionReset => return true,
                error.RecvTimeout => return false,
                else => return err,
            };
            if (n == 0) return true; // clean EOF
        }
    }

    /// Count bytes until close without keeping them.
    pub fn drainUntilClose(self: Conn) !usize {
        var total: usize = 0;
        var chunk: [64 * 1024]u8 = undefined;
        while (true) {
            const n = self.recv(&chunk) catch |err| switch (err) {
                error.ConnectionReset => break,
                else => return err,
            };
            if (n == 0) break;
            total += n;
        }
        return total;
    }

    /// Close hard: `SO_LINGER` with a zero timeout makes the kernel send
    /// RST instead of FIN, which is how a real client crashing or a load
    /// balancer yanking a connection looks to the server.
    pub fn abort(self: Conn) void {
        const linger = extern struct { onoff: c_int, linger: c_int }{ .onoff = 1, .linger = 0 };
        posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.LINGER, std.mem.asBytes(&linger)) catch {};
        _ = system.close(self.fd);
    }

    pub fn close(self: Conn) void {
        _ = system.close(self.fd);
    }
};

// ── Helpers ────────────────────────────────────────────────────────

pub const get_request = "GET / HTTP/1.1\r\nHost: test\r\n\r\n";

/// Build a fixed-size response with a body of `len` copies of `fill`.
pub fn buildResponse(buf: []u8, body_len: usize, fill: u8) ![]u8 {
    const head = try std.fmt.bufPrint(buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\n\r\n", .{body_len});
    if (head.len + body_len > buf.len) return error.BufferTooSmall;
    @memset(buf[head.len..][0..body_len], fill);
    return buf[0 .. head.len + body_len];
}
