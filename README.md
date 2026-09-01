# Loom

[![CI](https://github.com/tether-labs/Loom/actions/workflows/ci.yml/badge.svg)](https://github.com/tether-labs/Loom/actions/workflows/ci.yml)

A single-threaded, non-blocking event loop for TCP servers, written in Zig.

Loom owns the socket lifecycle: accepting connections, watching them with
`kqueue`, handing received bytes to your handler, draining responses
asynchronously, and dropping connections that stall. It does **not**
interpret those bytes — there is no HTTP parsing, no message framing, no
routing. That belongs in a protocol layer on top;
[Reverb](https://github.com/vic-Rokx/tether) is the HTTP server built on
this.

## Requirements

- Zig 0.16.0
- Linux (`epoll`) or macOS/BSD (`kqueue`). Windows is not supported.

The readiness backend is chosen at compile time and both are exercised by
the same test suite; see `src/engine/Poller.zig` for the contract they
share.

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

## Multiple workers

`Cluster` runs several event loops over one listening socket. Each worker
is a complete `Loom` on its own thread with its own kqueue, client pool,
connection slots and timeout list — nothing mutable is shared.

```zig
const handlers = [_]Handler{ .{}, .{}, .{}, .{} }; // one per worker

var cluster: loom.Cluster(Handler) = undefined;
try cluster.init(.{ .server_port = 8080, .max = 1024 }, allocator, &handlers);
defer cluster.deinit();

try cluster.serve(); // until cluster.stop()
```

The worker count is exactly `handlers.len`, which keeps the sharing
decision visible at the call site: pass distinct handlers for
shared-nothing workers, or the same pointer repeated if that handler is
genuinely safe to use from several threads. `max` is the limit across the
whole server, split evenly, and connection slots stay unique server-wide
so a slot still identifies exactly one live connection.

The allocator is used by every worker concurrently and must be
thread-safe — `std.heap.smp_allocator` is a good default.

**Per-worker counters.** Each worker keeps a `stats` struct — connections
accepted, listener wakeups, wakeups that lost the accept race,
connections refused at capacity, connections timed out. They are plain
integers rather than atomics because a worker is only ever touched by its
own thread, so they cost nothing on the hot path. Read them off
`cluster.workers[i].stats`.

**How connections are distributed.** Every worker registers the shared
listener in its own kqueue and they race to accept. The race balances by
availability: a worker busy inside a handler is not parked in `kevent`
ready to win, so connections drift toward idle workers. That is
load-proportional, and a slow worker naturally stops taking new work.

`SO_REUSEPORT` is deliberately not used to give each worker its own
listener. On Linux the kernel would load-balance across them, but Darwin
and the BSDs deliver every connection to the most recently bound socket —
measured here as all 40 of 40 connections landing on one listener — which
would leave every worker but one idle. Using kernel load balancing on
Linux while keeping the shared listener elsewhere is a worthwhile future
split; today both platforms share one listener.

Scaling on a 10-core M-series machine, with a CPU-bound handler and the
load generator sharing the box:

| workers | req/s | speedup |
| --- | --- | --- |
| 1 | 18,397 | 1.00× |
| 2 | 35,019 | 1.90× |
| 4 | 65,904 | 3.58× |
| 8 | 94,851 | 5.16× |

```
zig build run-cluster
curl -i http://127.0.0.1:8081/
```

## Configuration

| Field | Default | Meaning |
| --- | --- | --- |
| `server_addr` | `"0.0.0.0"` | Interface to bind. |
| `server_port` | `8080` | Port to bind. `0` lets the kernel choose; read it back with `boundPort()`. |
| `max` | `256` | Maximum concurrent connections. The listener parks when full and re-arms as slots free. |
| `max_body_size` | `4 MiB` | Largest payload `write` accepts; bigger ones get `error.ResponseTooLarge`. `0` disables the limit. |
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
  batch is done. See *Shutdown* below.
- `deinit()` — close live connections, the listener, and release everything.

On a `*Client`:

- `write(bytes)` — send, chunking through the writer buffer and finishing
  asynchronously if the kernel won't take it all at once. Copies whatever
  is still outstanding when it returns, so `bytes` may be a stack buffer
  or arena memory reused immediately afterwards.
- `writeBorrowed(bytes)` — the same, without the copy. The caller
  guarantees `bytes` stays valid and unchanged until the send drains,
  which may be several event-loop iterations later. For string literals
  and other genuinely stable memory.
- `fillWriteBuffer(bytes)` — buffer without sending, to coalesce a header
  and body into one syscall.
- `sendFile(file)` — stream a file; ownership transfers to the client.
- `isWriting()` — true while a previous send is still draining.
- `slot` — dense connection index in `0..max`, stable for the
  connection's lifetime and never shared with another live connection.
  Useful as a key for your own per-connection state.

## Shutdown

`stop()` is built to be called from a signal handler: an atomic store and
a single syscall to wake the loop. No allocation, no locks, nothing that
minds being interrupted. `serve()` then returns and `deinit()` closes
whatever is still connected.

```zig
var server: loom.Loom(Handler) = undefined;

fn onShutdownSignal(_: std.posix.SIG) callconv(.c) void {
    server.stop();
}

var action = std.posix.Sigaction{
    .handler = .{ .handler = onShutdownSignal },
    .mask = std.posix.sigemptyset(),
    .flags = 0, // no SA_RESTART, so a blocking wait also returns EINTR
};
std.posix.sigaction(std.posix.SIG.TERM, &action, null);
std.posix.sigaction(std.posix.SIG.INT, &action, null);
```

Loom does not install handlers itself. Signal disposition is
process-global and belongs to the application, not to a library it
happens to link. Both examples wire it up; CI starts each one, serves a
request, sends `SIGTERM` and requires a clean exit.

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

**Write payloads are copied.** Anything still outstanding when `write`
returns belongs to the client, so a handler is free to reuse or discard
its buffers immediately. `writeBorrowed` skips the copy when the payload
outlives the request anyway.

**Timeouts measure progress, not silence.** The idle deadline is refreshed
by every read *and* by every write the kernel accepts, so a slow but
advancing transfer is never dropped while a stalled one is.

## Testing

```
zig build test               # unit + end-to-end
zig build test-unit
zig build test-integration
```

CI runs the whole suite on Linux and macOS, in both `Debug` and
`ReleaseSafe`, plus a cross-compile check across five targets and a smoke
test that starts each example and makes a real request against it.

The end-to-end suite stands up real servers on ephemeral ports and drives
them over real sockets — disconnect storms, saturation, timeout expiry,
slow readers, multi-worker churn. Every regression test in it was proven
to fail: the bug it guards was re-introduced and the test watched to go
red. [TESTING.md](TESTING.md) documents the method, the full injection
matrix, the cases where the *tests themselves* turned out to be lying,
and the coverage gaps that remain.


## Status

Pre-1.0. Known gaps:

- No `io_uring` backend; Linux uses `epoll`.
- Outbound websocket `permessage-deflate` compression is not implemented
  on Zig 0.16 (`flate.Compress.Simple` no longer exists). Inbound
  decompression works, so peers may still compress towards us.
- Only the AArch64 coroutine assembly is present, so the (currently
  unused) `Scheduler` will not build for x86_64 or RISC-V.
- Connection distribution across cluster workers is decided by an accept
  race rather than an explicit scheduler. It balances well once handlers
  do real work, but a server whose handlers return almost instantly will
  see most connections land on one worker.
- Workers share one listener, so several wake on each incoming connection
  and all but one lose the race. Measured at 42% of listener wakeups
  wasted with 8 workers under connection churn — but that is roughly
  1,500 wasted wakeups a second, two cheap syscalls each, so well under
  1% of a core. It is also per *connection*, so keep-alive amortises it
  away almost entirely. `epoll` has `EPOLLEXCLUSIVE` for this; kqueue has
  no equivalent, so the alternative would be an nginx-style rotating
  accept mutex.

## License

MIT
