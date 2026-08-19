//! End-to-end tests for the event loop, driven over real sockets.
//!
//! Every test here pins down a bug that took the server out in practice.
//! The comment above each one names the failure it guards against, so a
//! regression tells you what broke rather than just that something did.

const std = @import("std");
const testing = std.testing;

const loom = @import("loom");
const harness = @import("harness.zig");

const Conn = harness.Conn;

// ── Handlers ───────────────────────────────────────────────────────

/// Replies with a fixed short body.
const EchoHandler = struct {
    pub fn process(_: EchoHandler, client: *loom.Client, _: []const u8) !void {
        try client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
    }
};

/// Replies with a body big enough to overflow the writer buffer, forcing
/// the async `EVFILT.WRITE` path.
const big_body_len = 1024 * 1024;
var big_response_buf: [big_body_len + 128]u8 = undefined;
var big_response: []u8 = &.{};

const BigHandler = struct {
    pub fn process(_: BigHandler, client: *loom.Client, _: []const u8) !void {
        try client.write(big_response);
    }
};

/// Records the connection slot each request arrives on, so tests can
/// assert the slot allocator hands out distinct indices to concurrently
/// live connections and recycles them afterwards.
const SlotHandler = struct {
    const max_slots = 64;
    var seen: [max_slots]std.atomic.Value(u32) = init: {
        var a: [max_slots]std.atomic.Value(u32) = undefined;
        for (&a) |*v| v.* = std.atomic.Value(u32).init(0);
        break :init a;
    };
    var out_of_range = std.atomic.Value(u32).init(0);
    var handled = std.atomic.Value(u32).init(0);

    pub fn process(_: SlotHandler, client: *loom.Client, _: []const u8) !void {
        if (client.slot >= max_slots) {
            _ = out_of_range.fetchAdd(1, .monotonic);
        } else {
            _ = seen[client.slot].fetchAdd(1, .monotonic);
        }
        _ = handled.fetchAdd(1, .monotonic);
        try client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
    }

    fn reset() void {
        for (&seen) |*v| v.store(0, .monotonic);
        out_of_range.store(0, .monotonic);
        handled.store(0, .monotonic);
    }

    fn distinctSlotsUsed() usize {
        var n: usize = 0;
        for (&seen) |*v| {
            if (v.load(.monotonic) > 0) n += 1;
        }
        return n;
    }
};

// ── Basics ─────────────────────────────────────────────────────────

test "serves a single request" {
    const allocator = std.heap.page_allocator;
    var server = try harness.Server(EchoHandler).start(allocator, .{}, .{ .max = 16 });
    defer server.stop();

    const conn = try server.connect();
    defer conn.close();

    try conn.send(harness.get_request);

    var buf: [64]u8 = undefined;
    const n = try conn.recv(&buf);
    try testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 200 OK"));
    try testing.expect(std.mem.endsWith(u8, buf[0..n], "\r\n\r\nok"));
}

test "keep-alive: many requests on one connection" {
    const allocator = std.heap.page_allocator;
    var server = try harness.Server(EchoHandler).start(allocator, .{}, .{ .max = 16 });
    defer server.stop();

    const conn = try server.connect();
    defer conn.close();

    var buf: [64]u8 = undefined;
    for (0..25) |_| {
        try conn.send(harness.get_request);
        const n = try conn.recv(&buf);
        try testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 200 OK"));
    }
}

test "large response drains completely through the async write path" {
    const allocator = std.heap.page_allocator;
    big_response = try harness.buildResponse(&big_response_buf, big_body_len, 'A');

    var server = try harness.Server(BigHandler).start(allocator, .{}, .{ .max = 16 });
    defer server.stop();

    const conn = try server.connect();
    defer conn.close();

    try conn.send(harness.get_request);

    const body = try allocator.alloc(u8, big_response.len);
    defer allocator.free(body);
    try conn.recvExactly(body);

    // The whole response has to arrive byte for byte: a short read or a
    // duplicated chunk means the write pump mishandled the EAGAIN path.
    try testing.expectEqualSlices(u8, big_response, body);
}

test "many concurrent large responses all complete" {
    const allocator = std.heap.page_allocator;
    big_response = try harness.buildResponse(&big_response_buf, big_body_len, 'A');

    var server = try harness.Server(BigHandler).start(allocator, .{}, .{ .max = 64 });
    defer server.stop();

    const conn_count = 30;
    const conns = try server.connectMany(allocator, conn_count);
    defer allocator.free(conns);
    defer for (conns) |c| c.close();

    for (conns) |c| try c.send(harness.get_request);

    for (conns) |c| try c.drainExactly(big_response.len);
}

// ── Regressions ────────────────────────────────────────────────────


/// Assert the server is still alive and serving.
///
/// Retries, because these stress tests leave the server working through
/// a backlog: a single refused or slow attempt right after the storm
/// means saturated, not dead. Only a server that never comes back fails.
fn expectHealthy(server: harness.Server(BigHandler)) !void {
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        const conn = server.connect() catch {
            harness.sleepMs(50);
            continue;
        };
        defer conn.close();
        conn.send(harness.get_request) catch {
            harness.sleepMs(50);
            continue;
        };
        conn.drainExactly(big_response.len) catch {
            harness.sleepMs(50);
            continue;
        };
        return;
    }
    return error.ServerNeverRecovered;
}

/// Ask `count` clients for a response far too big to fit in the socket
/// buffer, then disconnect them all while the server is still pushing it
/// out. `reset` picks RST (`SO_LINGER 0`) over an ordinary FIN.
///
/// The two disconnect styles fail the server's in-flight write
/// differently, and each one caught a different bug — so they get
/// separate tests rather than being mixed into one.
fn disconnectMidResponse(
    server: harness.Server(BigHandler),
    allocator: std.mem.Allocator,
    rounds: usize,
    count: usize,
    reset: bool,
    settle_ms: u64,
) !void {
    for (0..rounds) |_| {
        const conns = try server.connectMany(allocator, count);
        defer allocator.free(conns);

        // The client side is deliberately abusive — hundreds of connects
        // and resets a second against loopback — so the kernel sometimes
        // refuses one. That is the test hitting a local limit, not the
        // server failing, so a connection that won't take a request is
        // simply dropped. What is being asserted is that the server
        // survives the storm, which the check after the loop covers.
        for (conns) |c| {
            const sent = if (c.send(harness.get_request)) true else |_| false;
            // With no settle time the disconnect happens inline, so the
            // server's first write lands on an already-closed socket.
            if (settle_ms == 0 and sent) {
                if (reset) c.abort() else c.close();
            } else if (settle_ms == 0) {
                c.close();
            }
        }
        if (settle_ms != 0) {
            harness.sleepMs(settle_ms);
            for (conns) |c| if (reset) c.abort() else c.close();
        }
    }

    // The server has to still be there, and still working.
    try expectHealthy(server);
}

// `closeClient` used to free the client straight back into the pool while
// later events in the same `kevent` batch still pointed at it, so the
// loop read through a dangling pointer and closed an already-closed
// descriptor (panic: `BADF`, "use after free"). A reset makes the server
// notice the dead connection while it is mid-write, which is what lines
// up a second event for a client the batch has already torn down.
test "regression: connection resets mid-response do not kill the server" {
    const allocator = std.heap.page_allocator;
    big_response = try harness.buildResponse(&big_response_buf, big_body_len, 'A');

    var server = try harness.Server(BigHandler).start(allocator, .{}, .{ .max = 256 });
    defer server.stop();

    try disconnectMidResponse(server, allocator, 6, 40, true, 0);
}

// Same teardown path, reached the other way: an ordinary FIN lets one
// write through and fails the next, so the server discovers the dead
// connection at a different point in the write pump than a reset does.
// Deliberately oversubscribed, which also keeps the listener parking and
// re-arming under churn.
test "regression: graceful closes mid-response do not kill the server" {
    const allocator = std.heap.page_allocator;
    big_response = try harness.buildResponse(&big_response_buf, big_body_len, 'A');

    // Deliberately oversubscribed: 60 clients a round against 64 slots
    // keeps the server saturated and the listen backlog full, which is
    // what lines the writes up behind the peer's FIN.
    var server = try harness.Server(BigHandler).start(allocator, .{}, .{ .max = 64 });
    defer server.stop();

    try disconnectMidResponse(server, allocator, 10, 60, false, 0);
}

// Writing to a socket whose peer has gone raises SIGPIPE on Darwin/BSD,
// and the default disposition of SIGPIPE is to kill the process — a
// single client hanging up mid-response took the whole server down
// (exit 141). The fix is `SO_NOSIGPIPE` on every accepted socket.
//
// This asserts the option directly rather than trying to race a
// disconnect into the exact window between two writes. That race is real
// (it is how the bug was found) but reproducing it on demand depends on
// scheduling the test cannot control, so the assertion is on the
// invariant instead: every socket the server accepts has SIGPIPE
// suppressed, therefore no write on one can signal the process.
const NoSigPipeHandler = struct {
    var checked = std.atomic.Value(u32).init(0);
    var suppressed = std.atomic.Value(u32).init(0);

    pub fn process(_: NoSigPipeHandler, client: *loom.Client, _: []const u8) !void {
        var value: c_int = 0;
        var len: std.posix.socklen_t = @sizeOf(c_int);
        const rc = std.posix.system.getsockopt(
            client.socket,
            std.posix.SOL.SOCKET,
            std.c.SO.NOSIGPIPE,
            &value,
            &len,
        );
        _ = checked.fetchAdd(1, .monotonic);
        if (rc == 0 and value != 0) _ = suppressed.fetchAdd(1, .monotonic);

        try client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
    }
};

test "regression: accepted sockets have SIGPIPE suppressed" {
    if (!@hasDecl(std.c.SO, "NOSIGPIPE")) return error.SkipZigTest;

    const allocator = std.heap.page_allocator;
    NoSigPipeHandler.checked.store(0, .monotonic);
    NoSigPipeHandler.suppressed.store(0, .monotonic);

    var server = try harness.Server(NoSigPipeHandler).start(allocator, .{}, .{ .max = 16 });
    defer server.stop();

    const rounds = 8;
    var buf: [64]u8 = undefined;
    for (0..rounds) |_| {
        const conn = try server.connect();
        defer conn.close();
        try conn.send(harness.get_request);
        _ = try conn.recv(&buf);
    }

    try testing.expectEqual(@as(u32, rounds), NoSigPipeHandler.checked.load(.monotonic));
    try testing.expectEqual(@as(u32, rounds), NoSigPipeHandler.suppressed.load(.monotonic));
}

// Hitting `max` parked the listener and nothing ever re-armed it, so the
// server stopped accepting for the rest of its life even after every
// connection had closed.
test "regression: server accepts again after connections free up" {
    const allocator = std.heap.page_allocator;
    const max = 4;

    var server = try harness.Server(EchoHandler).start(allocator, .{}, .{ .max = max });
    defer server.stop();

    // Saturate: `max` connections that have each completed a request, so
    // we know the server really has them.
    const conns = try server.connectMany(allocator, max);
    defer allocator.free(conns);

    var buf: [64]u8 = undefined;
    for (conns) |c| {
        try c.send(harness.get_request);
        _ = try c.recv(&buf);
    }

    // Release everything, then confirm the listener came back.
    for (conns) |c| c.close();

    // The re-arm happens when the loop drains its close queue, which
    // needs the closes to be noticed first.
    var attempt: usize = 0;
    while (attempt < 50) : (attempt += 1) {
        const probe = server.connect() catch {
            harness.sleepMs(20);
            continue;
        };
        defer probe.close();
        probe.send(harness.get_request) catch {
            harness.sleepMs(20);
            continue;
        };
        const n = probe.recv(&buf) catch {
            harness.sleepMs(20);
            continue;
        };
        try testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 200 OK"));
        return;
    }
    return error.ServerNeverRecovered;
}

// With no slots left, `acceptConn` returned normally instead of
// erroring, so the accept loop spun forever: the event loop never got
// back to its already-connected clients and they starved.
test "regression: saturation does not starve established connections" {
    const allocator = std.heap.page_allocator;
    const max = 4;

    var server = try harness.Server(EchoHandler).start(allocator, .{}, .{ .max = max });
    defer server.stop();

    const conns = try server.connectMany(allocator, max);
    defer allocator.free(conns);
    defer for (conns) |c| c.close();

    var buf: [64]u8 = undefined;
    for (conns) |c| {
        try c.send(harness.get_request);
        _ = try c.recv(&buf);
    }

    // Pile up connections the server has no room for. These sit in the
    // accept backlog; the listener should be parked, not spun on.
    var overflow: [16]Conn = undefined;
    var opened: usize = 0;
    while (opened < overflow.len) : (opened += 1) {
        overflow[opened] = server.connect() catch break;
    }
    defer for (overflow[0..opened]) |c| c.close();

    harness.sleepMs(100);

    // The established connections must still be served promptly. Under
    // the spin bug these time out.
    for (conns) |c| {
        try c.send(harness.get_request);
        const n = try c.recv(&buf);
        try testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 200 OK"));
    }
}

// The double-free in the old close path pushed the same slot index onto
// the free list twice, so two live connections could be handed the same
// index — and downstream layers key their per-connection state off it.
test "regression: live connections never share a slot index" {
    const allocator = std.heap.page_allocator;
    const max = 8;
    SlotHandler.reset();

    var server = try harness.Server(SlotHandler).start(allocator, .{}, .{ .max = max });
    defer server.stop();

    const conns = try server.connectMany(allocator, max);
    defer allocator.free(conns);
    defer for (conns) |c| c.close();
    try testing.expectEqual(@as(usize, max), conns.len);

    var buf: [64]u8 = undefined;
    for (conns) |c| {
        try c.send(harness.get_request);
        _ = try c.recv(&buf);
    }

    try testing.expectEqual(@as(u32, 0), SlotHandler.out_of_range.load(.monotonic));
    // `max` connections live at once means `max` distinct slots. Any
    // aliasing shows up as a smaller count.
    try testing.expectEqual(@as(usize, max), SlotHandler.distinctSlotsUsed());
}

test "regression: slots are recycled across connection churn" {
    const allocator = std.heap.page_allocator;
    const max = 4;
    SlotHandler.reset();

    var server = try harness.Server(SlotHandler).start(allocator, .{}, .{ .max = max });
    defer server.stop();

    // Far more connections than slots, in sequence. If closed slots
    // weren't returned, this would wedge partway through.
    const rounds = 40;
    var buf: [64]u8 = undefined;
    for (0..rounds) |_| {
        const conn = try server.connect();
        defer conn.close();
        try conn.send(harness.get_request);
        const n = try conn.recv(&buf);
        try testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 200 OK"));
    }

    try testing.expectEqual(@as(u32, 0), SlotHandler.out_of_range.load(.monotonic));
    try testing.expectEqual(@as(u32, rounds), SlotHandler.handled.load(.monotonic));
    try testing.expect(SlotHandler.distinctSlotsUsed() <= max);
}

// `deinit` freed a `stack` field that was never assigned, so tearing a
// server down crashed.
test "regression: new/deinit round-trips cleanly and leaks nothing" {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    const allocator = debug_allocator.allocator();

    for (0..25) |_| {
        var instance: loom.Loom(EchoHandler) = undefined;
        try instance.new(.{ .max = 32, .server_port = 0 }, allocator, .{});
        instance.deinit();
    }

    try testing.expectEqual(std.heap.Check.ok, debug_allocator.deinit());
}

test "regression: bind/deinit without serving releases the listener" {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    const allocator = debug_allocator.allocator();

    for (0..25) |_| {
        var instance: loom.Loom(EchoHandler) = undefined;
        try instance.new(.{ .max = 8, .server_addr = "127.0.0.1", .server_port = 0 }, allocator, .{});
        try instance.bindListener();
        // An ephemeral port means a real one was assigned.
        try testing.expect(try instance.boundPort() != 0);
        instance.deinit();
    }

    try testing.expectEqual(std.heap.Check.ok, debug_allocator.deinit());
}

// Every accepted connection allocates a read-timeout node, and the close
// path used to drop it on the floor. A start/stop leak check can't see
// that — the pool just keeps handing out fresh nodes — so this watches
// outstanding bytes across churn instead. Steady-state memory has to be
// flat: warm the pools up, then run ten times the traffic and require
// the footprint not to move.
test "regression: connection churn does not grow the allocation footprint" {
    var counting = harness.CountingAllocator.init(std.heap.page_allocator);
    const allocator = counting.allocator();

    var server = try harness.Server(EchoHandler).start(allocator, .{}, .{ .max = 8 });
    defer server.stop();

    var buf: [64]u8 = undefined;
    const cycle = struct {
        fn run(srv: harness.Server(EchoHandler), scratch: []u8, n: usize) !void {
            for (0..n) |_| {
                const conn = try srv.connect();
                defer conn.close();
                try conn.send(harness.get_request);
                _ = try conn.recv(scratch);
            }
        }
    };

    // Warm up. The pools grow to whatever high-water mark of concurrent
    // clients they see, so saturate first — otherwise a later burst of
    // overlap grows them and reads as a leak. Then churn sequentially so
    // every pooled object has been recycled at least once.
    {
        const conns = try server.connectMany(allocator, 8);
        defer allocator.free(conns);
        for (conns) |c| try c.send(harness.get_request);
        for (conns) |c| _ = try c.recv(&buf);
        for (conns) |c| c.close();
    }
    try cycle.run(server, &buf, 30);
    harness.sleepMs(100);
    const baseline = counting.outstanding();

    try cycle.run(server, &buf, 300);
    harness.sleepMs(100);
    const after = counting.outstanding();

    // Pools round up, so allow a little slack -- but a per-connection
    // leak over 300 connections is far larger than this.
    try testing.expect(after <= baseline + 4096);
}

// ── Idle timeout ───────────────────────────────────────────────────

// A connection that opens and then says nothing used to hold its slot
// forever: the timeout list was built on accept but never linked, and the
// loop blocked in `kevent` indefinitely. `max` such connections wedged
// the server permanently — slowloris with no effort required.
test "idle connections are dropped once the deadline passes" {
    const allocator = std.heap.page_allocator;

    var server = try harness.Server(EchoHandler).start(allocator, .{}, .{
        .max = 16,
        .idle_timeout_ms = 200,
    });
    defer server.stop();

    const conn = try server.connect();
    defer conn.close();

    // Never send anything. The server should hang up on its own.
    try testing.expect(try conn.waitForClose(2_000));
}

// The mirror of the above: a connection that keeps talking must never be
// dropped, however long it lives. A timeout that fires on active
// connections is worse than no timeout at all.
test "active connections are never dropped by the timeout" {
    const allocator = std.heap.page_allocator;

    const timeout_ms = 200;
    var server = try harness.Server(EchoHandler).start(allocator, .{}, .{
        .max = 16,
        .idle_timeout_ms = timeout_ms,
    });
    defer server.stop();

    const conn = try server.connect();
    defer conn.close();

    // Stay alive across several timeout windows by making a request in
    // each one.
    var buf: [64]u8 = undefined;
    for (0..6) |_| {
        try conn.send(harness.get_request);
        const n = try conn.recv(&buf);
        try testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 200 OK"));
        harness.sleepMs(timeout_ms / 2);
    }

    // Still up after ~3x the timeout of continuous use.
    try conn.send(harness.get_request);
    const n = try conn.recv(&buf);
    try testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 200 OK"));
}

// Timing out has to actually release the connection slot, or the fix
// trades a permanent wedge for a slower one.
test "timed-out connections return their slot" {
    const allocator = std.heap.page_allocator;
    const max = 4;

    var server = try harness.Server(EchoHandler).start(allocator, .{}, .{
        .max = max,
        .idle_timeout_ms = 200,
    });
    defer server.stop();

    // Fill every slot with connections that will never speak.
    {
        const idle = try server.connectMany(allocator, max);
        defer allocator.free(idle);
        defer for (idle) |c| c.close();

        for (idle) |c| try testing.expect(try c.waitForClose(2_000));
    }

    // With the squatters evicted, the server has to take work again.
    const conn = try server.connect();
    defer conn.close();
    try conn.send(harness.get_request);

    var buf: [64]u8 = undefined;
    const n = try conn.recv(&buf);
    try testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 200 OK"));
}

// A reader that requests a large response and then stops reading stalls
// the server's write pump. No bytes move in either direction, so the
// deadline has to catch it — otherwise "never read the response" is a
// slot leak that a read-only timeout would miss.
test "stalled readers are dropped by the timeout" {
    const allocator = std.heap.page_allocator;
    big_response = try harness.buildResponse(&big_response_buf, big_body_len, 'A');

    var server = try harness.Server(BigHandler).start(allocator, .{}, .{
        .max = 8,
        .idle_timeout_ms = 300,
    });
    defer server.stop();

    const conn = try server.connect();
    defer conn.close();

    try conn.send(harness.get_request);
    // Read just enough to get the transfer going, then stop. The socket
    // buffers fill, the server parks on EVFILT.WRITE, and nothing
    // progresses from there.
    var buf: [1024]u8 = undefined;
    _ = try conn.recv(&buf);

    try testing.expect(try conn.waitForClose(5_000));
}

// Setting the timeout to zero has to mean "off", not "expire
// immediately" -- an off-by-one here silently drops every connection.
test "a zero timeout disables expiry" {
    const allocator = std.heap.page_allocator;

    var server = try harness.Server(EchoHandler).start(allocator, .{}, .{
        .max = 16,
        .idle_timeout_ms = 0,
    });
    defer server.stop();

    const conn = try server.connect();
    defer conn.close();

    // Sit idle well past any plausible default, then confirm it still works.
    try testing.expect(!try conn.waitForClose(700));

    try conn.send(harness.get_request);
    var buf: [64]u8 = undefined;
    const n = try conn.recv(&buf);
    try testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 200 OK"));
}

// The loop derives its `kevent` timeout from the earliest deadline, so a
// mistake there (a zero timeout, or a deadline that never advances) turns
// the wait into a spin. This drives churn through the timeout path and
// checks the list stays consistent — a corrupted list shows up as a wedge
// or a crash rather than a wrong number.
test "timeout bookkeeping survives churn" {
    const allocator = std.heap.page_allocator;
    const max = 8;

    var server = try harness.Server(EchoHandler).start(allocator, .{}, .{
        .max = max,
        .idle_timeout_ms = 150,
    });
    defer server.stop();

    var buf: [64]u8 = undefined;

    // Alternate between connections that are served and closed normally,
    // and connections left to expire, so the list is being appended to,
    // moved within, and removed from at the same time.
    for (0..6) |_| {
        const idle = try server.connectMany(allocator, 2);
        defer allocator.free(idle);
        defer for (idle) |c| c.close();

        for (0..4) |_| {
            const conn = try server.connect();
            defer conn.close();
            try conn.send(harness.get_request);
            const n = try conn.recv(&buf);
            try testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 200 OK"));
        }

        for (idle) |c| try testing.expect(try c.waitForClose(2_000));
    }

    const conn = try server.connect();
    defer conn.close();
    try conn.send(harness.get_request);
    const n = try conn.recv(&buf);
    try testing.expect(std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 200 OK"));
}

// ── Shutdown ───────────────────────────────────────────────────────

// `serve()` used to run until it failed, with no way to ask it to stop.
// That made a clean teardown impossible: callers could not release the
// server's memory or its listener without killing the process.
test "stop makes serve return" {
    const allocator = std.heap.page_allocator;

    const instance = try allocator.create(loom.Loom(EchoHandler));
    defer allocator.destroy(instance);
    try instance.new(.{ .max = 8, .server_addr = "127.0.0.1", .server_port = 0 }, allocator, .{});
    defer instance.deinit();
    try instance.bindListener();

    const Runner = struct {
        fn run(srv: *loom.Loom(EchoHandler), done: *std.atomic.Value(bool)) void {
            srv.serve() catch {};
            done.store(true, .release);
        }
    };
    var done = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, Runner.run, .{ instance, &done });

    // Confirm it is genuinely serving before asking it to stop.
    {
        const conn = try harness.Conn.open(try instance.boundPort());
        defer conn.close();
        try conn.send(harness.get_request);
        var buf: [64]u8 = undefined;
        _ = try conn.recv(&buf);
    }

    instance.stop();
    try harness.joinWithin(thread, &done, 5_000);
}

// The loop parks in `kevent` with no deadline when nothing is pending, so
// stopping has to actively wake it. Without the wake it would sit there
// until some unrelated event happened to arrive.
test "stop wakes a loop parked with no work" {
    const allocator = std.heap.page_allocator;

    const instance = try allocator.create(loom.Loom(EchoHandler));
    defer allocator.destroy(instance);
    // Timeouts off, no connections: nothing will wake this loop on its own.
    try instance.new(.{
        .max = 8,
        .server_addr = "127.0.0.1",
        .server_port = 0,
        .idle_timeout_ms = 0,
    }, allocator, .{});
    defer instance.deinit();
    try instance.bindListener();

    const Runner = struct {
        fn run(srv: *loom.Loom(EchoHandler), done: *std.atomic.Value(bool)) void {
            srv.serve() catch {};
            done.store(true, .release);
        }
    };
    var done = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, Runner.run, .{ instance, &done });

    harness.sleepMs(100); // let it reach the blocking wait
    instance.stop();
    try harness.joinWithin(thread, &done, 5_000);
}

// Shutting down with connections still open has to release them too --
// otherwise a stopped server still holds its descriptors.
test "stop tears down live connections" {
    const allocator = std.heap.page_allocator;
    const max = 8;

    var server = try harness.Server(EchoHandler).start(allocator, .{}, .{ .max = max });

    const conns = try server.connectMany(allocator, max);
    defer allocator.free(conns);
    defer for (conns) |c| c.close();

    var buf: [64]u8 = undefined;
    for (conns) |c| {
        try c.send(harness.get_request);
        _ = try c.recv(&buf);
    }

    // Joins the loop and runs deinit; must not hang or crash with every
    // slot still occupied.
    server.stop();

    // The server is gone, so its peers see the connections end.
    for (conns) |c| try testing.expect(try c.waitForClose(2_000));
}

// With a real shutdown path, the whole server lifecycle can be leak
// checked -- not just `new`/`deinit`, but accepting, serving, timing
// connections out and tearing down under load.
test "a full server lifecycle under load leaks nothing" {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    const allocator = debug_allocator.allocator();

    {
        var server = try harness.Server(EchoHandler).start(allocator, .{}, .{
            .max = 8,
            .idle_timeout_ms = 150,
        });
        defer server.stop();

        var buf: [64]u8 = undefined;

        // Served-and-closed connections.
        for (0..40) |_| {
            const conn = try server.connect();
            defer conn.close();
            try conn.send(harness.get_request);
            _ = try conn.recv(&buf);
        }

        // Connections left to expire.
        const idle = try server.connectMany(allocator, 4);
        defer allocator.free(idle);
        defer for (idle) |c| c.close();
        for (idle) |c| try testing.expect(try c.waitForClose(2_000));

        // And some still open at shutdown.
        const live = try server.connectMany(allocator, 4);
        defer allocator.free(live);
        defer for (live) |c| c.close();
        for (live) |c| try c.send(harness.get_request);
        for (live) |c| _ = try c.recv(&buf);
    }

    try testing.expectEqual(std.heap.Check.ok, debug_allocator.deinit());
}

// ── Per-connection read buffers ────────────────────────────────────

/// Holds on to the first connection's `msg` slice and re-checks it every
/// time a later connection is served.
///
/// Every connection used to read into one process-global buffer, so a
/// slice handed to the handler stayed valid only until the next read on
/// *any* connection — one client's request could be overwritten by
/// another's mid-flight. With per-connection buffers the slice is only
/// disturbed by the connection that owns it.
const IsolationHandler = struct {
    var held: ?[]const u8 = null;
    var expected: [256]u8 = undefined;
    var expected_len: usize = 0;
    var checks = std.atomic.Value(u32).init(0);
    var corrupted = std.atomic.Value(u32).init(0);

    pub fn process(_: IsolationHandler, client: *loom.Client, msg: []const u8) !void {
        if (held) |slice| {
            // A later connection. The first one's bytes must be untouched.
            _ = checks.fetchAdd(1, .monotonic);
            if (!std.mem.eql(u8, slice, expected[0..expected_len])) {
                _ = corrupted.fetchAdd(1, .monotonic);
            }
        } else if (msg.len <= expected.len) {
            // The first connection. Remember both the slice and a private
            // copy of what it should say.
            @memcpy(expected[0..msg.len], msg);
            expected_len = msg.len;
            held = msg;
        }
        try client.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
    }

    fn reset() void {
        held = null;
        expected_len = 0;
        checks.store(0, .monotonic);
        corrupted.store(0, .monotonic);
    }
};

test "regression: one connection's data is not disturbed by another's" {
    const allocator = std.heap.page_allocator;
    IsolationHandler.reset();

    var server = try harness.Server(IsolationHandler).start(allocator, .{}, .{ .max = 16 });
    defer server.stop();

    // The first connection stays open for the whole test, so the slice
    // the handler is holding stays owned by a live client.
    const first = try server.connect();
    defer first.close();

    var buf: [64]u8 = undefined;
    try first.send("GET /aaaaaaaaaaaaaaaa HTTP/1.1\r\nHost: first\r\n\r\n");
    _ = try first.recv(&buf);

    // Now drive traffic through other connections, each sending a
    // different payload of a similar size. Under a shared buffer these
    // land on top of the bytes the handler is still holding.
    for (0..20) |_| {
        const other = try server.connect();
        defer other.close();
        try other.send("GET /bbbbbbbbbbbbbbbb HTTP/1.1\r\nHost: other\r\n\r\n");
        _ = try other.recv(&buf);
    }

    try testing.expect(IsolationHandler.checks.load(.monotonic) >= 20);
    try testing.expectEqual(@as(u32, 0), IsolationHandler.corrupted.load(.monotonic));
}

/// Records the largest single `msg` it is handed.
const GrowthHandler = struct {
    var largest = std.atomic.Value(usize).init(0);
    var total = std.atomic.Value(usize).init(0);

    pub fn process(_: GrowthHandler, _: *loom.Client, msg: []const u8) !void {
        _ = total.fetchAdd(msg.len, .monotonic);
        var seen = largest.load(.monotonic);
        while (msg.len > seen) {
            seen = largest.cmpxchgWeak(seen, msg.len, .monotonic, .monotonic) orelse break;
        }
    }

    fn reset() void {
        largest.store(0, .monotonic);
        total.store(0, .monotonic);
    }
};

test "read buffers grow for connections that need them" {
    const allocator = std.heap.page_allocator;
    GrowthHandler.reset();

    const initial = 1024;
    var server = try harness.Server(GrowthHandler).start(allocator, .{}, .{
        .max = 8,
        .initial_read_size = initial,
        .max_read_size = 64 * 1024,
    });
    defer server.stop();

    const conn = try server.connect();
    defer conn.close();

    // Push far more than the initial buffer holds, in one continuous
    // stream, so reads come back full and the buffer is asked to grow.
    const payload = try allocator.alloc(u8, 512 * 1024);
    defer allocator.free(payload);
    @memset(payload, 'x');
    try conn.send(payload);

    // Wait until everything has been consumed.
    var waited: usize = 0;
    while (GrowthHandler.total.load(.monotonic) < payload.len and waited < 200) : (waited += 1) {
        harness.sleepMs(10);
    }

    try testing.expectEqual(payload.len, GrowthHandler.total.load(.monotonic));
    // A buffer that never grew could not have delivered more than
    // `initial` bytes in a single call.
    try testing.expect(GrowthHandler.largest.load(.monotonic) > initial);
}

test "read buffers stay within the configured ceiling" {
    const allocator = std.heap.page_allocator;
    GrowthHandler.reset();

    const cap = 8 * 1024;
    var server = try harness.Server(GrowthHandler).start(allocator, .{}, .{
        .max = 8,
        .initial_read_size = 1024,
        .max_read_size = cap,
    });
    defer server.stop();

    const conn = try server.connect();
    defer conn.close();

    const payload = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(payload);
    @memset(payload, 'y');
    try conn.send(payload);

    var waited: usize = 0;
    while (GrowthHandler.total.load(.monotonic) < payload.len and waited < 200) : (waited += 1) {
        harness.sleepMs(10);
    }

    try testing.expectEqual(payload.len, GrowthHandler.total.load(.monotonic));
    try testing.expect(GrowthHandler.largest.load(.monotonic) <= cap);
}

// Per-connection buffers only pay off if they are sized on demand. If a
// server allocated `max` * `max_read_size` up front, the defaults would
// cost half a gigabyte before serving a single request.
test "a fresh server does not preallocate the worst-case read memory" {
    var counting = harness.CountingAllocator.init(std.heap.page_allocator);
    const allocator = counting.allocator();

    var instance: loom.Loom(EchoHandler) = undefined;
    try instance.new(.{
        .max = 256,
        .server_addr = "127.0.0.1",
        .server_port = 0,
        .max_read_size = 2 * 1024 * 1024,
    }, allocator, .{});
    defer instance.deinit();

    // max * max_read_size would be 512 MiB; a few MiB of bookkeeping is fine.
    try testing.expect(counting.outstanding() < 8 * 1024 * 1024);
}

test "rejects a read-buffer ceiling below the starting size" {
    const allocator = std.heap.page_allocator;

    var instance: loom.Loom(EchoHandler) = undefined;
    try testing.expectError(error.InvalidConfig, instance.new(.{
        .initial_read_size = 64 * 1024,
        .max_read_size = 1024,
    }, allocator, .{}));

    try testing.expectError(error.InvalidConfig, instance.new(.{
        .initial_read_size = 0,
    }, allocator, .{}));
}
