const std = @import("std");
const posix = std.posix;
const system = posix.system;
const windows = posix.windows;
const native_os = builtin.os.tag;
const errno = posix.errno;
const builtin = @import("builtin");
const maxInt = std.math.maxInt;
const mem = std.mem;
const fs = @import("fs.zig");
const max_path_bytes = fs.max_path_bytes;
const lfs64_abi = native_os == .linux and builtin.link_libc and (builtin.abi.isGnu() or builtin.abi.isAndroid());

pub const assert = std.debug.assert;
pub const AF = system.AF;
pub const AF_SUN = system.AF_SUN;
pub const AI = system.AI;
pub const ARCH = system.ARCH;
pub const AT = system.AT;
pub const AT_SUN = system.AT_SUN;
pub const CLOCK = system.CLOCK;
pub const CPU_COUNT = system.CPU_COUNT;
pub const CTL = system.CTL;
pub const DT = system.DT;
pub const E = system.E;
pub const Elf_Symndx = system.Elf_Symndx;
pub const F = system.F;
pub const FD_CLOEXEC = system.FD_CLOEXEC;
pub const Flock = system.Flock;
pub const HOST_NAME_MAX = system.HOST_NAME_MAX;
pub const HW = system.HW;
pub const IFNAMESIZE = system.IFNAMESIZE;
pub const IOV_MAX = system.IOV_MAX;
pub const IPPROTO = system.IPPROTO;
pub const KERN = system.KERN;
pub const Kevent = system.Kevent;
pub const MADV = system.MADV;
pub const MAP = system.MAP;
pub const MAX_ADDR_LEN = system.MAX_ADDR_LEN;
pub const MFD = system.MFD;
pub const MREMAP = system.MREMAP;
pub const MSF = system.MSF;
pub const MSG = system.MSG;
pub const NAME_MAX = system.NAME_MAX;
pub const NSIG = system.NSIG;
pub const O = system.O;
pub const PATH_MAX = system.PATH_MAX;
pub const POLL = system.POLL;
pub const POSIX_FADV = system.POSIX_FADV;
pub const PR = system.PR;
pub const PROT = system.PROT;
pub const REG = system.REG;
pub const RLIM = system.RLIM;
pub const RR = system.RR;
pub const S = system.S;
pub const SA = system.SA;
pub const SC = system.SC;
pub const SEEK = system.SEEK;
pub const SHUT = system.SHUT;
pub const SIG = system.SIG;
pub const SIOCGIFINDEX = system.SIOCGIFINDEX;
pub const SO = system.SO;
pub const SOCK = system.SOCK;
pub const SOL = system.SOL;
pub const IFF = system.IFF;
pub const STDERR_FILENO = system.STDERR_FILENO;
pub const STDIN_FILENO = system.STDIN_FILENO;
pub const STDOUT_FILENO = system.STDOUT_FILENO;
pub const SYS = system.SYS;
pub const Sigaction = system.Sigaction;
pub const Stat = system.Stat;
pub const T = system.T;
pub const TCP = system.TCP;
pub const VDSO = system.VDSO;
pub const W = system.W;
pub const _SC = system._SC;
pub const addrinfo = system.addrinfo;
pub const blkcnt_t = system.blkcnt_t;
pub const blksize_t = system.blksize_t;
pub const clock_t = system.clock_t;
pub const timerfd_clockid_t = system.timerfd_clockid_t;
pub const cpu_set_t = system.cpu_set_t;
pub const dev_t = system.dev_t;
pub const dl_phdr_info = system.dl_phdr_info;
pub const fd_t = system.fd_t;
pub const file_obj = system.file_obj;
pub const gid_t = system.gid_t;
pub const ifreq = system.ifreq;
pub const ino_t = system.ino_t;
pub const mcontext_t = system.mcontext_t;
pub const mode_t = system.mode_t;
pub const msghdr = system.msghdr;
pub const msghdr_const = system.msghdr_const;
pub const nfds_t = system.nfds_t;
pub const nlink_t = system.nlink_t;
pub const off_t = system.off_t;
pub const pid_t = system.pid_t;
pub const pollfd = system.pollfd;
pub const port_event = system.port_event;
pub const port_notify = system.port_notify;
pub const port_t = system.port_t;
pub const rlim_t = system.rlim_t;
pub const rlimit = system.rlimit;
pub const rlimit_resource = system.rlimit_resource;
pub const rusage = system.rusage;
pub const sa_family_t = system.sa_family_t;
pub const siginfo_t = system.siginfo_t;
pub const sigset_t = system.sigset_t;
pub const sigrtmin = system.sigrtmin;
pub const sigrtmax = system.sigrtmax;
pub const sockaddr = system.sockaddr;
pub const socklen_t = system.socklen_t;
pub const stack_t = system.stack_t;
pub const time_t = system.time_t;
pub const timeval = system.timeval;
pub const timezone = system.timezone;
pub const ucontext_t = system.ucontext_t;
pub const uid_t = system.uid_t;
pub const user_desc = system.user_desc;
pub const utsname = system.utsname;

pub const termios = system.termios;
pub const CSIZE = system.CSIZE;
pub const NCCS = system.NCCS;
pub const cc_t = system.cc_t;
pub const V = system.V;
pub const speed_t = system.speed_t;
pub const tc_iflag_t = system.tc_iflag_t;
pub const tc_oflag_t = system.tc_oflag_t;
pub const tc_cflag_t = system.tc_cflag_t;
pub const tc_lflag_t = system.tc_lflag_t;
pub const socket_t = system.socket_t;

pub const F_OK = system.F_OK;
pub const R_OK = system.R_OK;
pub const W_OK = system.W_OK;
pub const X_OK = system.X_OK;

pub const SocketError = error{
    /// Permission to create a socket of the specified type and/or
    /// pro‐tocol is denied.
    PermissionDenied,

    /// The implementation does not support the specified address family.
    AddressFamilyNotSupported,

    /// Unknown protocol, or protocol family not available.
    ProtocolFamilyNotAvailable,

    /// The per-process limit on the number of open file descriptors has been reached.
    ProcessFdQuotaExceeded,

    /// The system-wide limit on the total number of open files has been reached.
    SystemFdQuotaExceeded,

    /// Insufficient memory is available. The socket cannot be created until sufficient
    /// resources are freed.
    SystemResources,

    /// The protocol type or the specified protocol is not supported within this domain.
    ProtocolNotSupported,

    /// The socket type is not supported by the protocol.
    SocketTypeNotSupported,
} || UnexpectedError;

pub const UnexpectedError = error{
    /// The Operating System returned an undocumented error code.
    ///
    /// This error is in theory not possible, but it would be better
    /// to handle this error than to invoke undefined behavior.
    ///
    /// When this error code is observed, it usually means the Zig Standard
    /// Library needs a small patch to add the error code to the error set for
    /// the respective function.
    Unexpected,
};

pub const unexpected_error_tracing = builtin.zig_backend == .stage2_llvm and builtin.mode == .Debug;

/// Call this when you made a syscall or something that sets errno
/// and you get an unexpected error.
pub fn unexpectedErrno(err: posix.system.E) UnexpectedError {
    if (unexpected_error_tracing) {
        std.debug.print("unexpected errno: {d}\n", .{@intFromEnum(err)});
        std.debug.dumpCurrentStackTrace(.{});
    }
    return error.Unexpected;
}

pub fn close(fd: fd_t) void {
    switch (errno(system.close(fd))) {
        .BADF => unreachable, // Always a race condition.
        .INTR => return, // This is still a success. See https://github.com/ziglang/zig/issues/2425
        else => return,
    }
}

pub fn socket(domain: u32, socket_type: u32, protocol: u32) !socket_t {
    if (native_os == .windows) {
        // These flags are not actually part of the Windows API, instead they are converted here for compatibility
        const filtered_sock_type = socket_type & ~@as(u32, SOCK.NONBLOCK | SOCK.CLOEXEC);
        var flags: u32 = windows.ws2_32.WSA_FLAG_OVERLAPPED;
        if ((socket_type & SOCK.CLOEXEC) != 0) flags |= windows.ws2_32.WSA_FLAG_NO_HANDLE_INHERIT;

        const rc = try windows.WSASocketW(
            @bitCast(domain),
            @bitCast(filtered_sock_type),
            @bitCast(protocol),
            null,
            0,
            flags,
        );
        errdefer windows.closesocket(rc) catch unreachable;
        if ((socket_type & SOCK.NONBLOCK) != 0) {
            var mode: c_ulong = 1; // nonblocking
            if (windows.ws2_32.SOCKET_ERROR == windows.ws2_32.ioctlsocket(rc, windows.ws2_32.FIONBIO, &mode)) {
                switch (windows.ws2_32.WSAGetLastError()) {
                    // have not identified any error codes that should be handled yet
                    else => unreachable,
                }
            }
        }
        return rc;
    }

    const have_sock_flags = !builtin.target.os.tag.isDarwin() and native_os != .haiku;
    const filtered_sock_type = if (!have_sock_flags)
        socket_type & ~@as(u32, SOCK.NONBLOCK | SOCK.CLOEXEC)
    else
        socket_type;
    const rc = system.socket(domain, filtered_sock_type, protocol);
    switch (errno(rc)) {
        .SUCCESS => {
            const fd: fd_t = @intCast(rc);
            errdefer close(fd);
            if (!have_sock_flags) {
                try setSockFlags(fd, socket_type);
            }
            return fd;
        },
        .ACCES => return error.AccessDenied,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .INVAL => return error.ProtocolFamilyNotAvailable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS => return error.SystemResources,
        .NOMEM => return error.SystemResources,
        .PROTONOSUPPORT => return error.ProtocolNotSupported,
        .PROTOTYPE => return error.SocketTypeNotSupported,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn listen(sock: socket_t, backlog: u31) !void {
    const rc = system.listen(sock, backlog);
    switch (errno(rc)) {
        .SUCCESS => return,
        .ADDRINUSE => return error.AddressInUse,
        .BADF => unreachable,
        .NOTSOCK => return error.FileDescriptorNotASocket,
        .OPNOTSUPP => return error.OperationNotSupported,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn bind(sock: socket_t, addr: *const sockaddr, len: socklen_t) !void {
    if (native_os == .windows) {
        const rc = windows.bind(sock, addr, len);
        if (rc == windows.ws2_32.SOCKET_ERROR) {
            switch (windows.ws2_32.WSAGetLastError()) {
                .WSANOTINITIALISED => unreachable, // not initialized WSA
                .WSAEACCES => return error.AccessDenied,
                .WSAEADDRINUSE => return error.AddressInUse,
                .WSAEADDRNOTAVAIL => return error.AddressNotAvailable,
                .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                .WSAEFAULT => unreachable, // invalid pointers
                .WSAEINVAL => return error.AlreadyBound,
                .WSAENOBUFS => return error.SystemResources,
                .WSAENETDOWN => return error.NetworkSubsystemFailed,
                else => |err| return windows.unexpectedWSAError(err),
            }
            unreachable;
        }
        return;
    } else {
        const rc = system.bind(sock, addr, len);
        switch (errno(rc)) {
            .SUCCESS => return,
            .ACCES, .PERM => return error.AccessDenied,
            .ADDRINUSE => return error.AddressInUse,
            .BADF => unreachable, // always a race condition if this error is returned
            .INVAL => unreachable, // invalid parameters
            .NOTSOCK => unreachable, // invalid `sockfd`
            .AFNOSUPPORT => return error.AddressFamilyNotSupported,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            .FAULT => unreachable, // invalid `addr` pointer
            .LOOP => return error.SymLinkLoop,
            .NAMETOOLONG => return error.NameTooLong,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOTDIR => return error.NotDir,
            .ROFS => return error.ReadOnlyFileSystem,
            else => |err| return unexpectedErrno(err),
        }
    }
    unreachable;
}

pub fn accept(
    /// This argument is a socket that has been created with `socket`, bound to a local address
    /// with `bind`, and is listening for connections after a `listen`.
    sock: posix.socket_t,
    /// This argument is a pointer to a sockaddr structure.  This structure is filled in with  the
    /// address  of  the  peer  socket, as known to the communications layer.  The exact format of the
    /// address returned addr is determined by the socket's address  family  (see  `socket`  and  the
    /// respective  protocol  man  pages).
    addr: ?*posix.sockaddr,
    /// This argument is a value-result argument: the caller must initialize it to contain  the
    /// size (in bytes) of the structure pointed to by addr; on return it will contain the actual size
    /// of the peer address.
    ///
    /// The returned address is truncated if the buffer provided is too small; in this  case,  `addr_size`
    /// will return a value greater than was supplied to the call.
    addr_size: ?*posix.socklen_t,
    /// The following values can be bitwise ORed in flags to obtain different behavior:
    /// * `SOCK.NONBLOCK` - Set the `NONBLOCK` file status flag on the open file description (see `open`)
    ///   referred  to by the new file descriptor.  Using this flag saves extra calls to `fcntl` to achieve
    ///   the same result.
    /// * `SOCK.CLOEXEC`  - Set the close-on-exec (`FD_CLOEXEC`) flag on the new file descriptor.   See  the
    ///   description  of the `CLOEXEC` flag in `open` for reasons why this may be useful.
    flags: u32,
) !posix.socket_t {
    const have_accept4 = !(builtin.target.isDarwinLibC() or builtin.os.tag == .windows or builtin.os.tag == .linux);
    std.debug.assert(0 == (flags & ~@as(u32, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC))); // Unsupported flag(s)

    const accepted_sock: posix.socket_t = while (true) {
        const rc = if (have_accept4)
            system.accept4(sock, addr, addr_size, flags)
        else
            system.accept(sock, addr, addr_size);

        switch (errno(rc)) {
            .SUCCESS => break @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => unreachable, // always a race condition
            .CONNABORTED => return error.ConnectionAborted,
            .FAULT => unreachable,
            .INVAL => return error.SocketNotListening,
            .NOTSOCK => unreachable,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .OPNOTSUPP => unreachable,
            .PROTO => return error.ProtocolFailure,
            .PERM => return error.BlockedByFirewall,
            else => |err| return unexpectedErrno(err),
        }
    };

    errdefer close(accepted_sock);
    if (!have_accept4) {
        try setSockFlags(accepted_sock, flags);
    }
    return accepted_sock;
}

pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) !usize {
    while (true) {
        const rc = system.fcntl(fd, cmd, arg);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN, .ACCES => return error.Locked,
            .BADF => unreachable,
            .BUSY => return error.FileBusy,
            .INVAL => unreachable, // invalid parameters
            .PERM => return error.PermissionDenied,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NOTDIR => unreachable, // invalid parameter
            .DEADLK => return error.DeadLock,
            .NOLCK => return error.LockedRegionLimitExceeded,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn setSockFlags(sock: socket_t, flags: u32) !void {
    if ((flags & SOCK.CLOEXEC) != 0) {
        if (native_os == .windows) {
            // TODO: Find out if this is supported for sockets
        } else {
            var fd_flags = fcntl(sock, F.GETFD, 0) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                error.DeadLock => unreachable,
                error.LockedRegionLimitExceeded => unreachable,
                else => |e| return e,
            };
            fd_flags |= FD_CLOEXEC;
            _ = fcntl(sock, F.SETFD, fd_flags) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                error.DeadLock => unreachable,
                error.LockedRegionLimitExceeded => unreachable,
                else => |e| return e,
            };
        }
    }
    if ((flags & SOCK.NONBLOCK) != 0) {
        if (native_os == .windows) {
            var mode: c_ulong = 1;
            if (windows.ws2_32.ioctlsocket(sock, windows.ws2_32.FIONBIO, &mode) == windows.ws2_32.SOCKET_ERROR) {
                switch (windows.ws2_32.WSAGetLastError()) {
                    .WSANOTINITIALISED => unreachable,
                    .WSAENETDOWN => return error.NetworkSubsystemFailed,
                    .WSAENOTSOCK => return error.FileDescriptorNotASocket,
                    // TODO: handle more errors
                    else => |err| return windows.unexpectedWSAError(err),
                }
            }
        } else {
            var fl_flags = fcntl(sock, F.GETFL, 0) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                error.DeadLock => unreachable,
                error.LockedRegionLimitExceeded => unreachable,
                else => |e| return e,
            };
            fl_flags |= 1 << @bitOffsetOf(O, "NONBLOCK");
            _ = fcntl(sock, F.SETFL, fl_flags) catch |err| switch (err) {
                error.FileBusy => unreachable,
                error.Locked => unreachable,
                error.PermissionDenied => unreachable,
                error.DeadLock => unreachable,
                error.LockedRegionLimitExceeded => unreachable,
                else => |e| return e,
            };
        }
    }
}

/// Test whether a file descriptor refers to a terminal.
pub fn isatty(handle: fd_t) bool {
    if (builtin.link_libc) {
        return system.isatty(handle) != 0;
    }
    return system.isatty(handle) != 0;
}

pub fn tcgetattr(handle: fd_t) posix.TermiosGetError!posix.termios {
    while (true) {
        var term: posix.termios = undefined;
        switch (errno(system.tcgetattr(handle, &term))) {
            .SUCCESS => return term,
            .INTR => continue,
            .BADF => unreachable,
            .NOTTY => return error.NotATerminal,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn tcsetattr(handle: fd_t, optional_action: posix.TCSA, termios_p: posix.termios) posix.TermiosSetError!void {
    while (true) {
        switch (errno(system.tcsetattr(handle, optional_action, &termios_p))) {
            .SUCCESS => return,
            .BADF => unreachable,
            .INTR => continue,
            .INVAL => unreachable,
            .NOTTY => return error.NotATerminal,
            .IO => return error.ProcessOrphaned,
            else => |err| return unexpectedErrno(err),
        }
    }
}

/// initialize an inotify instance
pub fn inotify_init1(flags: u32) !i32 {
    const rc = system.inotify_init1(flags);
    switch (errno(rc)) {
        .SUCCESS => return @intCast(rc),
        .INVAL => unreachable,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOMEM => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

const timespec = posix.timespec;
pub const timestamp_t = system.timestamp_t;
const clockid_t = system.clockid_t;

pub const ClockGetTimeError = error{UnsupportedClock} || UnexpectedError;

pub fn clock_gettime(clock_id: clockid_t) ClockGetTimeError!timespec {
    var tp: timespec = undefined;

    if (native_os == .windows) {
        @compileError("Windows does not support POSIX; use Windows-specific API or cross-platform std.time API");
    } else if (native_os == .wasi and !builtin.link_libc) {
        var ts: timestamp_t = undefined;
        switch (system.clock_time_get(clock_id, 1, &ts)) {
            .SUCCESS => {
                tp = .{
                    .sec = @intCast(ts / std.time.ns_per_s),
                    .nsec = @intCast(ts % std.time.ns_per_s),
                };
            },
            .INVAL => return error.UnsupportedClock,
            else => |err| return unexpectedErrno(err),
        }
        return tp;
    }

    switch (errno(system.clock_gettime(clock_id, &tp))) {
        .SUCCESS => return tp,
        .FAULT => unreachable,
        .INVAL => return error.UnsupportedClock,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn read(fd: fd_t, buf: []u8) ReadError!usize {
    if (buf.len == 0) return 0;
    // Prevents EINVAL.
    const max_count = switch (native_os) {
        .linux => 0x7ffff000,
        .macos, .ios, .watchos, .tvos, .visionos => maxInt(i32),
        else => maxInt(isize),
    };
    while (true) {
        const rc = system.read(fd, buf.ptr, @min(buf.len, max_count));
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL => unreachable,
            .FAULT => unreachable,
            .SRCH => return error.ProcessNotFound,
            .AGAIN => return error.WouldBlock,
            .CANCELED => return error.Canceled,
            .BADF => return error.NotOpenForReading, // Can be a race condition.
            .IO => return error.InputOutput,
            .ISDIR => return error.IsDir,
            .NOBUFS => return error.SystemResources,
            .NOMEM => return error.SystemResources,
            .NOTCONN => return error.SocketNotConnected,
            .CONNRESET => return error.ConnectionResetByPeer,
            .TIMEDOUT => return error.ConnectionTimedOut,
            else => |err| return unexpectedErrno(err),
        }
    }
}

fn write(fd: i32, buf: []const u8) !usize {
    const rc = posix.system.write(fd, buf.ptr, buf.len);
    const e = posix.system.errno(rc);
    if (e != .SUCCESS) return switch (e) {
        .AGAIN => error.WouldBlock,
        .PIPE => error.BrokenPipe,
        .CONNRESET => error.ConnectionReset,
        .INTR => error.Interrupted,
        else => error.Unexpected,
    };
    if (rc == 0) return error.Closed;
    return @intCast(rc);
}

pub const ReadError = error{
    InputOutput,
    SystemResources,
    IsDir,
    OperationAborted,
    BrokenPipe,
    ConnectionResetByPeer,
    ConnectionTimedOut,
    NotOpenForReading,
    SocketNotConnected,

    /// This error occurs when no global event loop is configured,
    /// and reading from the file descriptor would block.
    WouldBlock,

    /// reading a timerfd with CANCEL_ON_SET will lead to this error
    /// when the clock goes through a discontinuous change
    Canceled,

    /// In WASI, this error occurs when the file descriptor does
    /// not hold the required rights to read from it.
    AccessDenied,

    /// This error occurs in Linux if the process to be read from
    /// no longer exists.
    ProcessNotFound,

    /// Unable to read file due to lock.
    LockViolation,
} || UnexpectedError;

pub fn realpath(pathname: []const u8, out_buffer: *[max_path_bytes]u8) RealPathError![]u8 {
    if (native_os == .windows) {
        const pathname_w = try windows.sliceToPrefixedFileW(null, pathname);
        return realpathW(pathname_w.span(), out_buffer);
    } else if (native_os == .wasi and !builtin.link_libc) {
        @compileError("WASI does not support os.realpath");
    }
    const pathname_c = try toPosixPath(pathname);
    return realpathZ(&pathname_c, out_buffer);
}

/// Same as `realpath` except `pathname` is null-terminated.
///
/// Calling this function is usually a bug.
pub fn realpathZ(pathname: [*:0]const u8, out_buffer: *[max_path_bytes]u8) RealPathError![]u8 {
    if (native_os == .windows) {
        const pathname_w = try windows.cStrToPrefixedFileW(null, pathname);
        return realpathW(pathname_w.span(), out_buffer);
    } else if (native_os == .wasi and !builtin.link_libc) {
        return realpath(mem.sliceTo(pathname, 0), out_buffer);
    }
    if (!builtin.link_libc) {
        const flags: O = switch (native_os) {
            .linux => .{
                .NONBLOCK = true,
                .CLOEXEC = true,
                .PATH = true,
            },
            else => .{
                .NONBLOCK = true,
                .CLOEXEC = true,
            },
        };
        const fd = openZ(pathname, flags, 0) catch |err| switch (err) {
            error.FileLocksNotSupported => unreachable,
            error.WouldBlock => unreachable,
            error.FileBusy => unreachable, // not asking for write permissions
            error.InvalidUtf8 => unreachable, // WASI-only
            else => |e| return e,
        };
        defer close(fd);

        return std.os.getFdPath(fd, out_buffer);
    }
    const result_path = std.c.realpath(pathname, out_buffer) orelse switch (@as(E, @enumFromInt(std.c._errno().*))) {
        .SUCCESS => unreachable,
        .INVAL => unreachable,
        .BADF => unreachable,
        .FAULT => unreachable,
        .ACCES => return error.AccessDenied,
        .NOENT => return error.FileNotFound,
        .OPNOTSUPP => return error.NotSupported,
        .NOTDIR => return error.NotDir,
        .NAMETOOLONG => return error.NameTooLong,
        .LOOP => return error.SymLinkLoop,
        .IO => return error.InputOutput,
        else => |err| return unexpectedErrno(err),
    };
    return mem.sliceTo(result_path, 0);
}

/// Same as `realpath` except `pathname` is WTF16LE-encoded.
///
/// The result is encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
///
/// Calling this function is usually a bug.
pub fn realpathW(pathname: []const u16, out_buffer: *[max_path_bytes]u8) RealPathError![]u8 {
    const w = windows;

    const dir = fs.cwd().fd;
    const access_mask = w.GENERIC_READ | w.SYNCHRONIZE;
    const share_access = w.FILE_SHARE_READ | w.FILE_SHARE_WRITE | w.FILE_SHARE_DELETE;
    const creation = w.FILE_OPEN;
    const h_file = blk: {
        const res = w.OpenFile(pathname, .{
            .dir = dir,
            .access_mask = access_mask,
            .share_access = share_access,
            .creation = creation,
            .filter = .any,
        }) catch |err| switch (err) {
            error.WouldBlock => unreachable,
            else => |e| return e,
        };
        break :blk res;
    };
    defer w.CloseHandle(h_file);

    return std.os.getFdPath(h_file, out_buffer);
}

pub const RealPathError = error{
    FileNotFound,
    AccessDenied,
    PermissionDenied,
    NameTooLong,
    NotSupported,
    NotDir,
    SymLinkLoop,
    InputOutput,
    FileTooBig,
    IsDir,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    SystemResources,
    NoSpaceLeft,
    FileSystem,
    BadPathName,
    DeviceBusy,
    ProcessNotFound,

    SharingViolation,
    PipeBusy,

    /// Windows-only; file paths provided by the user must be valid WTF-8.
    /// https://simonsapin.github.io/wtf-8/
    InvalidWtf8,

    /// On Windows, `\\server` or `\\server\share` was not found.
    NetworkNotFound,

    PathAlreadyExists,

    /// On Windows, antivirus software is enabled by default. It can be
    /// disabled, but Windows Update sometimes ignores the user's preference
    /// and re-enables it. When enabled, antivirus software on Windows
    /// intercepts file system operations and makes them significantly slower
    /// in addition to possibly failing with this error code.
    AntivirusInterference,

    /// On Windows, the volume does not contain a recognized file system. File
    /// system drivers might not be loaded, or the volume may be corrupt.
    UnrecognizedVolume,
} || UnexpectedError;

/// Open and possibly create a file. Keeps trying if it gets interrupted.
/// On Windows, `file_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `file_path` should be encoded as valid UTF-8.
/// On other platforms, `file_path` is an opaque sequence of bytes with no particular encoding.
/// See also `openZ`.
pub fn open(file_path: []const u8, flags: O, perm: mode_t) OpenError!fd_t {
    if (native_os == .windows) {
        @compileError("Windows does not support POSIX; use Windows-specific API or cross-platform std.fs API");
    } else if (native_os == .wasi and !builtin.link_libc) {
        return openat(AT.FDCWD, file_path, flags, perm);
    }
    const file_path_c = try toPosixPath(file_path);
    return openZ(&file_path_c, flags, perm);
}

/// Open and possibly create a file. Keeps trying if it gets interrupted.
/// `file_path` is relative to the open directory handle `dir_fd`.
/// On Windows, `file_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `file_path` should be encoded as valid UTF-8.
/// On other platforms, `file_path` is an opaque sequence of bytes with no particular encoding.
/// See also `openatZ`.
pub fn openat(dir_fd: fd_t, file_path: []const u8, flags: O, mode: mode_t) OpenError!fd_t {
    if (native_os == .windows) {
        @compileError("Windows does not support POSIX; use Windows-specific API or cross-platform std.fs API");
    }
    const file_path_c = try toPosixPath(file_path);
    return openatZ(dir_fd, &file_path_c, flags, mode);
}

/// Open and possibly create a file. Keeps trying if it gets interrupted.
/// `file_path` is relative to the open directory handle `dir_fd`.
/// On Windows, `file_path` should be encoded as [WTF-8](https://simonsapin.github.io/wtf-8/).
/// On WASI, `file_path` should be encoded as valid UTF-8.
/// On other platforms, `file_path` is an opaque sequence of bytes with no particular encoding.
/// See also `openat`.
pub fn openatZ(dir_fd: fd_t, file_path: [*:0]const u8, flags: O, mode: mode_t) OpenError!fd_t {
    if (native_os == .windows) {
        @compileError("Windows does not support POSIX; use Windows-specific API or cross-platform std.fs API");
    } else if (native_os == .wasi and !builtin.link_libc) {
        return openat(dir_fd, mem.sliceTo(file_path, 0), flags, mode);
    }

    const openat_sym = if (lfs64_abi) system.openat64 else system.openat;
    while (true) {
        const rc = openat_sym(dir_fd, file_path, flags, mode);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,

            .FAULT => unreachable,
            .INVAL => return error.BadPathName,
            .BADF => unreachable,
            .ACCES => return error.AccessDenied,
            .FBIG => return error.FileTooBig,
            .OVERFLOW => return error.FileTooBig,
            .ISDIR => return error.IsDir,
            .LOOP => return error.SymLinkLoop,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NODEV => return error.NoDevice,
            .NOENT => return error.FileNotFound,
            .SRCH => return error.ProcessNotFound,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .EXIST => return error.PathAlreadyExists,
            .BUSY => return error.DeviceBusy,
            .OPNOTSUPP => return error.FileLocksNotSupported,
            .AGAIN => return error.WouldBlock,
            .TXTBSY => return error.FileBusy,
            .NXIO => return error.NoDevice,
            .ILSEQ => |err| if (native_os == .wasi)
                return error.InvalidUtf8
            else
                return unexpectedErrno(err),
            else => |err| return unexpectedErrno(err),
        }
    }
}

/// Used to convert a slice to a null terminated slice on the stack.
pub fn toPosixPath(file_path: []const u8) error{NameTooLong}![PATH_MAX - 1:0]u8 {
    if (std.debug.runtime_safety) assert(mem.indexOfScalar(u8, file_path, 0) == null);
    var path_with_null: [PATH_MAX - 1:0]u8 = undefined;
    // >= rather than > to make room for the null byte
    if (file_path.len >= PATH_MAX) return error.NameTooLong;
    @memcpy(path_with_null[0..file_path.len], file_path);
    path_with_null[file_path.len] = 0;
    return path_with_null;
}

pub fn openZ(file_path: [*:0]const u8, flags: O, perm: mode_t) OpenError!fd_t {
    if (native_os == .windows) {
        @compileError("Windows does not support POSIX; use Windows-specific API or cross-platform std.fs API");
    } else if (native_os == .wasi and !builtin.link_libc) {
        return open(mem.sliceTo(file_path, 0), flags, perm);
    }

    const open_sym = if (lfs64_abi) system.open64 else system.open;
    while (true) {
        const rc = open_sym(file_path, flags, perm);
        switch (errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,

            .FAULT => unreachable,
            .INVAL => return error.BadPathName,
            .ACCES => return error.AccessDenied,
            .FBIG => return error.FileTooBig,
            .OVERFLOW => return error.FileTooBig,
            .ISDIR => return error.IsDir,
            .LOOP => return error.SymLinkLoop,
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NAMETOOLONG => return error.NameTooLong,
            .NFILE => return error.SystemFdQuotaExceeded,
            .NODEV => return error.NoDevice,
            .NOENT => return error.FileNotFound,
            .SRCH => return error.ProcessNotFound,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            .NOTDIR => return error.NotDir,
            .PERM => return error.PermissionDenied,
            .EXIST => return error.PathAlreadyExists,
            .BUSY => return error.DeviceBusy,
            .ILSEQ => |err| if (native_os == .wasi)
                return error.InvalidUtf8
            else
                return unexpectedErrno(err),
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const OpenError = error{
    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to open a new resource relative to it.
    AccessDenied,
    PermissionDenied,
    SymLinkLoop,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    NoDevice,
    /// Either:
    /// * One of the path components does not exist.
    /// * Cwd was used, but cwd has been deleted.
    /// * The path associated with the open directory handle has been deleted.
    /// * On macOS, multiple processes or threads raced to create the same file
    ///   with `O.EXCL` set to `false`.
    FileNotFound,

    /// The path exceeded `max_path_bytes` bytes.
    NameTooLong,

    /// Insufficient kernel memory was available, or
    /// the named file is a FIFO and per-user hard limit on
    /// memory allocation for pipes has been reached.
    SystemResources,

    /// The file is too large to be opened. This error is unreachable
    /// for 64-bit targets, as well as when opening directories.
    FileTooBig,

    /// The path refers to directory but the `DIRECTORY` flag was not provided.
    IsDir,

    /// A new path cannot be created because the device has no room for the new file.
    /// This error is only reachable when the `CREAT` flag is provided.
    NoSpaceLeft,

    /// A component used as a directory in the path was not, in fact, a directory, or
    /// `DIRECTORY` was specified and the path was not a directory.
    NotDir,

    /// The path already exists and the `CREAT` and `EXCL` flags were provided.
    PathAlreadyExists,
    DeviceBusy,

    /// The underlying filesystem does not support file locks
    FileLocksNotSupported,

    /// Path contains characters that are disallowed by the underlying filesystem.
    BadPathName,

    /// WASI-only; file paths must be valid UTF-8.
    InvalidUtf8,

    /// Windows-only; file paths provided by the user must be valid WTF-8.
    /// https://simonsapin.github.io/wtf-8/
    InvalidWtf8,

    /// On Windows, `\\server` or `\\server\share` was not found.
    NetworkNotFound,

    /// This error occurs in Linux if the process to be open was not found.
    ProcessNotFound,

    /// One of these three things:
    /// * pathname  refers to an executable image which is currently being
    ///   executed and write access was requested.
    /// * pathname refers to a file that is currently in  use  as  a  swap
    ///   file, and the O_TRUNC flag was specified.
    /// * pathname  refers  to  a file that is currently being read by the
    ///   kernel (e.g., for module/firmware loading), and write access was
    ///   requested.
    FileBusy,

    WouldBlock,
} || UnexpectedError;

pub const FlockError = error{
    WouldBlock,

    /// The kernel ran out of memory for allocating file locks
    SystemResources,

    /// The underlying filesystem does not support file locks
    FileLocksNotSupported,
} || UnexpectedError;

/// Depending on the operating system `flock` may or may not interact with
/// `fcntl` locks made by other processes.
pub fn flock(fd: fd_t, operation: i32) FlockError!void {
    while (true) {
        const rc = system.flock(fd, operation);
        switch (errno(rc)) {
            .SUCCESS => return,
            .BADF => unreachable,
            .INTR => continue,
            .INVAL => unreachable, // invalid parameters
            .NOLCK => return error.SystemResources,
            .AGAIN => return error.WouldBlock, // TODO: integrate with async instead of just returning an error
            .OPNOTSUPP => return error.FileLocksNotSupported,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub const FStatError = error{
    SystemResources,

    /// In WASI, this error may occur when the file descriptor does
    /// not hold the required rights to get its filestat information.
    AccessDenied,
    PermissionDenied,
} || UnexpectedError;

/// Return information about a file descriptor.
pub fn fstat(fd: fd_t) FStatError!Stat {
    if (native_os == .wasi and !builtin.link_libc) {
        return Stat.fromFilestat(try std.os.fstat_wasi(fd));
    }
    if (native_os == .windows) {
        @compileError("fstat is not yet implemented on Windows");
    }

    const fstat_sym = if (lfs64_abi) system.fstat64 else system.fstat;
    var stat = mem.zeroes(Stat);
    switch (errno(fstat_sym(fd, &stat))) {
        .SUCCESS => return stat,
        .INVAL => unreachable,
        .BADF => unreachable, // Always a race condition.
        .NOMEM => return error.SystemResources,
        .ACCES => return error.AccessDenied,
        else => |err| return unexpectedErrno(err),
    }
}

pub const FStatAtError = FStatError || error{
    NameTooLong,
    FileNotFound,
    SymLinkLoop,
    /// WASI-only; file paths must be valid UTF-8.
    InvalidUtf8,
};

