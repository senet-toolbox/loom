// [timestamp] [log_type] [file] string
const std = @import("std");
const Time = @import("Time.zig");
const timestamp = Time.timestamp;

pub const Logger = @This();
mutex: std.Io.Mutex,

/// Where formatted lines go. `null` means stderr, which is what a server
/// wants; tests point it at a buffer so they can assert on the output
/// instead of just watching it scroll past.
sink: ?*std.Io.Writer = null,

const LogLevel = enum {
    DEBUG,
    WARN,
    FATAL,
    INFO,
    ERROR,

    pub fn color(log_level: LogLevel) []const u8 {
        return switch (log_level) {
            .DEBUG => "\x1b[36m", // Cyan
            .INFO => "\x1b[32m", // Green
            .WARN => "\x1b[33m", // Yellow
            .ERROR => "\x1b[31m", // Red
            .FATAL => "\x1b[35m", // Magenta
        };
    }
};

pub fn init(target: *Logger) void {
    target.* = .{
        .mutex = .{ .state = .{ .raw = .unlocked } },
    };
}

/// Redirect output, for tests. Pass `null` to go back to stderr.
pub fn setSink(logger: *Logger, sink: ?*std.Io.Writer) void {
    logger.sink = sink;
}

fn log(
    logger: *Logger,
    log_level: LogLevel,
    comptime fmt: []const u8,
    args: anytype,
    opt_src: ?std.builtin.SourceLocation,
) !void {
    std.Io.Threaded.mutexLock(&logger.mutex);
    defer std.Io.Threaded.mutexUnlock(&logger.mutex);
    var buf: [1024]u8 = undefined;
    var errstream = std.Io.Writer.fixed(&buf);
    const stderr = &errstream;

    nosuspend stderr.print("[{d}] ", .{timestamp()}) catch return;
    nosuspend stderr.print("[{s}{s}\x1b[0m] ", .{ log_level.color(), @tagName(log_level) }) catch return;
    if (opt_src) |src| {
        nosuspend stderr.print("[{s}:{d}] => ", .{ src.file, src.line }) catch return;
    }
    nosuspend stderr.print(fmt, args) catch return;
    nosuspend stderr.print("\n", .{}) catch return;

    const line = stderr.buffer[0..stderr.end];
    if (logger.sink) |sink| {
        nosuspend sink.writeAll(line) catch return;
    } else {
        std.debug.print("{s}", .{line});
    }
    try stderr.flush();
}

pub fn warn(
    logger: *Logger,
    comptime fmt: []const u8,
    args: anytype,
    opt_src: ?std.builtin.SourceLocation,
) !void {
    try logger.log(LogLevel.WARN, fmt, args, opt_src);
}
pub fn debug(
    logger: *Logger,
    comptime fmt: []const u8,
    args: anytype,
    opt_src: ?std.builtin.SourceLocation,
) !void {
    try logger.log(LogLevel.DEBUG, fmt, args, opt_src);
}
pub fn fatal(
    logger: *Logger,
    comptime fmt: []const u8,
    args: anytype,
    opt_src: ?std.builtin.SourceLocation,
) !void {
    try logger.log(LogLevel.FATAL, fmt, args, opt_src);
}
pub fn info(
    logger: *Logger,
    comptime fmt: []const u8,
    args: anytype,
    opt_src: ?std.builtin.SourceLocation,
) !void {
    try logger.log(LogLevel.INFO, fmt, args, opt_src);
}
pub fn err(
    logger: *Logger,
    comptime fmt: []const u8,
    args: anytype,
    opt_src: ?std.builtin.SourceLocation,
) !void {
    try logger.log(LogLevel.ERROR, fmt, args, opt_src);
}

test "all logs" {
    // Captured rather than printed: a test that writes to the real stderr
    // makes the build runner echo the whole command back as if something
    // had failed, and it asserts nothing beyond "did not crash".
    var buf: [4096]u8 = undefined;
    var capture = std.Io.Writer.fixed(&buf);

    var logger: Logger = undefined;
    logger.init();
    logger.setSink(&capture);

    try logger.warn("Panic in the building {s}", .{"Escape now"}, null);
    try logger.debug("Here are the logs for age {d}", .{24}, null);
    try logger.info("INFO {s}", .{"accessing"}, null);
    try logger.err("ERROR {s}", .{"accessing"}, null);
    try logger.fatal("FATAL {s}", .{"accessing"}, @src());

    const out = buf[0..capture.end];
    for ([_][]const u8{ "WARN", "DEBUG", "INFO", "ERROR", "FATAL" }) |level| {
        try std.testing.expect(std.mem.indexOf(u8, out, level) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, out, "Escape now") != null);
    // `@src()` was passed only to `fatal`, so the location belongs to it.
    try std.testing.expect(std.mem.indexOf(u8, out, "Logger.zig:") != null);

    // Formatting of non-trivial arguments still has to work.
    const vec1: @Vector(5, i32) = .{ 1, 2, 3, 4, 5 };
    const vec2: @Vector(5, i32) = .{ 6, 7, 8, 9, 10 };
    try logger.info("INFO {any}", .{vec1 + vec2}, null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..capture.end], "7") != null);
}
