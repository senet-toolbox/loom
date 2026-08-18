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

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var server: loom.Loom(Handler) = undefined;
    try server.new(.{
        .server_addr = "127.0.0.1",
        .server_port = 8080,
        .max = 1024,
        .idle_timeout_ms = 30_000,
    }, allocator, .{});
    defer server.deinit();

    // Bind before serving so the port is known up front. Handy when
    // `server_port` is 0 and the kernel picks one.
    try server.bindListener();
    std.debug.print("listening on http://127.0.0.1:{d}\n", .{try server.boundPort()});

    // Runs the event loop; does not return.
    try server.serve();
}
