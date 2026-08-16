//! WebSocket 帧编解码 — RFC 6455 §5
//!
//! 帧格式（比特布局）：
//! ```text
//!  0                   1                   2                   3
//!  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
//! +-+-+-+-+-------+-+-------------+-------------------------------+
//! |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
//! |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
//! |N|V|V|V|       |S|             |   (if payload len==126/127)   |
//! | |1|2|3|       |K|             |                               |
//! +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
//! |     Extended payload length continued, if payload len == 127  |
//! + - - - - - - - - - - - - - - - +-------------------------------+
//! |                               |Masking-key, if MASK set to 1  |
//! +-------------------------------+ - - - - - - - - - - - - - - - +
//! |    Masking-key (continued)    |          Payload Data         |
//! +-------------------------------- - - - - - - - - - - - - - - - +
//! :                     Payload Data continued ...                :
//! + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
//! |                     Payload Data continued ...                |
//! +---------------------------------------------------------------+
//! ```
//!
//! # 设计决策
//!
//! - 编码/解码操作于抽象的 `std.Io.Reader` / `std.Io.Writer`（不绑死 socket），
//!   让帧层可以脱离网络层做单元测试（用 fixed buffer）。
//! - `Frame` 持有 payload 切片（解码时由调用方提供 allocator），不持有 reader。
//!   这避免了"读完帧后 reader 缓冲被下一帧覆盖"的 use-after-free 陷阱。
//! - mask/unmask 用 XOR 循环，4 字节 key 周期循环。RFC 要求"客户端→服务端"
//!   的帧必须 masked；"服务端→客户端"的帧必须 NOT masked。本模块两端都能用，
//!   mask 标志位由调用方决定，编解码不做强制校验——把策略留给上层。

const std = @import("std");

/// WebSocket 操作码 — RFC 6455 §5.2
///
/// 4 bit 字段。高 bit (0x8) 在协议里是保留位，这里不用。
/// `reserved_*` 是 RFC 定义的进一步控制帧保留，未启用。
pub const OpCode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    /// 0x3-0x7 保留给未来的非控制帧
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    /// 0xB-0xF 保留给未来的控制帧
    _,

    /// 控制帧（ping/pong/close）的 payload 不得超过 125 字节，
    /// 且不可分片（必须 fin=1）。这里给上层一个判断辅助。
    pub fn isControl(self: OpCode) bool {
        const v = @backingInt(self);
        return v >= 0x8;
    }

    /// 数据帧（continuation/text/binary）。控制帧之外的都是数据帧。
    pub fn isData(self: OpCode) bool {
        return !self.isControl();
    }
};

/// 解析后的帧视图。payload 切片指向解码时分配的缓冲（不指向 reader 内部缓冲）。
pub const Frame = struct {
    /// FIN 位：1 = 这是一个 message 的最后一个分片。
    fin: bool,
    /// 3 个 RSV 位（RFC 保留给扩展，如 permessage-deflate）。默认 0。
    rsv1: bool = false,
    rsv2: bool = false,
    rsv3: bool = false,
    opcode: OpCode,
    /// 是否被 mask 过。客户端→服务端必须 true。
    mask: bool,
    /// 解码后已经 unmask 的 payload（mask=false 时是原始 payload）。
    /// 编码后的 Frame（encode 入参）也用这个字段表示"要发送的 payload"。
    payload: []u8,
    /// mask key（mask=true 时有效）。解码时存原 4 字节，编码时也用它做 mask。
    masking_key: [4]u8 = .{ 0, 0, 0, 0 },
};

/// payload 长度的三种编码档位（RFC §5.2 的 Payload len 字段）：
/// - 0..125: 7-bit 直接编码
/// - 126: 后跟 2 字节 16-bit 长度（big endian）
/// - 127: 后跟 8 字节 64-bit 长度（big endian）
const LEN_16_BIT: u8 = 126;
const LEN_64_BIT: u8 = 127;
const MAX_16_BIT: usize = 65535;

/// 把 payload 长度编码进首字节 + 扩展长度字段。
/// mask 为 true 时后续会写 4 字节 mask key（由调用方提供）。
pub fn encode(
    writer: *std.Io.Writer,
    opcode: OpCode,
    payload: []const u8,
    mask: bool,
    /// mask=true 时必须是 4 字节 key；mask=false 时被忽略。
    masking_key: [4]u8,
) !void {
    // 控制帧 payload 上限 125——这是协议约束，不是实现细节。
    // 这里只警告不强制 panic：上层 handshake/sendText 等不会触发。
    // 直接调用 encode 写超长 ping 是调用方 bug，但我们是 lib 不该 abort。
    if (opcode.isControl() and payload.len > 125) {
        return error.ControlFramePayloadTooLong;
    }

    const fin: u8 = 0x80; // FIN=1, 我们 encode 的总是完整帧（不分片场景由上层处理）
    const first: u8 = fin | @as(u8, @backingInt(opcode));
    // 注意：RFC §5.2 中 MASK 位在 *第二个* 字节（length 字节）的 bit 7，
    // 不是 first 字节。first 字节是 FIN/RSV/opcode。
    try writer.writeByte(first);

    // payload 长度档位选择——mask 位与 7-bit 长度共用 second 字节
    const len: u64 = payload.len;
    const mask_flag: u8 = if (mask) 0x80 else 0;
    if (len <= 125) {
        try writer.writeByte(mask_flag | @as(u8, @intCast(len)));
    } else if (len <= MAX_16_BIT) {
        try writer.writeByte(mask_flag | LEN_16_BIT);
        try writer.writeInt(u16, @intCast(len), .big);
    } else {
        try writer.writeByte(mask_flag | LEN_64_BIT);
        try writer.writeInt(u64, len, .big);
    }

    // mask key（如果 mask=true）
    if (mask) {
        try writer.writeAll(&masking_key);
        // mask 与 payload 一起写——payload 要被 XOR 过
        // RFC §5.3: transformed_payload = original XOR(i mod 4)
        var i: usize = 0;
        while (i < payload.len) : (i += 1) {
            try writer.writeByte(payload[i] ^ masking_key[i & 3]);
        }
    } else {
        try writer.writeAll(payload);
    }
}

/// 从 reader 读一帧并解码。
///
/// `allocator` 用于分配 payload 缓冲——解码后 payload 是独立 owned 内存，
/// 不依赖 reader 的内部缓冲，调用方负责 free。
///
/// 解码出的 payload 已经 unmask（mask=true 的情况下 XOR 还原）。
pub fn decode(reader: *std.Io.Reader, allocator: std.mem.Allocator) !Frame {
    const first = try reader.takeByte();
    const fin = (first & 0x80) != 0;
    const rsv1 = (first & 0x40) != 0;
    const rsv2 = (first & 0x20) != 0;
    const rsv3 = (first & 0x10) != 0;
    const opcode_raw: u4 = @truncate(first & 0x0F);
    const opcode: OpCode = @fromBackingInt(@intCast(opcode_raw));

    const second = try reader.takeByte();
    const mask = (second & 0x80) != 0;
    const len7: u8 = second & 0x7F;

    // 扩展长度档位解码
    const payload_len: u64 = switch (len7) {
        LEN_16_BIT => blk: {
            const v = try reader.takeInt(u16, .big);
            break :blk @intCast(v);
        },
        LEN_64_BIT => blk: {
            const v = try reader.takeInt(u64, .big);
            // RFC §5.5: 控制帧 payload 上限 125，但通用长度字段理论允许更大。
            // 高 bit 在 64-bit 长度里必须为 0（RFC），这里不校验，留给上层。
            break :blk v;
        },
        else => len7,
    };

    // 控制帧长度上限校验（协议硬约束）
    if (opcode.isControl() and payload_len > 125) {
        return error.ControlFramePayloadTooLong;
    }

    // mask key
    var masking_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (mask) {
        const key_bytes = try reader.takeArray(4);
        masking_key = key_bytes.*;
    }

    // 分配 payload 缓冲——独立 owned，不指向 reader 内部缓冲。
    const buf = try allocator.alloc(u8, @intCast(payload_len));
    errdefer allocator.free(buf);
    if (payload_len > 0) {
        try reader.readSliceAll(buf);
        if (mask) {
            // unmask: payload[i] ^= key[i mod 4]
            var i: usize = 0;
            while (i < buf.len) : (i += 1) {
                buf[i] ^= masking_key[i & 3];
            }
        }
    }

    return .{
        .fin = fin,
        .rsv1 = rsv1,
        .rsv2 = rsv2,
        .rsv3 = rsv3,
        .opcode = opcode,
        .mask = mask,
        .payload = buf,
        .masking_key = masking_key,
    };
}

/// 用一个 mask key 做就地 XOR 掩码/去掩码（两者操作相同）。
/// 公开给上层（如客户端模式发送前 mask）使用。
pub fn applyMask(payload: []u8, key: [4]u8) void {
    var i: usize = 0;
    while (i < payload.len) : (i += 1) {
        payload[i] ^= key[i & 3];
    }
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "encode then decode roundtrip — short unmasked text" {
    // 服务端→客户端：mask=false
    var out_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    try encode(&w, .text, "hello", false, .{ 0, 0, 0, 0 });
    const written = w.buffered();

    var r: std.Io.Reader = .fixed(written);
    const f = try decode(&r, testing.allocator);
    defer testing.allocator.free(f.payload);

    try testing.expect(f.fin);
    try testing.expect(!f.mask);
    try testing.expectEqual(OpCode.text, f.opcode);
    try testing.expectEqualStrings("hello", f.payload);
}

test "encode then decode roundtrip — masked binary (client→server)" {
    // 客户端→服务端：mask=true
    const payload = "binary-data-1234";
    var out_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    const key: [4]u8 = .{ 0x37, 0xfa, 0x21, 0xd9 };
    try encode(&w, .binary, payload, true, key);
    const written = w.buffered();

    var r: std.Io.Reader = .fixed(written);
    const f = try decode(&r, testing.allocator);
    defer testing.allocator.free(f.payload);

    try testing.expect(f.mask);
    try testing.expectEqual(OpCode.binary, f.opcode);
    try testing.expectEqualStrings(payload, f.payload);
}

test "encode uses 16-bit length encoding for 126-byte payload" {
    // payload 长度刚好 126（触发 16-bit 扩展字段）
    var payload: [126]u8 = @splat(0x41);
    var out_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    try encode(&w, .text, &payload, false, .{ 0, 0, 0, 0 });
    const written = w.buffered();

    // 第一字节 FIN+text = 0x81；第二字节 = 126；后两字节 big endian 长度
    try testing.expectEqual(@as(u8, 0x81), written[0]);
    try testing.expectEqual(@as(u8, 126), written[1]);
    try testing.expectEqual(@as(u8, 0), written[2]); // 126 = 0x00 0x7E big endian
    try testing.expectEqual(@as(u8, 126), written[3]);

    var r: std.Io.Reader = .fixed(written);
    const f = try decode(&r, testing.allocator);
    defer testing.allocator.free(f.payload);
    try testing.expectEqual(@as(usize, 126), f.payload.len);
}

test "encode uses 64-bit length encoding for >65535 byte payload" {
    const allocator = testing.allocator;
    const big = try allocator.alloc(u8, 70000);
    defer allocator.free(big);
    @memset(big, 0x42);

    // 用 Allocating writer，不知道输出多大
    var w: std.Io.Writer.Allocating = .init(allocator);
    defer w.deinit();
    try encode(&w.writer, .binary, big, false, .{ 0, 0, 0, 0 });
    const written = w.written();

    try testing.expectEqual(@as(u8, 0x82), written[0]); // FIN + binary
    try testing.expectEqual(@as(u8, 127), written[1]); // 64-bit marker

    var r: std.Io.Reader = .fixed(written);
    const f = try decode(&r, allocator);
    defer allocator.free(f.payload);
    try testing.expectEqual(@as(usize, 70000), f.payload.len);
}

test "close frame encodes and decodes" {
    var out_buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    try encode(&w, .close, "", false, .{ 0, 0, 0, 0 });
    const written = w.buffered();

    var r: std.Io.Reader = .fixed(written);
    const f = try decode(&r, testing.allocator);
    defer testing.allocator.free(f.payload);

    try testing.expectEqual(OpCode.close, f.opcode);
    try testing.expectEqual(@as(usize, 0), f.payload.len);
}

test "ping/pong are control frames" {
    try testing.expect(OpCode.ping.isControl());
    try testing.expect(OpCode.pong.isControl());
    try testing.expect(OpCode.close.isControl());
    try testing.expect(!OpCode.text.isControl());
    try testing.expect(!OpCode.binary.isControl());
    try testing.expect(!OpCode.continuation.isControl());
}

test "control frame payload over 125 is rejected" {
    var out_buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    const big: [126]u8 = @splat(0);
    // 直接 encode 应报错
    const err = encode(&w, .ping, &big, false, .{ 0, 0, 0, 0 });
    try testing.expectError(error.ControlFramePayloadTooLong, err);
}

test "applyMask is its own inverse" {
    var data = [_]u8{ 1, 2, 3, 4, 5, 6, 7 };
    const key: [4]u8 = .{ 0xAA, 0xBB, 0xCC, 0xDD };
    const original = data;
    applyMask(&data, key);
    try testing.expect(!std.mem.eql(u8, &original, &data));
    applyMask(&data, key);
    try testing.expectEqualSlices(u8, &original, &data);
}

test "decode empty payload frame" {
    var out_buf: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    try encode(&w, .ping, "", true, .{ 0x12, 0x34, 0x56, 0x78 });
    const written = w.buffered();

    var r: std.Io.Reader = .fixed(written);
    const f = try decode(&r, testing.allocator);
    defer testing.allocator.free(f.payload);
    try testing.expectEqual(@as(usize, 0), f.payload.len);
    try testing.expect(f.mask);
    try testing.expectEqual(@as(u8, 0x12), f.masking_key[0]);
}

test {
    std.testing.refAllDecls(@This());
}
