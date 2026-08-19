const std = @import("std");
const Client = @import("Client.zig");
const system = std.posix.system;

pub const KQueue = @This();
kfd: c_int = undefined,
event_list: [128]system.Kevent = undefined,
change_list: [32]system.Kevent = undefined,
change_count: usize = 0,

// ── Abstraction layer ──────────────────────────────────────────────

const KQueueError = error{
    WouldBlock,
    Interrupted,
    InvalidSocket,
    Unexpected,
};

/// Wraps the raw kevent syscall, converting c_int returns to Zig errors.
fn rawKevent(
    kq: c_int,
    changelist: []const system.Kevent,
    eventlist: []system.Kevent,
    timeout: ?*const std.posix.timespec,
) KQueueError!usize {
    const rc = system.kevent(
        kq,
        changelist.ptr,
        @intCast(changelist.len),
        eventlist.ptr,
        @intCast(eventlist.len),
        timeout,
    );
    if (rc < 0) {
        // kevent returns -1 and sets errno (via libc on macOS)
        const e = std.posix.system.errno(rc);
        return switch (e) {
            .INTR => error.Interrupted,
            .AGAIN => error.WouldBlock,
            else => error.Unexpected,
        };
    }
    return @intCast(rc);
}

fn rawClose(fd: c_int) void {
    _ = system.close(fd);
}

fn rawKqueue() !c_int {
    const fd = system.kqueue();
    if (fd < 0) return error.Unexpected;
    return fd;
}

// ── Public API (mostly unchanged) ──────────────────────────────────

/// Identifier of the user event used to break the loop out of `kevent`.
///
/// Idents are namespaced per filter, so this cannot collide with a socket
/// descriptor registered under `EVFILT.READ` or `EVFILT.WRITE`.
pub const wake_ident: usize = 0;

pub fn init() !KQueue {
    const kfd = try rawKqueue();
    return .{ .kfd = kfd };
}

/// Register the user event that `wake` triggers. Call once, before
/// entering the loop.
pub fn registerWake(self: *KQueue) !void {
    try self.queueChange(.{
        .ident = wake_ident,
        .filter = system.EVFILT.USER,
        .flags = system.EV.ADD | system.EV.CLEAR,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    });
}

/// Wake a loop parked in `kevent`, from any thread.
///
/// Applies the trigger with its own `kevent` call rather than going
/// through `queueChange`: the pending-change list belongs to the loop
/// thread and is not synchronised, but the `kevent` syscall itself is
/// safe to issue concurrently on the same kqueue.
pub fn wake(self: *KQueue) void {
    const trigger = [_]system.Kevent{.{
        .ident = wake_ident,
        .filter = system.EVFILT.USER,
        .flags = 0,
        .fflags = std.c.NOTE.TRIGGER,
        .data = 0,
        .udata = 0,
    }};
    // Nothing useful to do if this fails; the loop still exits on its
    // next natural wakeup because the running flag is already cleared.
    _ = rawKevent(self.kfd, &trigger, &.{}, null) catch {};
}

pub fn deinit(self: KQueue) void {
    rawClose(self.kfd);
}

fn queueChange(self: *KQueue, event: system.Kevent) !void {
    var count = self.change_count;
    if (count == self.change_list.len) {
        _ = try rawKevent(self.kfd, &self.change_list, &.{}, null);
        count = 0;
    }
    self.change_list[count] = event;
    self.change_count = count + 1;
}

/// Block for events. A negative `timeout_ms` blocks indefinitely.
pub fn wait(self: *KQueue, timeout_ms: i32) ![]system.Kevent {
    const timeout = std.posix.timespec{
        .sec = @intCast(@divTrunc(timeout_ms, 1000)),
        .nsec = @intCast(@mod(timeout_ms, 1000) * 1000000),
    };

    const count = try rawKevent(
        self.kfd,
        self.change_list[0..self.change_count],
        &self.event_list,
        if (timeout_ms < 0) null else &timeout,
    );
    self.change_count = 0;
    return self.event_list[0..count];
}

pub fn addListener(self: *KQueue, listener: c_int) !void {
    try self.queueChange(.{
        .ident = @intCast(listener),
        .filter = system.EVFILT.READ,
        .flags = system.EV.ADD,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    });
}

/// Stop reporting incoming connections without unregistering the
/// listener, so it can be re-armed later with `enableListener`.
pub fn removeListener(self: *KQueue, listener: c_int) !void {
    try self.queueChange(.{
        .ident = @intCast(listener),
        .filter = system.EVFILT.READ,
        .flags = system.EV.DISABLE,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    });
}

/// Re-arm a listener previously parked by `removeListener`.
pub fn enableListener(self: *KQueue, listener: c_int) !void {
    try self.queueChange(.{
        .ident = @intCast(listener),
        .filter = system.EVFILT.READ,
        .flags = system.EV.ADD | system.EV.ENABLE,
        .fflags = 0,
        .data = 0,
        .udata = 0,
    });
}

pub fn newClient(self: *KQueue, client: *Client) !void {
    try self.queueChange(.{
        .ident = @intCast(client.socket),
        .filter = system.EVFILT.READ,
        .flags = system.EV.ADD | system.EV.CLEAR,
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(client),
    });
    try self.queueChange(.{
        .ident = @intCast(client.socket),
        .filter = system.EVFILT.WRITE,
        .flags = system.EV.ADD | system.EV.DISABLE,
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(client),
    });
}

pub fn readMode(self: *KQueue, client: *Client) !void {
    if (client.socket < 0) return error.InvalidSocket;
    try self.queueChange(.{
        .ident = @intCast(client.socket),
        .filter = system.EVFILT.WRITE,
        .flags = system.EV.ADD | system.EV.DISABLE,
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(client),
    });
    try self.queueChange(.{
        .ident = @intCast(client.socket),
        .filter = system.EVFILT.READ,
        .flags = system.EV.ADD | system.EV.ENABLE,
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(client),
    });
}

pub fn writeMode(self: *KQueue, client: *Client) !void {
    if (client.socket < 0) return error.InvalidSocket;
    try self.queueChange(.{
        .ident = @intCast(client.socket),
        .filter = system.EVFILT.READ,
        .flags = system.EV.ADD | system.EV.DISABLE,
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(client),
    });
    try self.queueChange(.{
        .ident = @intCast(client.socket),
        .filter = system.EVFILT.WRITE,
        .flags = system.EV.ADD | system.EV.ENABLE,
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(client),
    });
}

/// Drop every not-yet-flushed change targeting `fd`.
///
/// Must be called before closing a socket. Otherwise a change queued
/// for it (an arm/disarm from `readMode`/`writeMode`) gets flushed on
/// the next `wait` against a closed descriptor, and kevent reports the
/// failure back as an `EV.ERROR` event still carrying the now-dangling
/// `udata` pointer.
pub fn purgeChanges(self: *KQueue, fd: c_int) void {
    const ident: @TypeOf(self.change_list[0].ident) = @intCast(fd);
    var read_idx: usize = 0;
    var write_idx: usize = 0;
    while (read_idx < self.change_count) : (read_idx += 1) {
        if (self.change_list[read_idx].ident == ident) continue;
        self.change_list[write_idx] = self.change_list[read_idx];
        write_idx += 1;
    }
    self.change_count = write_idx;
}

pub fn addEventRaw(self: *KQueue, event: system.Kevent) !void {
    try self.queueChange(event);
}

pub fn flushChanges(self: *KQueue) !void {
    if (self.change_count > 0) {
        _ = try rawKevent(
            self.kfd,
            self.change_list[0..self.change_count],
            &.{},
            null,
        );
        self.change_count = 0;
    }
}
