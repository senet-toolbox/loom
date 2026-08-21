//! Readiness notification, one backend per platform.
//!
//! `kqueue` on macOS and the BSDs, `epoll` on Linux. Both are wrapped
//! behind the same small API and, more importantly, both report through
//! one normalised `Event` type — so the event loop itself contains no
//! platform conditionals at all.
//!
//! The two mechanisms differ in ways the wrapper has to smooth over:
//!
//!   * kqueue reports one event per (descriptor, filter) pair, so a
//!     socket that is both readable and writable produces two events.
//!     epoll reports one event per descriptor with both bits set. The
//!     normalised event carries `readable` and `writable` separately and
//!     callers must be prepared for both to be true at once.
//!   * kqueue batches registration changes and applies them with the
//!     next `wait`. epoll applies each change immediately with its own
//!     syscall. `flushChanges` and `purgeChanges` therefore do real work
//!     on kqueue and nothing on epoll.
//!   * kqueue can disable a registration in place; epoll cannot, so
//!     parking the listener there means removing and re-adding it.

const std = @import("std");
const builtin = @import("builtin");

/// What a readiness notification refers to.
pub const Source = enum {
    /// A new connection is waiting to be accepted.
    listener,
    /// `wake` was called; the loop should re-check its own state.
    wake,
    /// Activity on an established connection.
    client,
};

/// One readiness notification, in a form neither backend leaks through.
pub const Event = struct {
    source: Source,
    /// Set when `source` is `.client`.
    client_ptr: usize = 0,
    readable: bool = false,
    writable: bool = false,
    /// The descriptor is finished: an error, or the peer hung up. The
    /// connection should be dropped.
    failed: bool = false,
};

/// Errors `wait` may report. Shared by both backends so the event loop
/// can handle them without knowing which one it is talking to.
pub const WaitError = error{
    /// A signal arrived; nothing was lost, just call again.
    Interrupted,
    /// Nothing was ready. Only some backends report this rather than
    /// returning an empty set.
    WouldBlock,
    Unexpected,
};

/// Sentinel user-data values. Real clients are identified by pointer, and
/// no valid pointer is 0 or 1, so these can share the field.
pub const tag_listener: usize = 0;
pub const tag_wake: usize = 1;

pub const Backend = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => @import("KQueue.zig"),
    .linux => @import("Epoll.zig"),
    else => @compileError(
        "Loom has no readiness backend for " ++ @tagName(builtin.os.tag) ++
            " -- kqueue (macOS/BSD) and epoll (Linux) are supported",
    ),
};

test "backend satisfies the poller contract" {
    // Compile-time check that whichever backend was selected exposes
    // everything the event loop calls.
    const required = .{
        "init",           "deinit",       "wait",     "addListener", "removeListener",
        "enableListener", "newClient",    "readMode", "writeMode",   "purgeChanges",
        "flushChanges",   "registerWake", "wake",
    };
    inline for (required) |name| {
        if (!@hasDecl(Backend, name)) {
            @compileError("readiness backend is missing '" ++ name ++ "'");
        }
    }
}
