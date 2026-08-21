//! Runs several `Loom` event loops over one listening socket.
//!
//! Each worker is a complete `Loom` on its own thread with its own
//! kqueue, client pool, connection slots and timeout list. Nothing
//! mutable is shared between them. The only thing they have in common is
//! the listening socket, which every worker registers in its own kqueue;
//! they then race to accept.
//!
//! That race is the load balancer, and it balances by *availability*: a
//! worker busy serving requests is not sitting in `kevent` ready to win,
//! so connections drift toward whichever workers are idle. Measured
//! across four workers with a shared listener, distribution goes from
//! badly skewed when workers do no work at all, to even once each
//! connection costs a couple of hundred microseconds — which any real
//! handler does.
//!
//! `SO_REUSEPORT` is deliberately *not* used to give each worker its own
//! listener. On Linux that would load-balance in the kernel, but Darwin
//! and the BSDs hand every connection to the most recently bound socket
//! instead, which would leave every worker but one idle.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const system = posix.system;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.loom_cluster);

const Loom = @import("Loom.zig").Loom;

pub fn Cluster(comptime Handler: type) type {
    return struct {
        allocator: Allocator,
        workers: []Loom(Handler),
        threads: []std.Thread,
        started: usize = 0,
        listener: posix.socket_t = -1,
        port: u16 = 0,

        const Self = @This();
        const Worker = Loom(Handler);

        pub const Config = struct {
            server_addr: []const u8 = "0.0.0.0",
            server_port: u16 = 8080,

            /// Maximum concurrent connections across the whole server,
            /// divided evenly between workers. Connection slots stay
            /// unique server-wide, so a slot still identifies exactly one
            /// live connection.
            max: usize = 256,

            max_body_size: usize = 4 * 1024 * 1024,
            initial_read_size: usize = 16 * 1024,
            max_read_size: usize = 2097152,
            idle_timeout_ms: i64 = 60_000,
            backlog: u31 = 4096,
        };

        /// Set up the listener and one worker per handler.
        ///
        /// The number of workers is exactly `handlers.len`, which keeps
        /// the sharing decision in the caller's hands and visible at the
        /// call site: pass distinct handlers for shared-nothing workers,
        /// or the same pointer repeated if that handler is genuinely safe
        /// to use from several threads at once.
        ///
        /// `allocator` is used concurrently by every worker and must be
        /// thread-safe. `std.heap.smp_allocator` and
        /// `std.heap.page_allocator` are; `std.heap.DebugAllocator` is
        /// only with `.thread_safe = true` (its default off
        /// single-threaded builds). An `ArenaAllocator` is not.
        pub fn init(
            target: *Self,
            config: Config,
            allocator: Allocator,
            handlers: []const Handler,
        ) !void {
            if (handlers.len == 0) return error.InvalidConfig;
            if (config.max < handlers.len) return error.InvalidConfig;

            const listener = try openListener(config);
            errdefer closeFd(listener);
            const port = try boundPortOf(listener);

            const workers = try allocator.alloc(Worker, handlers.len);
            errdefer allocator.free(workers);
            const threads = try allocator.alloc(std.Thread, handlers.len);
            errdefer allocator.free(threads);

            // Split the connection budget evenly, handing the remainder to
            // the first workers so the totals add up to exactly `max`.
            const base_share = config.max / handlers.len;
            const remainder = config.max % handlers.len;

            var created: usize = 0;
            errdefer for (workers[0..created]) |*w| w.deinit();

            var slot_base: usize = 0;
            while (created < handlers.len) : (created += 1) {
                const share = base_share + @intFromBool(created < remainder);
                try workers[created].new(.{
                    .server_addr = config.server_addr,
                    .server_port = port,
                    .max = share,
                    .max_body_size = config.max_body_size,
                    .initial_read_size = config.initial_read_size,
                    .max_read_size = config.max_read_size,
                    .idle_timeout_ms = config.idle_timeout_ms,
                    .slot_base = slot_base,
                }, allocator, handlers[created]);
                try workers[created].adoptListener(listener);
                slot_base += share;
            }

            target.* = .{
                .allocator = allocator,
                .workers = workers,
                .threads = threads,
                .listener = listener,
                .port = port,
            };
        }

        /// The port the shared listener bound to. Meaningful immediately
        /// after `init`, including when `server_port` was 0.
        pub fn boundPort(self: *const Self) u16 {
            return self.port;
        }

        /// Spawn every worker thread and return.
        pub fn start(self: *Self) !void {
            errdefer self.stopStarted();
            while (self.started < self.workers.len) {
                self.threads[self.started] = try std.Thread.spawn(
                    .{},
                    runWorker,
                    .{ &self.workers[self.started], self.started },
                );
                self.started += 1;
            }
        }

        fn runWorker(worker: *Worker, index: usize) void {
            worker.serve() catch |err| {
                log.err("worker {d} exited: {any}", .{ index, err });
            };
        }

        /// Ask every worker to finish. Safe from any thread.
        pub fn stop(self: *Self) void {
            for (self.workers) |*w| w.stop();
        }

        /// Wait for every started worker to exit.
        pub fn join(self: *Self) void {
            for (self.threads[0..self.started]) |t| t.join();
            self.started = 0;
        }

        fn stopStarted(self: *Self) void {
            for (self.workers[0..self.started]) |*w| w.stop();
            self.join();
        }

        /// Run until `stop` is called.
        pub fn serve(self: *Self) !void {
            try self.start();
            self.join();
        }

        pub fn deinit(self: *Self) void {
            // Workers must be off their threads before their state is
            // torn down.
            self.stopStarted();
            for (self.workers) |*w| w.deinit();
            // Every worker borrowed the listener, so closing it is ours.
            if (self.listener >= 0) {
                closeFd(self.listener);
                self.listener = -1;
            }
            self.allocator.free(self.workers);
            self.allocator.free(self.threads);
        }

        // ── listener ────────────────────────────────────────────────

        fn closeFd(fd: posix.socket_t) void {
            _ = system.close(fd);
        }

        fn openListener(config: Config) !posix.socket_t {
            const parsed = try std.Io.net.IpAddress.parse(config.server_addr, config.server_port);
            const domain: u32 = switch (parsed) {
                .ip4 => posix.AF.INET,
                .ip6 => posix.AF.INET6,
            };
            if (domain != posix.AF.INET) return error.UnsupportedAddressFamily;

            const sock_type: u32 = if (sock_flags_in_socket)
                posix.SOCK.STREAM | posix.SOCK.NONBLOCK
            else
                posix.SOCK.STREAM;
            const rc = system.socket(domain, sock_type, posix.IPPROTO.TCP);
            if (rc < 0) return error.SocketFailed;
            const fd: posix.socket_t = @intCast(rc);
            errdefer closeFd(fd);
            if (!sock_flags_in_socket) try setNonBlocking(fd);

            const on = std.mem.toBytes(@as(c_int, 1));
            try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &on);

            var addr: posix.sockaddr.in = .{
                .family = posix.AF.INET,
                .port = std.mem.nativeToBig(u16, config.server_port),
                .addr = @bitCast(parsed.ip4.bytes),
                .zero = .{0} ** 8,
            };
            if (system.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) != 0) {
                return error.AddressInUse;
            }
            if (system.listen(fd, config.backlog) != 0) return error.ListenFailed;
            return fd;
        }

        /// Linux accepts `SOCK_NONBLOCK` in `socket` itself; Darwin does
        /// not and needs a follow-up `fcntl`.
        const sock_flags_in_socket = builtin.os.tag == .linux;

        fn setNonBlocking(fd: posix.socket_t) !void {
            const flags = system.fcntl(fd, posix.system.F.GETFL, @as(c_int, 0));
            if (flags < 0) return error.Unexpected;
            const want: c_int = flags | (1 << @bitOffsetOf(posix.system.O, "NONBLOCK"));
            if (system.fcntl(fd, posix.system.F.SETFL, want) < 0) return error.Unexpected;
        }

        fn boundPortOf(fd: posix.socket_t) !u16 {
            var addr: posix.sockaddr.in = undefined;
            var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
            if (system.getsockname(fd, @ptrCast(&addr), &len) != 0) return error.Unexpected;
            return std.mem.bigToNative(u16, addr.port);
        }
    };
}
