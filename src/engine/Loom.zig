const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const system = std.posix.system;
const print = std.debug.print;
const log = std.log.scoped(.tcp_demo);
const Logger = @import("Logger.zig");
const Parsed = std.json.Parsed;
const net = std.Io.net;
const Scheduler = @import("async/Scheduler.zig");
pub const xresume = Scheduler.xresume;
pub const xsuspend = Scheduler.xsuspend;
const Client = @import("Client.zig");
const Poller = @import("Poller.zig").Backend;
const PollEvent = @import("Poller.zig").Event;
const Abstractions = @import("Abstractions.zig");
const errno = posix.system.errno;
const Time = @import("Time.zig");
// NOTE: `Time.timestamp` is in *seconds*. Deadlines are milliseconds, so
// everything in the timeout path uses `milliTimestamp` -- mixing the two
// is what made the original timeout code never fire.
const milliTimestamp = Time.milliTimestamp;
const native_os = builtin.os.tag;
const SOCK = posix.SOCK;
const socket_t = posix.socket_t;
const F = posix.system.F;
const FD_CLOEXEC = posix.system.FD_CLOEXEC;
const O = posix.system.O;
const sockaddr = posix.system.sockaddr;
const socklen_t = posix.system.socklen_t;
const windows = std.os.windows;

pub const SocketError = error{
    /// Permission to create a socket of the specified type and/or
    /// pro‐tocol is denied.
    PermissionDenied,

    /// The implementation does not support the specified address family.
    AddressFamilyNotSupported,

    /// Unknown protocol, or protocol family not available.
    ProtocolFamilyNotAvailable,

    /// The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,

    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,

    /// Insufficient memory is available. The socket cannot be created until sufficient
    /// resources are freed.
    SystemResources,

    /// The protocol type or the specified protocol is not supported within this domain.
    ProtocolNotSupported,

    /// The socket type is not supported by the protocol.
    SocketTypeNotSupported,
} || UnexpectedError;

pub const UnexpectedError = error{
    /// The Operating System returned an undocumented error code.
    ///
    /// This error is in theory not possible, but it would be better
    /// to handle this error than to invoke undefined behavior.
    ///
    /// When this error code is observed, it usually means the Zig Standard
    /// Library needs a small patch to add the error code to the error set for
    /// the respective function.
    Unexpected,
};

// EVFILT_READ
// Monitors for data available to read
// For sockets: triggers when data arrives
// For files: triggers when data is available
// The .data field will contain number of bytes available

// EVFILT_WRITE
// Monitors for write space available
// Triggers when buffer space is available for writing
// .data field contains space available in buffer

// EVFILT_AIO
// For asynchronous I/O operations
// Monitors completion of aio_* functions
// Great for bulk file operations

// EVFILT_VNODE
// Monitors changes to files and directories
// Can detect: delete, write, extend, attrib, link, rename
// Commonly used for config file monitoring

// EVFILT_PROC
// Monitors process events
// Can detect: exit, fork, exec, signal
// Useful for process supervision

// EVFILT_SIGNAL
// Monitors for Unix signals
// Alternative to traditional signal handlers
// More flexible than signal()

// EVFILT_TIMER
// Creates a timer event
// Can be one-shot or periodic
// More efficient than multiple individual timers

// EVFILT_USER
// User-triggered events
// Allows triggering events from userspace
// Useful for inter-thread communication

// EV_ADD
// Add an event to kqueue monitoring
// If it exists, modify it
// Most common flag you'll use

// EV_DELETE
// Remove event from monitoring
// Stops watching for this event
// Use when cleaning up

// EV_ENABLE
// Enable an event that was disabled
// Event can now trigger
// Paired with EV_DISABLE

// EV_DISABLE
// Temporarily disable event
// Event won't trigger until enabled
// Good for temporary suspensions

// EV_ONESHOT
// Only trigger once
// Automatically removed after triggering
// Good for one-time notifications

// EV_CLEAR
// Clear event state after triggering
// Prevents edge-triggered notification pileup
// Important for high-throughput scenarios

// EV_EOF
// End of file condition
// Set by system when EOF detected
// Useful for connection handling

// EV_ERROR
// Error condition
// Set by system when error occurs
// Check errno for details

/// Default for `Config.idle_timeout_ms`: one minute without progress.
const READ_TIMEOUT_MS = 60_000;

const ClientList = Client.ClientList;
pub var logger: Logger = undefined;
pub const fd_t = system.fd_t;
const builtin = @import("builtin");

pub const unexpected_error_tracing = builtin.zig_backend == .stage2_llvm and builtin.mode == .Debug;

/// Call this when you made a syscall or something that sets errno
/// and you get an unexpected error.
pub fn unexpectedErrno(err: posix.system.E) UnexpectedError {
    if (unexpected_error_tracing) {
        std.debug.print("unexpected errno: {d}\n", .{@intFromEnum(err)});
        std.debug.dumpCurrentStackTrace(.{});
    }
    return error.Unexpected;
}

pub fn Loom(comptime Handler: type) type {
    return struct {
        handler: Handler,
        arena: Allocator = undefined,
        config: Config = undefined,
        // Max connections
        max: usize = undefined,

        // Cleared by `stop` to break the event loop. Atomic because
        // `stop` is meant to be callable from another thread (or a signal
        // handler) while the loop is parked in `kevent`.
        running: std.atomic.Value(bool) = .init(true),

        listener: posix.socket_t = -1,
        // Whether the listener is currently armed in the kqueue. Parked
        // when we hit `max` (or run out of file descriptors) and re-armed
        // as soon as a connection slot frees up.
        listener_armed: bool = false,

        // Event Loop
        poller: Poller = undefined,
        threaded: std.Io.Threaded = .init_single_threaded,

        // The number of clients we currently have connected
        connected: u32 = undefined,

        // Live connections in deadline order, oldest first. Every client
        // shares one timeout duration, so refreshing a deadline means
        // moving its node to the tail — which keeps the list sorted
        // without ever comparing anything.
        read_timeout_list: ClientList = undefined,
        idle_timeout_ms: i64 = READ_TIMEOUT_MS,

        // for creating client
        client_pool: Abstractions.ManagedMemoryPool(Client) = undefined,
        max_body_size: usize,

        // Free connection slots, popped on accept and pushed back on
        // close. Doubles as the connection limiter. Holds indices in
        // `slot_base .. slot_base + max`.
        free_slots: std.array_list.Managed(usize) = undefined,
        slot_base: usize = 0,

        // False when the listener belongs to someone else (a `Cluster`
        // sharing one socket across workers), in which case this instance
        // must not close it.
        owns_listener: bool = true,

        stats: Stats = .{},

        // Clients marked for teardown during the current event batch.
        // Draining is deferred to the end of the batch so that a client
        // is never freed while later events in the same batch still
        // reference it.
        close_queue: std.array_list.Managed(*Client) = undefined,

        /// Cheap per-worker counters.
        ///
        /// Plain integers, not atomics: a `Loom` is only ever touched by
        /// its own thread, so incrementing costs nothing. Reading them
        /// from another thread is racy in the harmless way — you may see
        /// a slightly stale count, never a torn one on any target we
        /// support.
        pub const Stats = struct {
            /// Times the loop was woken by the listener being readable.
            listener_wakeups: u64 = 0,
            /// Wakeups that yielded no connection at all, because another
            /// worker won the race. This is the cost of sharing one
            /// listener between workers.
            empty_listener_wakeups: u64 = 0,
            /// Connections accepted by this worker.
            accepted: u64 = 0,
            /// Connections refused because every slot was taken.
            rejected_at_capacity: u64 = 0,
            /// Connections dropped for making no progress in time.
            timed_out: u64 = 0,
        };

        pub const Config = struct {
            server_addr: []const u8 = "0.0.0.0",
            server_port: u16 = 8080,
            sticky_server: bool = false,
            max: usize = 256,
            max_body_size: usize = 4 * 1024 * 1024,

            /// Size of a connection's read buffer at accept time. Kept
            /// small because every connection gets its own -- the buffer
            /// grows on demand for the connections that actually need it,
            /// rather than every slot paying for the worst case up front.
            initial_read_size: usize = 16 * 1024,

            /// Ceiling a connection's read buffer may grow to.
            max_read_size: usize = 2097152,

            /// First connection slot index this instance hands out.
            ///
            /// Only interesting under `Cluster`, which gives each worker a
            /// disjoint range so that a slot identifies a connection
            /// uniquely across the whole server, not just within one
            /// worker. Downstream code keying per-connection state by
            /// slot then needs no knowledge of workers at all.
            slot_base: usize = 0,

            /// Drop a connection that goes this long without making
            /// progress — no bytes read, and no bytes of a pending
            /// response accepted by the kernel. Set to 0 to disable.
            ///
            /// This is what stops an idle or deliberately-stalled peer
            /// (slowloris, a client that opens sockets and never speaks,
            /// a reader that stops draining mid-response) from holding a
            /// connection slot forever.
            idle_timeout_ms: i64 = READ_TIMEOUT_MS,
        };

        pub fn new(target: *Loom(Handler), config: Config, arena: Allocator, handler: Handler) !void {
            if (config.max == 0) return error.InvalidConfig;
            if (config.initial_read_size == 0) return error.InvalidConfig;
            if (config.max_read_size < config.initial_read_size) return error.InvalidConfig;

            var poller = try Poller.init();
            errdefer poller.deinit();

            // Queued now, flushed when the listener is armed.
            try poller.registerWake();

            // Connection slots, handed out on accept. Popped from the end.
            var free_list = std.array_list.Managed(usize).init(arena);
            errdefer free_list.deinit();
            try free_list.ensureTotalCapacity(config.max);
            for (0..config.max) |i| {
                free_list.appendAssumeCapacity(config.slot_base + i);
            }

            // Capacity is `max` and a client can only be queued once (the
            // `closing` flag guards re-entry), so draining never allocates.
            var close_queue = std.array_list.Managed(*Client).init(arena);
            errdefer close_queue.deinit();
            try close_queue.ensureTotalCapacity(config.max);

            logger.init();
            target.* = Loom(Handler){
                .config = config,
                .arena = arena,
                .max = config.max,
                .connected = 0,
                .read_timeout_list = .{},
                .client_pool = Abstractions.ManagedMemoryPool(Client).init(arena),
                .idle_timeout_ms = config.idle_timeout_ms,
                .slot_base = config.slot_base,
                .poller = poller,
                .running = .init(true),
                .threaded = .init_single_threaded,
                .max_body_size = config.max_body_size,
                .free_slots = free_list,
                .close_queue = close_queue,
                .handler = handler,
            };
        }

        /// The `std.Io` for this server.
        ///
        /// Derived on every call rather than cached in a field, because
        /// `Threaded.io()` embeds `&self.threaded` as its userdata. A
        /// cached copy silently dangles the moment the `Loom` is moved —
        /// and callers do move it, e.g. by initialising one on the stack
        /// and then storing it into a longer-lived struct. Deriving it
        /// makes that impossible to get wrong.
        pub fn io(self: *Loom(Handler)) std.Io {
            return self.threaded.io();
        }

        pub fn deinit(self: *Loom(Handler)) void {
            // Tear down anything still connected before the pools go.
            // Walking the timeout list is how we reach live clients --
            // the close queue only holds ones already on their way out.
            var it = self.read_timeout_list.first;
            while (it) |node| {
                const next = node.next;
                self.closeClient(clientFromTimeoutNode(node));
                it = next;
            }
            self.drainCloseQueue();

            if (self.listener >= 0) {
                if (self.owns_listener) close(self.listener);
                self.listener = -1;
                self.listener_armed = false;
            }
            self.poller.deinit();
            self.client_pool.deinit();
            self.free_slots.deinit();
            self.close_queue.deinit();
            self.threaded.deinit();
        }

        /// Park the listener so the kernel stops handing us connections we
        /// have no slot for. Idempotent.
        fn disarmListener(self: *Loom(Handler)) void {
            if (!self.listener_armed or self.listener < 0) return;
            self.poller.removeListener(self.listener) catch |err| {
                log.err("failed to park listener: {any}", .{err});
                return;
            };
            self.listener_armed = false;
        }

        /// Re-arm the listener once a connection slot is available again.
        /// Idempotent.
        fn armListener(self: *Loom(Handler)) void {
            if (self.listener_armed or self.listener < 0) return;
            if (self.free_slots.items.len == 0) return;
            self.poller.enableListener(self.listener) catch |err| {
                log.err("failed to re-arm listener: {any}", .{err});
                return;
            };
            self.listener_armed = true;
        }

        pub fn close(fd: fd_t) void {
            switch (errno(system.close(fd))) {
                .BADF => unreachable, // Always a race condition.
                .INTR => return, // This is still a success. See https://github.com/ziglang/zig/issues/2425
                else => return,
            }
        }
        pub fn connectSocket(domain: u32, socket_type: u32, protocol: u32) anyerror!posix.socket_t {
            if (native_os == .windows) {
                // These flags are not actually part of the Windows API, instead they are converted here for compatibility
                const filtered_sock_type = socket_type & ~@as(u32, SOCK.NONBLOCK | SOCK.CLOEXEC);
                var flags: u32 = windows.ws2_32.WSA_FLAG_OVERLAPPED;
                if ((socket_type & SOCK.CLOEXEC) != 0) flags |= windows.ws2_32.WSA_FLAG_NO_HANDLE_INHERIT;

                const rc = try windows.WSASocketW(
                    @bitCast(domain),
                    @bitCast(filtered_sock_type),
                    @bitCast(protocol),
                    null,
                    0,
                    flags,
                );
                errdefer windows.closesocket(rc) catch unreachable;
                if ((socket_type & SOCK.NONBLOCK) != 0) {
                    var mode: c_ulong = 1; // nonblocking
                    if (windows.ws2_32.SOCKET_ERROR == windows.ws2_32.ioctlsocket(rc, windows.ws2_32.FIONBIO, &mode)) {
                        switch (windows.ws2_32.WSAGetLastError()) {
                            // have not identified any error codes that should be handled yet
                            else => unreachable,
                        }
                    }
                }
                return rc;
            }

            const have_sock_flags = !builtin.target.os.tag.isDarwin() and native_os != .haiku;
            const filtered_sock_type = if (!have_sock_flags)
                socket_type & ~@as(u32, SOCK.NONBLOCK | SOCK.CLOEXEC)
            else
                socket_type;
            const rc = system.socket(domain, filtered_sock_type, protocol);
            switch (errno(rc)) {
                .SUCCESS => {
                    const fd: fd_t = @intCast(rc);
                    errdefer close(fd);
                    if (!have_sock_flags) {
                        try setSockFlags(fd, socket_type);
                    }
                    return fd;
                },
                .ACCES => return error.AccessDenied,
                .AFNOSUPPORT => return error.AddressFamilyNotSupported,
                .INVAL => return error.ProtocolFamilyNotAvailable,
                .MFILE => return error.ProcessFdQuotaExceeded,
                .NFILE => return error.SystemFdQuotaExceeded,
                .NOBUFS => return error.SystemResources,
                .NOMEM => return error.SystemResources,
                .PROTONOSUPPORT => return error.ProtocolNotSupported,
                .PROTOTYPE => return error.SocketTypeNotSupported,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn createListener(loom: *Loom(Handler)) !c_int {
            // const self_addr = try net.Address.resolveIp(loom.config.server_addr, loom.config.server_port);
            const self_addr = try net.IpAddress.parse(loom.config.server_addr, loom.config.server_port);

            const domain: u32 = switch (self_addr) {
                .ip4 => posix.AF.INET,
                .ip6 => posix.AF.INET6,
            };

            // 1. Create non-blocking socket
            const tpe: u32 = posix.SOCK.STREAM | posix.SOCK.NONBLOCK;

            const listener = connectSocket(domain, tpe, posix.IPPROTO.TCP) catch |err| {
                std.debug.print("Failed to create socket: {any}\n", .{err});
                return err;
            };

            // Build a proper sockaddr_in from the parsed IpAddress
            var addr: posix.sockaddr.in = .{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, loom.config.server_port),
                .addr = @bitCast(self_addr.ip4.bytes),
                .zero = .{0} ** 8,
            };

            // 2. Set REUSEPORT FIRST (MUST BE BEFORE BIND)
            const reuse = std.mem.toBytes(@as(c_int, 1));
            try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEPORT, &reuse);
            try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &reuse);

            // 3. Bind and listen
            const addr_len: posix.socklen_t = switch (self_addr) {
                .ip4 => @sizeOf(posix.sockaddr.in),
                .ip6 => @sizeOf(posix.sockaddr.in6),
            };

            bind(listener, @ptrCast(&addr), addr_len) catch |err| {
                std.debug.print("Failed to bind socket: {any}\n", .{err});
                return err;
            };
            try connlisten(listener, 4096);

            // 4. Add to THIS THREAD'S kqueue (not a shared one)
            try loom.poller.addListener(listener);
            loom.listener = listener;
            loom.listener_armed = true;

            // 5. Force flush kqueue changes immediately
            try loom.poller.flushChanges();

            return listener;
        }

        pub fn connlisten(sock: posix.socket_t, backlog: u31) anyerror!void {
            const rc = system.listen(sock, backlog);
            switch (errno(rc)) {
                .SUCCESS => return,
                .ADDRINUSE => return error.AddressInUse,
                .BADF => unreachable,
                .NOTSOCK => return error.FileDescriptorNotASocket,
                .OPNOTSUPP => return error.OperationNotSupported,
                else => |err| return unexpectedErrno(err),
            }
        }

        pub fn bind(sock: socket_t, addr: *const sockaddr, len: socklen_t) anyerror!void {
            if (native_os == .windows) {
                const rc = windows.bind(sock, addr, len);
                if (rc == windows.ws2_32.SOCKET_ERROR) {
                    switch (windows.ws2_32.WSAGetLastError()) {
                        .WSANOTINITIALISED => unreachable, // not initialized WSA
                        .WSAEACCES => return error.AccessDenied,
                        .WSAEADDRINUSE => return error.AddressInUse,
                        .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
                        .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                        .WSAEFAULT => unreachable, // invalid pointers
                        .WSAEINVAL => return error.AlreadyBound,
                        .WSAENOBUFS => return error.SystemResources,
                        .WSAENETDOWN => return error.NetworkSubsystemFailed,
                        else => |err| return windows.unexpectedWSAError(err),
                    }
                    unreachable;
                }
                return;
            } else {
                const rc = system.bind(sock, addr, len);
                switch (errno(rc)) {
                    .SUCCESS => return,
                    .ACCES, .PERM => return error.AccessDenied,
                    .ADDRINUSE => return error.AddressInUse,
                    .BADF => unreachable, // always a race condition if this error is returned
                    .INVAL => unreachable, // invalid parameters
                    .NOTSOCK => unreachable, // invalid `sockfd`
                    .AFNOSUPPORT => return error.AddressFamilyNotSupported,
                    .ADDRNOTAVAIL => return error.AddressNotAvailable,
                    .FAULT => unreachable, // invalid `addr` pointer
                    .LOOP => return error.SymLinkLoop,
                    .NAMETOOLONG => return error.NameTooLong,
                    .NOENT => return error.FileNotFound,
                    .NOMEM => return error.SystemResources,
                    .NOTDIR => return error.NotDir,
                    .ROFS => return error.ReadOnlyFileSystem,
                    else => |err| return unexpectedErrno(err),
                }
            }
            unreachable;
        }

        /// Create, bind and arm the listening socket without entering the
        /// event loop.
        ///
        /// Split out from `serve` so a caller can learn the bound port
        /// (see `boundPort`) before the loop takes over the thread, which
        /// is what makes `server_port = 0` usable. Idempotent.
        pub fn bindListener(loom: *Loom(Handler)) !void {
            if (loom.listener >= 0) return;
            _ = loom.createListener() catch |err| {
                log.err("failed to create listener: {any}", .{err});
                return err;
            };
        }

        /// Use an already-bound listening socket instead of creating one.
        ///
        /// The socket stays the caller's property: `deinit` will not close
        /// it. This is how `Cluster` puts every worker on one listener --
        /// each registers it in its own kqueue and they race to accept,
        /// which spreads connections toward whichever workers are idle.
        pub fn adoptListener(loom: *Loom(Handler), fd: posix.socket_t) !void {
            if (loom.listener >= 0) return error.AlreadyBound;
            loom.listener = fd;
            loom.owns_listener = false;
            try loom.poller.addListener(fd);
            loom.listener_armed = true;
            try loom.poller.flushChanges();
        }

        /// The port the listener actually bound to. Only meaningful after
        /// `bindListener`; the interesting case is `server_port = 0`, where
        /// the kernel picks an ephemeral port.
        pub fn boundPort(loom: *Loom(Handler)) !u16 {
            if (loom.listener < 0) return error.NotBound;
            var addr: posix.sockaddr.in = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            switch (errno(system.getsockname(loom.listener, @ptrCast(&addr), &addr_len))) {
                .SUCCESS => return std.mem.bigToNative(u16, addr.port),
                else => |err| return unexpectedErrno(err),
            }
        }

        /// Bind if needed, then run the event loop until `stop` is called
        /// or the loop fails.
        pub fn serve(loom: *Loom(Handler)) !void {
            try loom.bindListener();
            try run(loom);
        }

        /// Ask the event loop to finish.
        ///
        /// Safe to call from another thread while the loop is parked in
        /// `kevent`: the flag is atomic and the wake goes through its own
        /// syscall rather than the loop's pending-change list. `serve`
        /// returns once the in-flight batch is done; connections are torn
        /// down by `deinit`, not here.
        ///
        /// Idempotent, and safe to call before the loop has started — the
        /// loop then exits at its first check.
        pub fn stop(loom: *Loom(Handler)) void {
            loom.running.store(false, .release);
            loom.poller.wake();
        }

        /// This function calls listen on the Loom instance.
        pub fn listen(loom: *Loom(Handler)) !void {
            return loom.serve();
        }

        fn run(loom: *Loom(Handler)) !void {
            while (loom.running.load(.acquire)) {
                // Reap anything past its deadline, then block only until
                // the next deadline is due.
                const next_timeout = loom.enforceTimeout();
                loom.drainCloseQueue();

                const ready_events = loom.readEvents(next_timeout) catch |err| switch (err) {
                    // A signal interrupted the wait; nothing was dropped.
                    error.Interrupted, error.WouldBlock => continue,
                    else => return err,
                };

                for (ready_events) |ready| {
                    switch (ready.source) {
                        // Only ever means "re-check the running flag",
                        // which the enclosing while already does.
                        .wake => continue,

                        .listener => loom.acceptPending(),

                        .client => {
                            const client: *Client = @ptrFromInt(ready.client_ptr);

                            // The client was torn down earlier in this same
                            // batch. Its memory is still alive (the close
                            // queue is drained below) but the socket is gone,
                            // so the event is stale.
                            if (client.closing) continue;

                            // The poller reports per-descriptor failures
                            // inline. It is dead either way, so drop it.
                            if (ready.failed) {
                                loom.closeClient(client);
                                continue;
                            }

                            // Both may be set at once: epoll reports one
                            // event per descriptor with every ready
                            // condition combined, where kqueue reports one
                            // per filter.
                            if (ready.readable) {
                                while (true) {
                                    const msg = client.readMessage() catch |err| {
                                        switch (err) {
                                            error.WouldBlock => break,
                                            else => {
                                                loom.closeClient(client);
                                                break;
                                            },
                                        }
                                    };

                                    loom.touchClient(client);

                                    loom.handler.process(client, msg) catch {
                                        loom.closeClient(client);
                                        break;
                                    };

                                    // The handler may have closed the client
                                    // (directly, or by way of a failed write).
                                    if (client.closing) break;
                                }
                            }

                            if (ready.writable and !client.closing) {
                                // Drive the write state machine forward. On
                                // completion this also flips the client back
                                // to read mode for the next keep-alive request.
                                client.continueWrite() catch {
                                    loom.closeClient(client);
                                    continue;
                                };
                                // The socket took more bytes, so this
                                // connection is progressing even though
                                // nothing was read.
                                loom.touchClient(client);
                            }
                        },
                    }
                }

                // Every event in the batch has been inspected, so no stale
                // pointers remain. Safe to actually free.
                loom.drainCloseQueue();
            }
        }

        /// Drain the accept backlog. Stops on the first would-block, on a
        /// full connection table, or on a persistent error — never spins.
        fn acceptPending(loom: *Loom(Handler)) void {
            loom.stats.listener_wakeups += 1;
            const before = loom.stats.accepted;
            defer if (loom.stats.accepted == before) {
                loom.stats.empty_listener_wakeups += 1;
            };

            while (true) {
                loom.acceptConn() catch |err| switch (err) {
                    // Backlog drained; the listener is level-triggered so
                    // kevent will tell us when there's more.
                    error.WouldBlock => return,

                    // No slot free. The listener is parked; it gets re-armed
                    // by `drainCloseQueue` when one frees up.
                    error.NoCapacity => {
                        loom.stats.rejected_at_capacity += 1;
                        return;
                    },

                    // Out of file descriptors. Park the listener rather than
                    // spinning on a failure that won't clear on its own.
                    error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded => {
                        log.err("out of file descriptors, parking listener", .{});
                        loom.disarmListener();
                        return;
                    },

                    // The peer went away between the event and the accept.
                    // The next one may still be good.
                    error.ConnectionAborted => continue,

                    else => |e| {
                        log.err("accept error: {any}", .{e});
                        return;
                    },
                };
            }
        }

        /// Recover the client that owns a timeout-list node.
        fn clientFromTimeoutNode(node: *ClientList.Node) *Client {
            return @fieldParentPtr("timeout_node", node);
        }

        /// Mark this connection as having made progress, pushing its
        /// deadline out and moving it to the tail of the list.
        ///
        /// Called for every read and for every write the kernel accepts,
        /// so a slow-but-progressing transfer is never mistaken for a
        /// stalled one.
        fn touchClient(self: *Loom(Handler), client: *Client) void {
            if (client.closing) return;
            client.read_timeout = milliTimestamp() + self.idle_timeout_ms;
            self.read_timeout_list.remove(&client.timeout_node);
            self.read_timeout_list.append(&client.timeout_node);
        }

        /// Close every connection that has blown its deadline and report
        /// how long the loop may block before the next one expires.
        ///
        /// Returns a millisecond timeout for `wait`, or -1 to block
        /// indefinitely when nothing is pending. Clients are closed
        /// through the normal deferred path, so the caller must drain the
        /// close queue before blocking again.
        pub fn enforceTimeout(self: *Loom(Handler)) i32 {
            if (self.idle_timeout_ms == 0) return -1;

            const now = milliTimestamp();
            // Walk with an explicit cursor and never unlink here: nodes
            // are removed by `drainCloseQueue` alone, so there is exactly
            // one place that can take a client out of this list.
            var it = self.read_timeout_list.first;
            while (it) |node| {
                const next = node.next;
                const client = clientFromTimeoutNode(node);

                // Already queued for teardown; it will be unlinked on the
                // next drain. Skip rather than stall on it.
                if (!client.closing) {
                    const remaining = client.read_timeout - now;
                    if (remaining > 0) {
                        // The list is deadline-ordered, so the first
                        // client still in the future bounds the wait.
                        return std.math.cast(i32, remaining) orelse std.math.maxInt(i32);
                    }
                    self.stats.timed_out += 1;
                    self.closeClient(client);
                }
                it = next;
            }
            return -1;
        }

        pub fn accept(
            /// This argument is a socket that has been created with `socket`, bound to a local address
            /// with `bind`, and is listening for connections after a `listen`.
            sock: posix.socket_t,
            /// This argument is a pointer to a sockaddr structure.  This structure is filled in with  the
            /// address  of  the  peer  socket, as known to the communications layer.  The exact format of the
            /// address returned addr is determined by the socket's address  family  (see  `socket`  and  the
            /// respective  protocol  man  pages).
            addr: ?*posix.sockaddr,
            /// This argument is a value-result argument: the caller must initialize it to contain  the
            /// size (in bytes) of the structure pointed to by addr; on return it will contain the actual size
            /// of the peer address.
            ///
            /// The returned address is truncated if the buffer provided is too small; in this  case,  `addr_size`
            /// will return a value greater than was supplied to the call.
            addr_size: ?*posix.socklen_t,
            /// The following values can be bitwise ORed in flags to obtain different behavior:
            /// * `SOCK.NONBLOCK` - Set the `NONBLOCK` file status flag on the open file description (see `open`)
            ///   referred  to by the new file descriptor.  Using this flag saves extra calls to `fcntl` to achieve
            ///   the same result.
            /// * `SOCK.CLOEXEC`  - Set the close-on-exec (`FD_CLOEXEC`) flag on the new file descriptor.   See  the
            ///   description  of the `CLOEXEC` flag in `open` for reasons why this may be useful.
            flags: u32,
        ) anyerror!posix.socket_t {
            const have_accept4 = !(builtin.target.isDarwinLibC() or builtin.os.tag == .windows or builtin.os.tag == .linux);
            std.debug.assert(0 == (flags & ~@as(u32, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC))); // Unsupported flag(s)

            const accepted_sock: posix.socket_t = while (true) {
                const rc = if (have_accept4)
                    system.accept4(sock, addr, addr_size, flags)
                else
                    system.accept(sock, addr, addr_size);

                switch (errno(rc)) {
                    .SUCCESS => break @intCast(rc),
                    .INTR => continue,
                    .AGAIN => return error.WouldBlock,
                    .BADF => unreachable, // always a race condition
                    .CONNABORTED => return error.ConnectionAborted,
                    .FAULT => unreachable,
                    .INVAL => return error.SocketNotListening,
                    .NOTSOCK => unreachable,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    .NOBUFS => return error.SystemResources,
                    .NOMEM => return error.SystemResources,
                    .OPNOTSUPP => unreachable,
                    .PROTO => return error.ProtocolFailure,
                    .PERM => return error.BlockedByFirewall,
                    else => |err| return unexpectedErrno(err),
                }
            };

            errdefer close(accepted_sock);
            if (!have_accept4) {
                try setSockFlags(accepted_sock, flags);
            }
            return accepted_sock;
        }

        pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) anyerror!usize {
            while (true) {
                const rc = system.fcntl(fd, cmd, arg);
                switch (errno(rc)) {
                    .SUCCESS => return @intCast(rc),
                    .INTR => continue,
                    .AGAIN, .ACCES => return error.Locked,
                    .BADF => unreachable,
                    .BUSY => return error.FileBusy,
                    .INVAL => unreachable, // invalid parameters
                    .PERM => return error.PermissionDenied,
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NOTDIR => unreachable, // invalid parameter
                    .DEADLK => return error.DeadLock,
                    .NOLCK => return error.LockedRegionLimitExceeded,
                    else => |err| return unexpectedErrno(err),
                }
            }
        }

        fn setSockFlags(sock: socket_t, flags: u32) !void {
            if ((flags & SOCK.CLOEXEC) != 0) {
                if (native_os == .windows) {
                    // TODO: Find out if this is supported for sockets
                } else {
                    var fd_flags = fcntl(sock, F.GETFD, 0) catch |err| switch (err) {
                        error.FileBusy => unreachable,
                        error.Locked => unreachable,
                        error.PermissionDenied => unreachable,
                        error.DeadLock => unreachable,
                        error.LockedRegionLimitExceeded => unreachable,
                        else => |e| return e,
                    };
                    fd_flags |= FD_CLOEXEC;
                    _ = fcntl(sock, F.SETFD, fd_flags) catch |err| switch (err) {
                        error.FileBusy => unreachable,
                        error.Locked => unreachable,
                        error.PermissionDenied => unreachable,
                        error.DeadLock => unreachable,
                        error.LockedRegionLimitExceeded => unreachable,
                        else => |e| return e,
                    };
                }
            }
            if ((flags & SOCK.NONBLOCK) != 0) {
                if (native_os == .windows) {
                    var mode: c_ulong = 1;
                    if (windows.ws2_32.ioctlsocket(sock, windows.ws2_32.FIONBIO, &mode) == windows.ws2_32.SOCKET_ERROR) {
                        switch (windows.ws2_32.WSAGetLastError()) {
                            .WSANOTINITIALISED => unreachable,
                            .WSAENETDOWN => return error.NetworkSubsystemFailed,
                            .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                            // TODO: handle more errors
                            else => |err| return windows.unexpectedWSAError(err),
                        }
                    }
                } else {
                    var fl_flags = fcntl(sock, F.GETFL, 0) catch |err| switch (err) {
                        error.FileBusy => unreachable,
                        error.Locked => unreachable,
                        error.PermissionDenied => unreachable,
                        error.DeadLock => unreachable,
                        error.LockedRegionLimitExceeded => unreachable,
                        else => |e| return e,
                    };
                    fl_flags |= 1 << @bitOffsetOf(O, "NONBLOCK");
                    _ = fcntl(sock, F.SETFL, fl_flags) catch |err| switch (err) {
                        error.FileBusy => unreachable,
                        error.Locked => unreachable,
                        error.PermissionDenied => unreachable,
                        error.DeadLock => unreachable,
                        error.LockedRegionLimitExceeded => unreachable,
                        else => |e| return e,
                    };
                }
            }
        }

        /// On Darwin/BSD a `write` to a socket whose peer has already gone
        /// away raises SIGPIPE, and the default disposition of SIGPIPE is
        /// to kill the process. Suppress it per-socket so the write
        /// surfaces as EPIPE and the client is simply dropped.
        ///
        /// Best-effort on purpose, via the raw syscall: a peer that resets
        /// between `accept` and here leaves the socket in a state that
        /// rejects the option with EINVAL, and `posix.setsockopt` treats
        /// that as unreachable. Nothing to do about it either way — the
        /// next read or write on the socket will fail and drop the client.
        fn setNoSigPipe(sock: posix.socket_t) void {
            if (!@hasDecl(std.c.SO, "NOSIGPIPE")) return;
            const on: c_int = 1;
            _ = system.setsockopt(
                sock,
                posix.SOL.SOCKET,
                std.c.SO.NOSIGPIPE,
                &on,
                @sizeOf(c_int),
            );
        }

        /// Accept a single pending connection.
        ///
        /// Returns `error.WouldBlock` when the backlog is drained and
        /// `error.NoCapacity` when the connection table is full (the
        /// listener is parked as a side effect). Both are signals to the
        /// caller to stop looping, never to retry immediately.
        pub fn acceptConn(self: *Loom(Handler)) !void {
            var address: net.IpAddress = undefined;
            var address_len: posix.socklen_t = @sizeOf(net.IpAddress);

            if (self.free_slots.items.len == 0 or self.connected >= self.max) {
                // Out of slots. Park the listener; `drainCloseQueue` re-arms
                // it as soon as a connection closes.
                self.disarmListener();
                return error.NoCapacity;
            }

            const socket = try accept(self.listener, @ptrCast(&address), &address_len, posix.SOCK.NONBLOCK);
            errdefer close(socket);
            setNoSigPipe(socket);

            const client: *Client = try self.client_pool.create();
            errdefer self.client_pool.destroy(client);

            client.* = Client.init(
                self.arena,
                self.io(),
                socket,
                address,
                &self.poller,
                self.config.initial_read_size,
                self.config.max_read_size,
                self.config.max_body_size,
            ) catch |err| {
                log.err("failed to initialize client: {}", .{err});
                return err;
            };
            errdefer client.deinit(self.arena);

            client.timeout_node = .{};
            client.state = .Connected;
            client.client_type = .HTTP;
            client.closing = false;

            // Claim a connection slot. Checked non-empty above.
            client.slot = self.free_slots.pop().?;
            errdefer self.free_slots.appendAssumeCapacity(client.slot);

            try self.poller.newClient(client);
            self.connected += 1;
            self.stats.accepted += 1;

            // Newest deadline, so it belongs at the tail.
            client.read_timeout = milliTimestamp() + self.idle_timeout_ms;
            self.read_timeout_list.append(&client.timeout_node);
        }

        pub fn readEvents(loom: *Loom(Handler), next_timeout: i32) ![]PollEvent {
            return try loom.poller.wait(next_timeout);
        }

        /// Mark a client for teardown.
        ///
        /// The client is *not* freed here. Freeing it mid-batch would leave
        /// later events in the same `kevent` batch pointing at reclaimed
        /// memory — the socket is closed, the pool slot is handed to the
        /// next connection, and the loop reads through a dangling pointer.
        /// Instead the client is flagged and queued; `drainCloseQueue`
        /// finishes the job once the batch is fully processed.
        ///
        /// Safe to call more than once for the same client.
        pub fn closeClient(self: *Loom(Handler), client: *Client) void {
            if (client.closing) return;
            client.closing = true;

            // Any arm/disarm still sitting in the change list would be
            // flushed against a descriptor we are about to close.
            self.poller.purgeChanges(client.socket);

            // Capacity is `max` and each client enqueues at most once.
            std.debug.assert(self.close_queue.items.len < self.max);
            self.close_queue.appendAssumeCapacity(client);
        }

        /// Free every client queued by `closeClient` during this batch.
        fn drainCloseQueue(self: *Loom(Handler)) void {
            if (self.close_queue.items.len == 0) return;

            for (self.close_queue.items) |client| {
                if (client.pending_file) |f| {
                    f.close(self.io());
                    client.pending_file = null;
                }
                client.pending = null;

                // Return the connection slot.
                std.debug.assert(client.slot >= self.slot_base);
                std.debug.assert(client.slot - self.slot_base < self.max);
                self.free_slots.appendAssumeCapacity(client.slot);

                self.read_timeout_list.remove(&client.timeout_node);
                client.deinit(self.arena);

                // Closing the descriptor drops its kqueue registrations.
                close(client.socket);
                client.socket = -1;

                self.client_pool.destroy(client);
                self.connected -= 1;
            }
            self.close_queue.clearRetainingCapacity();

            // Slots came free, so start taking connections again.
            self.armListener();
        }
    };
}
