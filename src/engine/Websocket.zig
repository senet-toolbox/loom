const Client = @import("Client.zig");
const deflate = @import("wss_deflate.zig");

const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;

pub const Opcode = enum(u4) {
    Continuation = 0x0,
    Text = 0x1,
    Binary = 0x2,
    Close = 0x8,
    Ping = 0x9,
    Pong = 0xA,
    _,
};

pub const WsError = error{
    IncompleteFrame,
    ProtocolError,
    PayloadTooLarge,
    InvalidOpcode,
    InvalidUtf8,
    Unsupported,
    DecompressionFailed,
    CompressionFailed,
};

pub const Message = union(enum) {
    Text: []u8,
    Binary: []u8,
    Ping: []u8,
    Pong: []u8,
    Close: struct { code: u16, reason: []u8 },
};

pub const Websocket = @This();
client: *Client,
parser: Parser,
deflate_ctx: ?deflate.DeflateContext,

pub fn init(client: *Client, allocator: Allocator, body_size: usize, deflate_config: ?deflate.DeflateConfig) !Websocket {
    var deflate_ctx: ?deflate.DeflateContext = null;
    if (deflate_config) |config| {
        if (config.enabled) {
            deflate_ctx = deflate.DeflateContext.init(allocator, config);
        }
    }

    return Websocket{
        .client = client,
        .parser = try Parser.init(allocator, 4096, body_size),
        .deflate_ctx = deflate_ctx,
    };
}

pub fn deinit(self: *Websocket) void {
    self.parser.deinit();
    if (self.deflate_ctx) |*ctx| {
        ctx.deinit();
    }
}

/// Incremental parser that can be fed chunks of bytes and will produce complete frames/messages.
pub const Parser = struct {
    buf: []u8,
    storage: []u8,
    write_pos: usize,
    max_message_size: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, capacity: usize, max_message_size: usize) !Parser {
        const storage = try allocator.alloc(u8, capacity);
        return Parser{
            .buf = storage[0..0],
            .storage = storage,
            .write_pos = 0,
            .max_message_size = max_message_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.allocator.free(self.storage);
        self.buf = &[_]u8{};
        self.storage = &[_]u8{};
        self.write_pos = 0;
    }

    pub fn reset(self: *Parser) void {
        self.write_pos = 0;
        self.buf = self.storage[0..self.write_pos];
    }

    pub fn feed(self: *Parser, chunk: []const u8) !void {
        const cap = self.storage.len;
        if (self.write_pos + chunk.len > cap) {
            return WsError.PayloadTooLarge;
        }
        @memcpy(self.storage[self.write_pos .. self.write_pos + chunk.len], chunk);
        self.write_pos += chunk.len;
        self.buf = self.storage[0..self.write_pos];
    }

    /// Parse result includes whether the frame was compressed (RSV1 set)
    pub const ParseResult = struct {
        message: Message,
        was_compressed: bool,
    };

    /// Try to parse a single frame/message. Returns WsError.IncompleteFrame if more bytes required.
    /// Now returns ParseResult which indicates if decompression is needed.
    pub fn nextMessage(self: *Parser, deflate_enabled: bool) !ParseResult {
        var offset: usize = 0;
        if (self.write_pos < 2) return WsError.IncompleteFrame;

        const first = self.buf[0];
        const second = self.buf[1];

        const fin = (first & 0x80) != 0;
        const rsv1 = (first & 0x40) != 0; // Compression flag
        const rsv2 = (first & 0x20) != 0;
        const rsv3 = (first & 0x10) != 0;

        // RSV2 and RSV3 must be 0 (we don't support other extensions)
        if (rsv2 or rsv3) return WsError.ProtocolError;

        // RSV1 is only valid if we negotiated permessage-deflate
        if (rsv1 and !deflate_enabled) return WsError.ProtocolError;

        const opcode_val = first & 0x0F;
        const masked = (second & 0x80) != 0;
        var payload_len_small: u64 = (second & 0x7F);

        offset = 2;

        // Extended lengths
        if (payload_len_small == 126) {
            if (self.write_pos < offset + 2) return WsError.IncompleteFrame;
            payload_len_small = 0;
            for (0..2) |i| {
                payload_len_small = (payload_len_small << 8) | @as(u8, @intCast(self.buf[offset + i]));
            }
            offset += 2;
        } else if (payload_len_small == 127) {
            if (self.write_pos < offset + 8) return WsError.IncompleteFrame;
            payload_len_small = 0;
            for (0..8) |i| {
                payload_len_small = (payload_len_small << 8) | @as(u8, @intCast(self.buf[offset + i]));
            }
            offset += 8;
        }

        // Masking key
        var mask_key: [4]u8 = undefined;
        if (masked) {
            if (self.write_pos < offset + 4) return WsError.IncompleteFrame;
            for (0..4) |i| mask_key[i] = self.buf[offset + i];
            offset += 4;
        }

        const payload_len_usize: usize = @intCast(payload_len_small);
        if (self.write_pos < offset + payload_len_usize) return WsError.IncompleteFrame;

        // Validate opcode
        var opcode: Opcode = undefined;
        switch (opcode_val) {
            0 => opcode = Opcode.Continuation,
            1 => opcode = Opcode.Text,
            2 => opcode = Opcode.Binary,
            8 => opcode = Opcode.Close,
            9 => opcode = Opcode.Ping,
            10 => opcode = Opcode.Pong,
            else => return WsError.InvalidOpcode,
        }

        // Control frames cannot be compressed (RSV1 must be 0 for control frames)
        const is_control = (opcode == Opcode.Close or opcode == Opcode.Ping or opcode == Opcode.Pong);
        if (is_control and rsv1) return WsError.ProtocolError;

        // Control frame rules
        if (is_control and !fin) {
            return WsError.ProtocolError;
        }
        if (is_control and payload_len_usize > 125) {
            return WsError.ProtocolError;
        }

        if (payload_len_usize > self.max_message_size) return WsError.PayloadTooLarge;

        const payload_slice = self.buf[offset .. offset + payload_len_usize];

        // Unmask if needed
        var payload_unmasked: []u8 = undefined;
        if (payload_len_usize == 0) {
            payload_unmasked = &[_]u8{};
        } else {
            payload_unmasked = try self.allocator.alloc(u8, payload_len_usize);
            if (masked) {
                for (payload_slice, 0..) |b, i| {
                    payload_unmasked[i] = b ^ mask_key[i % 4];
                }
            } else {
                @memcpy(payload_unmasked, payload_slice);
            }
        }

        // Advance buffer
        const consumed = offset + payload_len_usize;
        const remaining = self.write_pos - consumed;
        if (remaining > 0) {
            @memcpy(self.storage[0..remaining], self.storage[consumed .. consumed + remaining]);
        }
        self.write_pos = remaining;
        self.buf = self.storage[0..self.write_pos];

        // Build message
        const message: Message = switch (opcode) {
            Opcode.Text => blk: {
                // Note: UTF-8 validation should happen AFTER decompression
                // So we defer validation to the caller
                break :blk Message{ .Text = payload_unmasked };
            },
            Opcode.Binary => Message{ .Binary = payload_unmasked },
            Opcode.Ping => Message{ .Ping = payload_unmasked },
            Opcode.Pong => Message{ .Pong = payload_unmasked },
            Opcode.Close => blk: {
                var code: u16 = 0;
                var reason: []u8 = &[_]u8{};
                if (payload_unmasked.len >= 2) {
                    // Close code is big-endian
                    code = (@as(u16, payload_unmasked[0]) << 8) | @as(u16, payload_unmasked[1]);
                    reason = payload_unmasked[2..];
                } else if (payload_unmasked.len == 1) {
                    self.allocator.free(payload_unmasked);
                    return WsError.ProtocolError;
                }
                break :blk Message{ .Close = .{ .code = code, .reason = reason } };
            },
            Opcode.Continuation => {
                self.allocator.free(payload_unmasked);
                return WsError.Unsupported;
            },
            _ => {
                self.allocator.free(payload_unmasked);
                return WsError.InvalidOpcode;
            },
        };

        return ParseResult{
            .message = message,
            .was_compressed = rsv1,
        };
    }
};

/// Receive and process the next message, handling decompression if needed
pub fn receiveMessage(ws: *Websocket, validate_utf8: bool) !Message {
    const deflate_enabled = if (ws.deflate_ctx) |ctx| ctx.config.enabled else false;
    const result = try ws.parser.nextMessage(deflate_enabled);

    if (result.was_compressed) {
        if (ws.deflate_ctx) |*ctx| {
            // Decompress the payload
            const decompressed = ctx.decompress(switch (result.message) {
                .Text => |data| data,
                .Binary => |data| data,
                else => unreachable, // Control frames can't be compressed
            }) catch return WsError.DecompressionFailed;

            // Free the compressed data
            switch (result.message) {
                .Text => |data| ws.parser.allocator.free(data),
                .Binary => |data| ws.parser.allocator.free(data),
                else => {},
            }

            // Validate UTF-8 after decompression for text messages
            if (result.message == .Text and validate_utf8) {
                if (!std.unicode.utf8ValidateSlice(decompressed)) {
                    ws.parser.allocator.free(decompressed);
                    return WsError.InvalidUtf8;
                }
            }

            return switch (result.message) {
                .Text => Message{ .Text = decompressed },
                .Binary => Message{ .Binary = decompressed },
                else => unreachable,
            };
        }
    }

    // No compression - validate UTF-8 if needed
    if (result.message == .Text and validate_utf8) {
        if (!std.unicode.utf8ValidateSlice(result.message.Text)) {
            ws.parser.allocator.free(result.message.Text);
            return WsError.InvalidUtf8;
        }
    }

    return result.message;
}

/// Send a frame, optionally compressed
fn sendFrameInternal(client: *Client, opcode: Opcode, payload: []const u8, compressed: bool) !void {
    var header: [10]u8 = undefined;
    var i: usize = 0;

    // FIN bit + RSV1 (compression) + opcode
    header[i] = @intFromEnum(opcode); // FIN bit set
    header[i] = header[0] | 0x80;

    if (compressed) {
        header[i] |= 0x40; // Set RSV1
    }
    i += 1;

    // Payload length (server doesn't mask)
    if (payload.len <= 125) {
        header[i] = @intCast(payload.len);
        i += 1;
    } else if (payload.len <= 65535) {
        header[i] = 126;
        i += 1;
        var len_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_bytes, @intCast(payload.len), .big);
        @memcpy(header[i .. i + 2], &len_bytes);
        i += 2;
    } else {
        header[i] = 127;
        i += 1;
        var len_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_bytes, @intCast(payload.len), .big);
        @memcpy(header[i .. i + 8], &len_bytes);
        i += 8;
    }

    // Buffer the small frame header without sending, then write the
    // payload — `write` flushes both header and payload as a single
    // logical message and transparently chunks oversized payloads
    // through `pending` if they don't fit in the writer buffer.
    try client.fillWriteBuffer(header[0..i]);
    try client.write(payload);
}

pub fn sendFrame(client: *Client, opcode: Opcode, payload: []const u8) !void {
    try sendFrameInternal(client, opcode, payload, false);
}

pub fn sendText(ws: *Websocket, payload: []const u8) !void {
    // if (ws.deflate_ctx) |*ctx| {
    //     if (ctx.config.enabled and payload.len > 0) {
    //         const compressed = ctx.compress(payload) catch return WsError.CompressionFailed;
    //         defer ctx.allocator.free(compressed);
    //         try sendFrameInternal(ws.client, Opcode.Text, compressed, true);
    //         return;
    //     }
    // }
    try sendFrameInternal(ws.client, Opcode.Text, payload, false);
}

pub fn sendBinary(ws: *Websocket, payload: []const u8) !void {
    if (ws.deflate_ctx) |*ctx| {
        if (ctx.config.enabled and payload.len > 0) {
            const compressed = ctx.compress(payload) catch return WsError.CompressionFailed;
            defer ctx.allocator.free(compressed);
            try sendFrameInternal(ws.client, Opcode.Binary, compressed, true);
            return;
        }
    }
    try sendFrameInternal(ws.client, Opcode.Binary, payload, false);
}

/// Send text without compression (useful for small messages where compression overhead isn't worth it)
pub fn sendTextUncompressed(ws: *Websocket, payload: []const u8) !void {
    try sendFrameInternal(ws.client, Opcode.Text, payload, false);
}

pub fn sendPing(ws: *Websocket, payload: []const u8) !void {
    if (payload.len > 125) return WsError.PayloadTooLarge;
    try sendFrameInternal(ws.client, Opcode.Ping, payload, false);
}

pub fn sendPong(ws: *Websocket, payload: []const u8) !void {
    if (payload.len > 125) return WsError.PayloadTooLarge;
    try sendFrameInternal(ws.client, Opcode.Pong, payload, false);
}

pub fn sendClose(ws: *Websocket, code: u16, reason: []const u8) !void {
    const total_len = 2 + reason.len;
    var buf = try std.heap.c_allocator.alloc(u8, total_len);
    defer std.heap.c_allocator.free(buf);

    buf[0] = @intCast((code >> 8) & 0xFF);
    buf[1] = @intCast(code & 0xFF);
    @memcpy(buf[2..], reason);

    try sendFrameInternal(ws.client, Opcode.Close, buf, false);
}

/// Example of how to handle WebSocket upgrade with permessage-deflate negotiation
/// This would be integrated into your HTTP request handler
pub const HandshakeResult = struct {
    accept_key: [28]u8, // Base64-encoded SHA1 hash
    deflate_config: ?deflate.DeflateConfig,
};

/// Parse WebSocket upgrade request and prepare response
/// Returns the Sec-WebSocket-Accept value and deflate config if negotiated
pub fn handleUpgrade(
    websocket_key: []const u8,
    extensions_header: ?[]const u8,
) !HandshakeResult {
    // Calculate Sec-WebSocket-Accept
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(websocket_key);
    hasher.update(magic);
    const hash = hasher.finalResult();

    var accept_key: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept_key, &hash);

    // Check for permessage-deflate extension
    var deflate_config: ?deflate.DeflateConfig = null;
    if (extensions_header) |ext_header| {
        deflate_config = deflate.parseExtensionHeader(ext_header);
        // You can modify the config here if you want to enforce certain options
        // For example, always require no_context_takeover for memory efficiency:
        if (deflate_config) |*config| {
            config.server_no_context_takeover = true;
            config.client_no_context_takeover = true;
        }
    }

    return HandshakeResult{
        .accept_key = accept_key,
        .deflate_config = deflate_config,
    };
}

/// Build the HTTP 101 Switching Protocols response
pub fn buildUpgradeResponse(
    result: HandshakeResult,
    buffer: []u8,
) ![]u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("HTTP/1.1 101 Switching Protocols\r\n");
    try writer.writeAll("Upgrade: websocket\r\n");
    try writer.writeAll("Connection: Upgrade\r\n");
    try writer.writeAll("Sec-WebSocket-Accept: ");
    try writer.writeAll(&result.accept_key);
    try writer.writeAll("\r\n");

    // Add extension header if deflate was negotiated
    if (result.deflate_config) |config| {
        if (config.enabled) {
            try writer.writeAll("Sec-WebSocket-Extensions: ");
            try writer.writeAll(deflate.buildExtensionResponse(config));
            try writer.writeAll("\r\n");
        }
    }

    try writer.writeAll("\r\n");

    return writer.buffered();
}

/// Example usage in your server's connection handler
pub fn exampleUsage() !void {
    // This is pseudo-code showing how it fits together

    // 1. Parse incoming HTTP request headers
    const websocket_key = "dGhlIHNhbXBsZSBub25jZQ=="; // From Sec-WebSocket-Key header
    const extensions = "permessage-deflate; client_max_window_bits"; // From Sec-WebSocket-Extensions

    // 2. Handle the upgrade
    const result = try handleUpgrade(websocket_key, extensions);

    // 3. Send response
    var response_buf: [512]u8 = undefined;
    const response = try buildUpgradeResponse(result, &response_buf);
    _ = response;
    // send(response) to client

    // 4. Create WebSocket with deflate context
    // const ws = try Websocket.init(client, allocator, max_size, result.deflate_config);

    // 5. Now you can send/receive compressed messages
    // const msg = try ws.receiveMessage(true);
    // try ws.sendText("Hello compressed world!");
}

test "handshake with deflate" {
    const result = try handleUpgrade(
        "dGhlIHNhbXBsZSBub25jZQ==",
        "permessage-deflate; client_max_window_bits",
    );

    try std.testing.expect(result.deflate_config != null);
    try std.testing.expect(result.deflate_config.?.enabled);

    var buf: [512]u8 = undefined;
    const response = try buildUpgradeResponse(result, &buf);

    // Should contain the extension header
    try std.testing.expect(std.mem.indexOf(u8, response, "Sec-WebSocket-Extensions:") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "permessage-deflate") != null);
}

test "handshake without deflate" {
    const result = try handleUpgrade(
        "dGhlIHNhbXBsZSBub25jZQ==",
        null,
    );

    try std.testing.expect(result.deflate_config == null);

    var buf: [512]u8 = undefined;
    const response = try buildUpgradeResponse(result, &buf);

    // Should NOT contain extension header
    try std.testing.expect(std.mem.indexOf(u8, response, "Sec-WebSocket-Extensions:") == null);
}

// // TODO figure what the hell is wrong with struct fields set to []const u8,
// // but then to store it it needs to a []u8 field and then to stringify the struct field needs to []const u8
// /// This function takes the Struct Type and outputs the parsed json payload into the struct.
// ///
// /// # Parameters:
// /// - `Context`: *Context.
// /// - `T`: StructType.
// /// - `value`: *T.
// ///
// /// # Returns:
// /// Struct.
// ///
// /// # Example:
// /// try ctx.bind(CredentialsReq)
// /// # Returns:
// /// CredentialsReq { name: "Vic", password: "password" }.
// pub fn bind(self: *Websocket, comptime T: type, value: *T) !void {
//     // assert_cm(@intFromEnum(self.content_type) == @intFromEnum(helpers.ContentType.JSON), "Http Payload must be JSON to Bind");
//     const fields = @typeInfo(T).@"struct".fields;
//     // print("{s}\n", .{self.payload[0..self.content_length]});
//     var parsed = std.json.parseFromSlice(
//         T,
//         self.arena,
//         self.payload[0..self.content_length],
//         .{},
//     ) catch return error.MalformedJson;
//
//     // we need to parse the struct []const u8 into []u8 to store in the hashmap
//     inline for (fields) |f| {
//         if (f.type == []const u8) {
//             const field_value = @field(parsed.value, f.name);
//             @field(parsed.value, f.name) = try helpers.convertStringToSlice(field_value, std.heap.c_allocator);
//         }
//     }
//     value.* = parsed.value;
// }
//
// pub fn convertStringToSlice(haystack: []const u8, allocator: std.mem.Allocator) ![]u8 {
//     const mutable_slice = try allocator.dupe(u8, haystack);
//     return mutable_slice;
// }
