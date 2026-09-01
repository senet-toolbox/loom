//! Minimal Loom server.
//!
//!     zig build run-example
//!     curl -i http://127.0.0.1:8080/
//!
//! Loom is an event loop, not an HTTP server: it hands the handler
//! whatever bytes the last `read` produced, with no framing applied. A
//! single small request arrives in one piece, which is why this example
//! can get away with ignoring `msg` entirely. Anything real needs a
//! protocol layer on top to accumulate bytes until a complete message has
//! arrived (see the note in the README).

const std = @import("std");
const posix = std.posix;
const loom = @import("loom");

const Handler = struct {
    /// Called whenever bytes arrive on a connection.
    ///
    /// Returning an error tells the server to drop the connection.
    pub fn process(_: Handler, client: *loom.Client, msg: []const u8) !void {
        _ = msg;
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
var server: loom.Loom(Handler) = undefined;

/// Runs on whichever thread takes the signal.
///
/// `stop` is built for exactly this: an atomic store followed by one
/// syscall to wake the loop. No allocation, no locks, nothing that cares
/// about being interrupted.
fn onShutdownSignal(_: posix.SIG) callconv(.c) void {
    server.stop();
}

/// Loom deliberately does not install signal handlers itself — signal
/// disposition is process-global and belongs to the application, not to a
/// library it happens to link. Wiring it up is this small.
fn handleShutdownSignals() void {
    var action = posix.Sigaction{
        .handler = .{ .handler = onShutdownSignal },
        .mask = posix.sigemptyset(),
        // No SA_RESTART: letting the blocking wait return EINTR is a
        // second, independent way for the loop to notice it should stop.
        .flags = 0,
    };
    posix.sigaction(posix.SIG.TERM, &action, null); // docker stop, systemd
    posix.sigaction(posix.SIG.INT, &action, null); // ctrl-c
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    try server.new(.{
        .server_addr = "127.0.0.1",
        .server_port = 8080,
        .max = 1024,
        .idle_timeout_ms = 30_000,
    }, allocator, .{});
    defer server.deinit();

    handleShutdownSignals();

    // Bind before serving so the port is known up front. Handy when
    // `server_port` is 0 and the kernel picks one.
    try server.bindListener();
    std.debug.print("listening on http://127.0.0.1:{d}\n", .{try server.boundPort()});

    // Returns once a shutdown signal arrives; `deinit` then closes any
    // connections still open.
    try server.serve();
    std.debug.print("shut down cleanly\n", .{});
}
