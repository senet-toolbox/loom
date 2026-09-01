//! Multi-worker Loom server.
//!
//!     zig build run-cluster
//!     curl -i http://127.0.0.1:8081/
//!
//! One listening socket, several independent event loops. Each worker has
//! its own kqueue, client pool, connection slots and timeout list, and
//! they race to accept — so connections land on whichever worker is not
//! already busy.

const std = @import("std");
const posix = std.posix;
const loom = @import("loom");

/// One handler per worker.
///
/// Because each worker gets its own instance, per-worker state needs no
/// synchronisation at all — this counter is a plain `usize`, not an
/// atomic, and that is safe. Sharing state between workers is opt-in:
/// you would pass the same pointer to every worker and take on the
/// thread-safety yourself.
const Handler = struct {
    id: usize,
    served: usize = 0,

    pub fn process(self: *Handler, client: *loom.Client, msg: []const u8) !void {
        _ = msg;
        self.served += 1;
        try client.write(
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Content-Length: 12\r\n" ++
                "\r\n" ++
                "hello, loom\n",
        );
    }
};

/// Reachable from the signal handler, which gets no arguments.
var cluster: loom.Cluster(*Handler) = undefined;

/// `Cluster.stop` signals every worker: one atomic store and one wake
/// syscall each. Safe to do from a signal handler, and safe to do while
/// the workers are mid-batch.
fn onShutdownSignal(_: posix.SIG) callconv(.c) void {
    cluster.stop();
}

/// Loom does not install signal handlers itself — signal disposition is
/// process-global and belongs to the application.
fn handleShutdownSignals() void {
    var action = posix.Sigaction{
        .handler = .{ .handler = onShutdownSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &action, null); // docker stop, systemd
    posix.sigaction(posix.SIG.INT, &action, null); // ctrl-c
}

pub fn main() !void {
    // Workers allocate concurrently, so the allocator has to be
    // thread-safe. `smp_allocator` is built for exactly this.
    const allocator = std.heap.smp_allocator;

    const worker_count = @min(std.Thread.getCpuCount() catch 4, 8);

    const handlers = try allocator.alloc(*Handler, worker_count);
    defer allocator.free(handlers);
    for (handlers, 0..) |*h, i| {
        h.* = try allocator.create(Handler);
        h.*.* = .{ .id = i };
    }
    defer for (handlers) |h| allocator.destroy(h);

    try cluster.init(.{
        .server_addr = "127.0.0.1",
        .server_port = 8081,
        // Shared out evenly between workers; slots stay unique server-wide.
        .max = 1024,
        .idle_timeout_ms = 30_000,
    }, allocator, handlers);
    defer cluster.deinit();

    std.debug.print(
        "listening on http://127.0.0.1:{d} across {d} workers\n",
        .{ cluster.boundPort(), worker_count },
    );

    handleShutdownSignals();

    // Returns once a shutdown signal arrives; `deinit` then joins every
    // worker and closes what is still open.
    try cluster.serve();
    std.debug.print("shut down cleanly\n", .{});
}
