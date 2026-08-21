//! Linux readiness backend.
//!
//! Mirrors `KQueue.zig` so the event loop cannot tell them apart. See
//! `Poller.zig` for the shared contract and the differences being papered
//! over.

const std = @import("std");
const linux = std.os.linux;
const Client = @import("Client.zig");
const poller = @import("Poller.zig");
const Event = poller.Event;

pub const Epoll = @This();

epfd: i32 = -1,
/// eventfd used by `wake` to break the loop out of `epoll_wait`.
wake_fd: i32 = -1,
raw_events: [128]linux.epoll_event = undefined,
event_list: [128]Event = undefined,

const EpollError = error{
    Unexpected,
    InvalidSocket,
};

fn check(rc: usize) EpollError!void {
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => error.Unexpected,
    };
}

pub fn init() !Epoll {
    const rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    try check(rc);
    return .{ .epfd = @intCast(rc) };
}

pub fn deinit(self: Epoll) void {
    if (self.wake_fd >= 0) _ = linux.close(self.wake_fd);
    if (self.epfd >= 0) _ = linux.close(self.epfd);
}

fn ctl(self: *Epoll, op: u32, fd: i32, events: u32, tag: usize) !void {
    var ev = linux.epoll_event{
        .events = events,
        .data = .{ .ptr = tag },
    };
    try check(linux.epoll_ctl(self.epfd, op, fd, &ev));
}

/// Blocks for events. A negative `timeout_ms` blocks indefinitely, which
/// is what `epoll_wait` already means by -1.
pub fn wait(self: *Epoll, timeout_ms: i32) poller.WaitError![]Event {
    const rc = linux.epoll_wait(
        self.epfd,
        &self.raw_events,
        self.raw_events.len,
        timeout_ms,
    );
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .INTR => return error.Interrupted,
        .AGAIN => return error.WouldBlock,
        else => return error.Unexpected,
    }
    const count: usize = @intCast(rc);

    for (self.raw_events[0..count], 0..) |raw, i| {
        const tag = raw.data.ptr;
        const failed = (raw.events & (linux.EPOLL.ERR | linux.EPOLL.HUP)) != 0;
        self.event_list[i] = switch (tag) {
            poller.tag_listener => .{ .source = .listener },
            poller.tag_wake => blk: {
                // Drain the counter so the eventfd goes quiet again.
                var scratch: u64 = 0;
                _ = linux.read(self.wake_fd, @ptrCast(&scratch), @sizeOf(u64));
                break :blk .{ .source = .wake };
            },
            else => .{
                .source = .client,
                .client_ptr = tag,
                .readable = (raw.events & linux.EPOLL.IN) != 0,
                .writable = (raw.events & linux.EPOLL.OUT) != 0,
                .failed = failed,
            },
        };
    }
    return self.event_list[0..count];
}

// ── listener ───────────────────────────────────────────────────────

/// Level-triggered on purpose: with several workers sharing one listener,
/// every one of them needs to keep being told a connection is waiting
/// until somebody actually takes it.
pub fn addListener(self: *Epoll, listener: i32) !void {
    try self.ctl(linux.EPOLL.CTL_ADD, listener, linux.EPOLL.IN, poller.tag_listener);
}

/// epoll cannot disable a registration in place, so parking means
/// removing it outright. `enableListener` adds it back.
pub fn removeListener(self: *Epoll, listener: i32) !void {
    try check(linux.epoll_ctl(self.epfd, linux.EPOLL.CTL_DEL, listener, null));
}

pub fn enableListener(self: *Epoll, listener: i32) !void {
    self.ctl(linux.EPOLL.CTL_ADD, listener, linux.EPOLL.IN, poller.tag_listener) catch |err| {
        // Already registered is not a failure; the listener is armed
        // either way.
        if (err == error.Unexpected) return;
        return err;
    };
}

// ── clients ────────────────────────────────────────────────────────

/// Edge-triggered, matching the `EV_CLEAR` the kqueue backend uses. The
/// read path already drains until `EAGAIN`, which is what edge triggering
/// requires.
pub fn newClient(self: *Epoll, client: *Client) !void {
    try self.ctl(
        linux.EPOLL.CTL_ADD,
        client.socket,
        linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.RDHUP,
        @intFromPtr(client),
    );
}

pub fn readMode(self: *Epoll, client: *Client) !void {
    if (client.socket < 0) return error.InvalidSocket;
    try self.ctl(
        linux.EPOLL.CTL_MOD,
        client.socket,
        linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.RDHUP,
        @intFromPtr(client),
    );
}

pub fn writeMode(self: *Epoll, client: *Client) !void {
    if (client.socket < 0) return error.InvalidSocket;
    try self.ctl(
        linux.EPOLL.CTL_MOD,
        client.socket,
        linux.EPOLL.OUT | linux.EPOLL.ET | linux.EPOLL.RDHUP,
        @intFromPtr(client),
    );
}

// ── change batching ────────────────────────────────────────────────

/// No-op: `epoll_ctl` applies immediately, so nothing is ever pending
/// against a descriptor that is about to close.
pub fn purgeChanges(self: *Epoll, fd: i32) void {
    _ = self;
    _ = fd;
}

/// No-op, for the same reason as `purgeChanges`.
pub fn flushChanges(self: *Epoll) !void {
    _ = self;
}

// ── wakeup ─────────────────────────────────────────────────────────

pub fn registerWake(self: *Epoll) !void {
    const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    try check(rc);
    self.wake_fd = @intCast(rc);
    try self.ctl(linux.EPOLL.CTL_ADD, self.wake_fd, linux.EPOLL.IN, poller.tag_wake);
}

/// Wake a loop parked in `epoll_wait`, from any thread. Writing to an
/// eventfd is atomic and safe to do concurrently.
pub fn wake(self: *Epoll) void {
    if (self.wake_fd < 0) return;
    const one: u64 = 1;
    _ = linux.write(self.wake_fd, @ptrCast(&one), @sizeOf(u64));
}
