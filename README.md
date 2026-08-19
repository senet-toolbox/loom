# Loom

A single-threaded, non-blocking event loop for TCP servers, written in Zig.

Loom owns the socket lifecycle: accepting connections, watching them with
`kqueue`, handing received bytes to your handler, draining responses
asynchronously, and dropping connections that stall. It does **not**
interpret those bytes — there is no HTTP parsing, no message framing, no
routing. That belongs in a protocol layer on top;
[Reverb](https://github.com/vic-Rokx/reverb) is the HTTP server built on
this.

## Requirements

- Zig 0.16.0
- macOS or BSD. Loom is `kqueue`-only — there is no `epoll`, `io_uring`,
  or Windows backend yet.

## Usage

```zig
const std = @import("std");
const loom = @import("loom");

const Handler = struct {
    pub fn process(_: Handler, client: *loom.Client, msg: []const u8) !void {
        _ = msg;
        try client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();

    var server: loom.Loom(Handler) = undefined;
    try server.new(.{ .server_port = 8080 }, allocator, .{});
    defer server.deinit();

    try server.serve();
}
```

A handler is any type with a `process` method. Returning an error from it
drops the connection.

Run the bundled example:

```
zig build run-example
curl -i http://127.0.0.1:8080/
```

## Configuration

| Field | Default | Meaning |
| --- | --- | --- |
| `server_addr` | `"0.0.0.0"` | Interface to bind. |
| `server_port` | `8080` | Port to bind. `0` lets the kernel choose; read it back with `boundPort()`. |
| `max` | `256` | Maximum concurrent connections. The listener parks when full and re-arms as slots free. |
| `max_body_size` | `4 MiB` | Largest response body accepted by `write`. |
| `initial_read_size` | `16 KiB` | Size of a connection's read buffer at accept. |
| `max_read_size` | `2 MiB` | Ceiling a connection's read buffer may grow to. |
| `idle_timeout_ms` | `60_000` | Drop connections that make no progress for this long. `0` disables. |

## API

- `new(config, allocator, handler)` — initialise in place.
- `bindListener()` — bind and arm the listener without serving, so the
  port is known before the loop starts.
- `boundPort()` — the port actually bound.
- `serve()` — run the event loop until `stop()` is called.
- `listen()` — `bindListener` then `serve`.
- `stop()` — ask the loop to finish. Safe from another thread or a signal
  handler while the loop is parked; `serve()` returns once the in-flight
  batch is done.
- `deinit()` — close live connections, the listener, and release everything.

On a `*Client`:

- `write(bytes)` — send, chunking through the writer buffer and finishing
  asynchronously if the kernel won't take it all at once.
- `fillWriteBuffer(bytes)` — buffer without sending, to coalesce a header
  and body into one syscall.
- `sendFile(file)` — stream a file; ownership transfers to the client.
- `isWriting()` — true while a previous send is still draining.
- `slot` — dense connection index in `0..max`, stable for the
  connection's lifetime and never shared with another live connection.
  Useful as a key for your own per-connection state.

## Behaviour worth knowing

**No framing.** `process` receives exactly what one `read` returned. A
request split across packets arrives as two calls; two pipelined requests
in one packet arrive as one. Accumulating bytes until a complete message
has arrived is the caller's job.

**Read buffers are per-connection.** The slice handed to `process` stays
valid until the next read *on that connection*; nothing another
connection does can disturb it. Each buffer starts at
`initial_read_size` and doubles up to `max_read_size` when a read comes
back full, so only connections that actually send a lot pay for a large
buffer.

**Write payloads are borrowed.** A payload too large for the 64 KiB writer
buffer is held as a slice until it drains. Keep the backing memory alive
until the next read event on that connection.

**Timeouts measure progress, not silence.** The idle deadline is refreshed
by every read *and* by every write the kernel accepts, so a slow but
advancing transfer is never dropped while a stalled one is.

## Testing

```
zig build test               # unit + end-to-end
zig build test-unit
zig build test-integration
```

The end-to-end suite stands up real servers on ephemeral ports and drives
them over real sockets, including disconnect storms, saturation, and
timeout expiry. Every regression test in it was verified by
re-introducing the bug it guards.

## Status

Pre-1.0. Known gaps:

- `kqueue` only; no `epoll`, `io_uring`, or Windows.
- Only the AArch64 coroutine assembly is present, so the (currently
  unused) `Scheduler` will not build for x86_64 or RISC-V.
- Single-threaded. `SO_REUSEPORT` is set on the listener, so running one
  instance per thread or process is the intended way to scale for now,
  but Loom does not do that for you.

## License

MIT
