const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const Io = std.Io;
const Writer = Io.Writer;

pub const DeflateError = error{
    DecompressionFailed,
    CompressionFailed,
    InvalidData,
    OutOfMemory,
    WriteFailed,
};

/// Configuration for permessage-deflate extension
pub const DeflateConfig = struct {
    /// Whether compression is enabled for this connection
    enabled: bool = false,
    /// server_no_context_takeover: if true, server decompression context is reset after each message
    server_no_context_takeover: bool = true,
    /// client_no_context_takeover: if true, client decompression context is reset after each message
    client_no_context_takeover: bool = true,
    /// server_max_window_bits (8-15, default 15)
    server_max_window_bits: u4 = 15,
    /// client_max_window_bits (8-15, default 15)
    client_max_window_bits: u4 = 15,
};

/// Parse Sec-WebSocket-Extensions header for permessage-deflate
pub fn parseExtensionHeader(header: []const u8) ?DeflateConfig {
    if (std.mem.indexOf(u8, header, "permessage-deflate") == null) {
        return null;
    }

    var config = DeflateConfig{ .enabled = true };

    if (std.mem.indexOf(u8, header, "server_no_context_takeover") != null) {
        config.server_no_context_takeover = true;
    }
    if (std.mem.indexOf(u8, header, "client_no_context_takeover") != null) {
        config.client_no_context_takeover = true;
    }

    if (std.mem.indexOf(u8, header, "server_max_window_bits=")) |idx| {
        const start = idx + "server_max_window_bits=".len;
        if (parseWindowBits(header[start..])) |b| config.server_max_window_bits = b;
    }

    if (std.mem.indexOf(u8, header, "client_max_window_bits=")) |idx| {
        const start = idx + "client_max_window_bits=".len;
        if (parseWindowBits(header[start..])) |b| config.client_max_window_bits = b;
    }

    return config;
}

fn parseWindowBits(s: []const u8) ?u4 {
    var end: usize = 0;
    while (end < s.len and s[end] >= '0' and s[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    const val = std.fmt.parseInt(u4, s[0..end], 10) catch return null;
    if (val < 8 or val > 15) return null;
    return val;
}

/// Build the Sec-WebSocket-Extensions response header value
pub fn buildExtensionResponse(config: DeflateConfig) []const u8 {
    if (!config.enabled) return "";

    if (config.server_no_context_takeover and config.client_no_context_takeover) {
        return "permessage-deflate; server_no_context_takeover; client_no_context_takeover";
    } else if (config.server_no_context_takeover) {
        return "permessage-deflate; server_no_context_takeover";
    } else if (config.client_no_context_takeover) {
        return "permessage-deflate; client_no_context_takeover";
    }
    return "permessage-deflate";
}

/// Handles compression/decompression for WebSocket permessage-deflate
pub const DeflateContext = struct {
    config: DeflateConfig,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: DeflateConfig) DeflateContext {
        return DeflateContext{
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DeflateContext) void {
        _ = self;
    }

    /// Decompress a WebSocket payload (when RSV1 is set)
    /// Per RFC 7692, we need to append 0x00 0x00 0xff 0xff before decompressing
    pub fn decompress(self: *DeflateContext, compressed: []const u8) ![]u8 {
        // Append the DEFLATE tail that's stripped in WebSocket frames
        const tail = [_]u8{ 0x00, 0x00, 0xff, 0xff };
        const input_len = compressed.len + tail.len;
        const input = try self.allocator.alloc(u8, input_len);
        defer self.allocator.free(input);

        @memcpy(input[0..compressed.len], compressed);
        @memcpy(input[compressed.len..], &tail);

        // Output list
        var output = std.array_list.Managed(u8).init(self.allocator);
        errdefer output.deinit();

        // Create reader from input
        var in_reader: Io.Reader = .fixed(input);

        // Window buffer for decompression
        var window_buf: [flate.max_window_len]u8 = undefined;

        // Initialize decompressor for raw deflate (no zlib/gzip header)
        var decompressor: flate.Decompress = .init(&in_reader, .raw, &window_buf);

        // Read all decompressed data using the reader interface
        while (true) {
            const chunk = decompressor.reader.peekGreedy(4096) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return DeflateError.DecompressionFailed,
            };
            if (chunk.len == 0) break;
            try output.appendSlice(chunk);
            decompressor.reader.toss(chunk.len);
        }

        return output.toOwnedSlice();
    }

    /// Compress a WebSocket payload (for sending with RSV1 set)
    /// Per RFC 7692, we strip the trailing 0x00 0x00 0xff 0xff
    ///
    /// Uses flate.Compress which requires:
    /// - output: *Writer with capacity >= 8 bytes
    /// - buffer: []u8 of at least flate.max_window_len
    /// - container: .raw for WebSocket (no zlib/gzip wrapper)
    /// - opts: compression options (default is level 6)
    pub fn compress(self: *DeflateContext, uncompressed: []const u8) ![]u8 {
        const max_output = uncompressed.len + 128 + (uncompressed.len / 100);
        var output_storage = try self.allocator.alloc(u8, max_output);
        defer self.allocator.free(output_storage);

        var out_writer: Writer = .fixed(output_storage);

        // Use a buffer for the Simple compressor
        // Note: store blocks are limited to 65535 bytes
        var compress_buf: [65535]u8 = undefined;

        // Use Simple with huffman strategy instead of full Compress
        var compressor = flate.Compress.Simple.init(
            &out_writer,
            &compress_buf,
            .raw, // container
            .huffman, // strategy - use huffman encoding
        ) catch return DeflateError.CompressionFailed;

        // Copy data into buffer and flush
        const chunk_size = compress_buf.len;
        var offset: usize = 0;
        while (offset < uncompressed.len) {
            const remaining = uncompressed.len - offset;
            const to_copy = @min(remaining, chunk_size - compressor.wp);

            @memcpy(compressor.buffer[compressor.wp..][0..to_copy], uncompressed[offset..][0..to_copy]);
            compressor.wp += to_copy;
            offset += to_copy;

            // Flush buffer if full and more data to come
            if (compressor.wp == chunk_size and offset < uncompressed.len) {
                compressor.flush() catch return DeflateError.CompressionFailed;
            }
        }

        // Finish compression
        compressor.finish() catch return DeflateError.CompressionFailed;

        // Get the compressed output
        const compressed_len = out_writer.end;
        std.debug.print("Compressed len: {}\n", .{compressed_len});

        const compressed = output_storage[0..compressed_len];

        // Copy result and strip trailing 0x00 0x00 0xff 0xff per RFC 7692
        const tail = [_]u8{ 0x00, 0x00, 0xff, 0xff };
        const final_len = if (compressed_len >= 4 and
            std.mem.eql(u8, compressed[compressed_len - 4 ..], &tail))
            compressed_len - 4
        else
            compressed_len;

        const result = try self.allocator.alloc(u8, final_len);
        @memcpy(result, compressed[0..final_len]);
        return result;
    }
};

test "parse extension header" {
    const header1 = "permessage-deflate; client_max_window_bits";
    const config1 = parseExtensionHeader(header1);
    try std.testing.expect(config1 != null);
    try std.testing.expect(config1.?.enabled);

    const header2 = "permessage-deflate; server_no_context_takeover; client_no_context_takeover";
    const config2 = parseExtensionHeader(header2);
    try std.testing.expect(config2 != null);
    try std.testing.expect(config2.?.server_no_context_takeover);
    try std.testing.expect(config2.?.client_no_context_takeover);

    const header3 = "some-other-extension";
    const config3 = parseExtensionHeader(header3);
    try std.testing.expect(config3 == null);
}

test "roundtrip compress decompress" {
    const allocator = std.testing.allocator;
    var ctx = DeflateContext.init(allocator, .{ .enabled = true });
    defer ctx.deinit();

    const original = "Hello, WebSocket compression! This is a test message that should compress well because it has some repetition. repetition. repetition.";

    const compressed = try ctx.compress(original);
    defer allocator.free(compressed);

    const decompressed = try ctx.decompress(compressed);
    defer allocator.free(decompressed);

    try std.testing.expectEqualStrings(original, decompressed);
}
