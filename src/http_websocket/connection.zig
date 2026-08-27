//! WebSocket 连接 — 帧读写的高级 API
//!
//! 包装底层 `std.Io.Reader` / `std.Io.Writer`，提供 message 级别的 API：
//! - `sendText` / `sendBinary`：发送一个完整 message（FIN=1）
//! - `receive`：阻塞读一个 message，自动处理分片与 ping/pong 控制帧
//! - `ping` / `pong`：主动发送控制帧
//! - `close`：发送 close 帧（带状态码 + 原因）
//!
//! # 服务端 vs 客户端
//!
//! 服务端发送的帧必须 NOT masked（RFC §5.1），客户端→服务端必须 masked。
//! `WebSocket` 结构带一个 `is_client` 标志决定 encode 时的 mask 策略。
//! 服务端模式（默认）：发送不 mask，接收期望对方 mask（decode 自动 unmask）。
//!
//! # 自动 ping/pong 处理
//!
//! `receive` 在读到 ping 帧时自动回 pong（RFC §5.5.2 要求），
//! 读到 close 帧时自动回 close（RFC §7.1.2 关闭握手）。
//! 这些控制帧不会作为 Message 返回给调用方——调用方只看到数据 message。
//!
//! # 分片（continuation）
//!
//! 一个 message 可能被分成多个帧：首帧 opcode=text/binary FIN=0，
//! 后续帧 opcode=continuation FIN=0，末帧 FIN=1。
//! `receive` 会把所有分片的 payload 拼到一个 buffer 里，最后才返回。
//! 拼接用 `ArrayList` 按需增长——控制帧（ping/pong/close）可以插在分片中间，
//! RFC §5.4 允许。

const std = @import("std");
const frame_mod = @import("frame.zig");

pub const Frame = frame_mod.Frame;
pub const OpCode = frame_mod.OpCode;

/// 一个完整的 WebSocket message（分片已拼合）。
/// `payload` 是 reader.allocator 分配的 owned 内存，调用方负责通过
/// `Message.deinit` 释放（或用同一个 allocator free）。
pub const Message = struct {
    opcode: OpCode,
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Message) void {
        self.allocator.free(self.payload);
    }
};

/// WebSocket 关闭状态码 — RFC §7.4
pub const CloseCode = enum(u16) {
    normal_closure = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    no_status_received = 1005,
    abnormal_closure = 1006,
    invalid_frame_payload_data = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    mandatory_extension = 1010,
    internal_server_error = 1011,
    _,
};

/// 高级 WebSocket 连接。持有 reader/writer 和一个 allocator（用于 payload）。
///
/// 生命周期：调用方在握手成功、底层 stream 劫持后构造本对象。
/// 帧编解码完全通过 reader/writer 抽象，不依赖具体 stream 类型。
pub const WebSocket = struct {
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
    /// true = 客户端模式（发送时 mask payload）。
    is_client: bool = false,
    /// 已发送/收到 close 帧——避免重复发送。
    closed: bool = false,
    /// 单帧 payload 上限（修复 E1）。
    max_frame_payload: usize = frame_mod.DEFAULT_MAX_PAYLOAD,
    /// 分片拼接后的单个 message 总大小上限（修复 E2）。
    max_message_size: usize = frame_mod.DEFAULT_MAX_PAYLOAD,
    /// 客户端 mask key 递增计数器（无 io 时的退化派生用）。
    mask_counter: u64 = 0,
    /// 密码学熵源。客户端模式下 RFC 6455 §5.3 要求每帧 mask key **不可预测**
    /// （否则经过代理时可做缓存投毒）。设了 io 就用 `std.Io.randomSecure`。
    /// 为 null 时退化成计数器派生 —— 仅可用于单元测试，不要用于真实客户端。
    io: ?std.Io = null,

    const Self = @This();

    /// 服务端模式构造（发送不 mask）。
    pub fn initServer(reader: *std.Io.Reader, writer: *std.Io.Writer, allocator: std.mem.Allocator) Self {
        return .{ .reader = reader, .writer = writer, .allocator = allocator };
    }

    /// 客户端模式构造（发送时 mask）。
    ///
    /// **注意**：没有 io 就没有密码学熵源，mask key 退化成计数器派生（可预测）。
    /// RFC 6455 §5.3 要求客户端每帧用不可预测的 mask key（防代理缓存投毒），
    /// 真实客户端请用 `initClientSecure`。本构造函数保留给单元测试（可重现）。
    pub fn initClient(reader: *std.Io.Reader, writer: *std.Io.Writer, allocator: std.mem.Allocator) Self {
        return .{ .reader = reader, .writer = writer, .allocator = allocator, .is_client = true };
    }

    /// 客户端模式构造（带密码学熵源）。mask key 用 `std.Io.randomSecure` 生成。
    pub fn initClientSecure(
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        allocator: std.mem.Allocator,
        io: std.Io,
    ) Self {
        return .{
            .reader = reader,
            .writer = writer,
            .allocator = allocator,
            .is_client = true,
            .io = io,
        };
    }

    /// 发送一个 text message（完整帧，FIN=1）。
    pub fn sendText(self: *Self, message: []const u8) !void {
        try self.send(.text, message);
    }

    /// 发送一个 binary message。
    pub fn sendBinary(self: *Self, message: []const u8) !void {
        try self.send(.binary, message);
    }

    /// 内部发送：按 is_client 决定 mask，写完立即 flush。
    ///
    /// **flush 不是可选的**：self.writer 是带缓冲的 socket writer（生产里是 zio
    /// stream writer，默认 8KB 缓冲）。只 encode 不 flush 的话帧会一直卡在缓冲区，
    /// 对端在缓冲填满前收不到任何东西 —— echo/推送场景表现为「WebSocket 毫无反应」。
    fn send(self: *Self, opcode: OpCode, payload: []const u8) !void {
        if (self.is_client) {
            // RFC 6455 §5.3: 客户端每帧必须用不可预测的随机 mask key，
            // 防经过代理时的缓存投毒攻击。
            var key: [4]u8 = undefined;
            if (self.io) |io| {
                try std.Io.randomSecure(io, &key);
            } else {
                // 无熵源的退化路径（仅单元测试会走到，initClientSecure 才是生产用法）。
                self.mask_counter +%= 1;
                var seed: [16]u8 = undefined;
                std.mem.writeInt(u64, seed[0..8], self.mask_counter, .little);
                std.mem.writeInt(u64, seed[8..16], @intFromPtr(self), .little);
                const h = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, &seed);
                std.mem.writeInt(u32, &key, @truncate(h), .little);
            }
            try frame_mod.encode(self.writer, opcode, payload, true, key);
        } else {
            try frame_mod.encode(self.writer, opcode, payload, false, .{ 0, 0, 0, 0 });
        }
        try self.writer.flush();
    }

    /// 用指定数字状态码发送 close 帧（内部用,不做 CloseCode enum 约束）。
    fn closeWithCode(self: *Self, code: u16) !void {
        if (self.closed) return;
        self.closed = true;
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, code, .big);
        try self.send(.close, &buf);
    }

    /// 发送 ping（控制帧，payload ≤ 125）。
    pub fn ping(self: *Self, payload: []const u8) !void {
        if (payload.len > 125) return error.ControlFramePayloadTooLong;
        try self.send(.ping, payload);
    }

    /// 发送 pong（控制帧，payload ≤ 125）。通常自动回复 ping，无需手动调。
    pub fn pong(self: *Self, payload: []const u8) !void {
        if (payload.len > 125) return error.ControlFramePayloadTooLong;
        try self.send(.pong, payload);
    }

    /// 发送 close 帧。`code` 是 RFC §7.4 状态码，`reason` 是可读关闭原因。
    /// payload 格式：2 字节状态码（big endian）+ reason UTF-8。
    pub fn close(self: *Self, code: CloseCode, reason: []const u8) !void {
        if (self.closed) return; // 关闭握手已发起，幂等返回
        self.closed = true;

        // close payload = code(2) + reason；控制帧上限 125，减去 2 字节 code 后 reason ≤ 123
        var buf: [125]u8 = undefined;
        if (reason.len > 123) return error.ControlFramePayloadTooLong;
        std.mem.writeInt(u16, buf[0..2], @backingInt(code), .big);
        @memcpy(buf[2 .. 2 + reason.len], reason);
        try self.send(.close, buf[0 .. 2 + reason.len]);
    }

    /// 阻塞读一个完整的 message。
    ///
    /// 自动处理：
    /// - 分片：累积 continuation 帧 payload 直到 FIN=1
    /// - ping：自动回 pong，继续读下一个帧
    /// - pong：忽略（不需要回应），继续读
    /// - close：自动回 close 帧，返回 error.ConnectionClosed
    ///
    /// 返回的 Message.payload 由 self.allocator 拥有，调用方用 Message.deinit 释放。
    pub fn receive(self: *Self) !Message {
        var payload_list = std.ArrayList(u8).empty;
        defer payload_list.deinit(self.allocator);

        var first_opcode: OpCode = .text; // 默认值，首帧循环里会被覆盖
        var saw_first_frame: bool = false;

        while (true) {
            var f = try frame_mod.decode(self.reader, self.allocator, self.max_frame_payload);
            defer self.allocator.free(f.payload);

            // 修复 E6：未协商扩展时 RSV 位必须为 0。
            if (f.rsv1 or f.rsv2 or f.rsv3) return error.ProtocolError;

            // 修复 E4：控制帧不可分片（RFC §5.4，FIN 必须为 1）。
            if (f.opcode.isControl() and !f.fin) return error.ProtocolError;

            // 修复 E3：服务端必须拒绝未 mask 的客户端帧（RFC §5.1）。
            if (!self.is_client and !f.mask) return error.ProtocolError;

            switch (f.opcode) {
                .ping => {
                    // RFC §5.5.2: 收到 ping 必须尽快回相同 payload 的 pong。
                    try self.pong(f.payload);
                    continue; // ping 不算数据 message，继续读
                },
                .pong => {
                    // 主动 ping 的响应，这里不维护 outstanding ping 队列，直接忽略。
                    continue;
                },
                .close => {
                    // RFC §5.5.1：close payload 长度必须为 0 或 ≥ 2（P2-17）。
                    // 长度为 1 无法容纳 2 字节 close code → 协议错误。
                    if (f.payload.len == 1) return error.ProtocolError;
                    // close reason（code 之后的字节）必须是合法 UTF-8（RFC §5.5.1 / §8.1）。
                    if (f.payload.len > 2 and !std.unicode.utf8ValidateSlice(f.payload[2..])) {
                        return error.ProtocolError;
                    }
                    // RFC §7.1.2: 收到 close 后应回一个 close（如果还没发过）。
                    if (!self.closed) {
                        self.closed = true;
                        // 用对方的 close code 回应（如果有 payload）。无 payload 时发空 close。
                        var reply_buf: [125]u8 = undefined;
                        var reply_len: usize = 0;
                        if (f.payload.len >= 2) {
                            var reply_code = std.mem.readInt(u16, f.payload[0..2], .big);
                            // RFC §7.4.1: 1005/1006/1015 等不得出现在线路上;
                            // 对方发了无效码则用 1002 protocol_error 回应，不直接回显。
                            if (!isValidCloseCode(reply_code)) reply_code = 1002;
                            std.mem.writeInt(u16, reply_buf[0..2], reply_code, .big);
                            const reason = f.payload[2..];
                            const rlen = @min(reason.len, 123);
                            @memcpy(reply_buf[2 .. 2 + rlen], reason[0..rlen]);
                            reply_len = 2 + rlen;
                        }
                        try self.send(.close, reply_buf[0..reply_len]);
                    }
                    return error.ConnectionClosed;
                },
                .text, .binary => {
                    // 新 message 的首帧。如果之前有未完成的分片，是协议错误——
                    // RFC §5.4: 不允许在 FIN=0 后开始新 message。
                    // 修复 E5：用 saw_first_frame 判定（而非 payload_list.len），
                    // 否则首帧空 payload+FIN=0 时会漏判。
                    if (saw_first_frame) {
                        return error.ProtocolError;
                    }
                    first_opcode = f.opcode;
                    saw_first_frame = true;
                    try self.appendBounded(&payload_list, f.payload);
                    if (f.fin) return self.finishMessage(&payload_list, first_opcode);
                    // FIN=0: 等待 continuation 帧
                },
                .continuation => {
                    // 必须在已有首帧的上下文里——否则协议错误。
                    if (!saw_first_frame) {
                        return error.ProtocolError;
                    }
                    try self.appendBounded(&payload_list, f.payload);
                    if (f.fin) return self.finishMessage(&payload_list, first_opcode);
                },
                else => {
                    // 保留 opcode（0x3-0x7, 0xB-0xF）——未知帧，协议错误。
                    return error.ProtocolError;
                },
            }
        }
    }

    /// 收尾一个完整 message：取走 payload 所有权、校验 text 的 UTF-8（RFC §5.6）。
    ///
    /// **释放路径只有这一条**：失败时本函数自己 free。调用点绝对不能再写
    /// `errdefer allocator.free(owned)` 或额外的显式 free —— 旧实现两者共存，
    /// `return error.InvalidUtf8` 会先执行分支内的 free 再触发 errdefer 的 free
    /// → double free（远程可触发：一个 payload=`\xff` 的 text 帧即可）。
    fn finishMessage(self: *Self, list: *std.ArrayList(u8), opcode: OpCode) !Message {
        const owned = try list.toOwnedSlice(self.allocator);
        if (opcode == .text and !std.unicode.utf8ValidateSlice(owned)) {
            self.allocator.free(owned);
            self.closeWithCode(1007) catch {};
            return error.InvalidUtf8;
        }
        return .{ .opcode = opcode, .payload = owned, .allocator = self.allocator };
    }

    /// 向分片缓冲追加，受 max_message_size 限制（修复 E2：防分片总大小无限增长 OOM）。
    fn appendBounded(self: *Self, list: *std.ArrayList(u8), data: []const u8) !void {
        if (list.items.len + data.len > self.max_message_size) {
            return error.MessageTooBig;
        }
        try list.appendSlice(self.allocator, data);
    }
};

/// 判断 close 状态码是否允许出现在线路上（RFC 6455 §7.4.1）。
/// 1005/1006/1015 是保留码，不得在实际 close 帧中发送。
fn isValidCloseCode(code: u16) bool {
    return switch (code) {
        1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011 => true,
        3000...4999 => true, // 应用/私有保留区间
        else => false,
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

/// 手动写一个帧，控制 FIN 位（frame.encode 总是 FIN=1，测试分片需要 FIN=0）。
/// 仅供测试用——所以没有用更复杂的扩展长度档位。
fn writeTestFrame(
    writer: *std.Io.Writer,
    opcode: OpCode,
    fin: bool,
    payload: []const u8,
    mask: bool,
    key: [4]u8,
) !void {
    // FIN bit 在 first byte 的 bit 7；MASK bit 在 second byte 的 bit 7。
    var first: u8 = @backingInt(opcode);
    if (fin) first |= 0x80;
    try writer.writeByte(first);

    var second: u8 = 0;
    if (mask) second |= 0x80;
    // payload ≤ 125 假设（测试用）
    std.debug.assert(payload.len <= 125);
    second |= @as(u8, @intCast(payload.len));
    try writer.writeByte(second);

    if (mask) {
        try writer.writeAll(&key);
        var i: usize = 0;
        while (i < payload.len) : (i += 1) {
            try writer.writeByte(payload[i] ^ key[i & 3]);
        }
    } else {
        try writer.writeAll(payload);
    }
}

test "sendText / receive roundtrip (server → client)" {
    const allocator = testing.allocator;

    // 服务端发送（不 mask）到 in-memory writer
    var send_w: std.Io.Writer.Allocating = .init(allocator);
    defer send_w.deinit();
    var dummy_r: std.Io.Reader = .fixed("");
    var server_ws = WebSocket.initServer(&dummy_r, &send_w.writer, allocator);
    try server_ws.sendText("hello world");
    const sent = send_w.written();

    // 用一个新 reader 解码这些字节，模拟"客户端收到"
    var client_r: std.Io.Reader = .fixed(sent);
    var client_w: std.Io.Writer.Allocating = .init(allocator);
    defer client_w.deinit();
    var client_ws = WebSocket.initClient(&client_r, &client_w.writer, allocator);

    var msg = try client_ws.receive();
    defer msg.deinit();
    try testing.expectEqual(OpCode.text, msg.opcode);
    try testing.expectEqualStrings("hello world", msg.payload);
}

test "sendBinary / receive roundtrip (client → server)" {
    const allocator = testing.allocator;

    // 客户端发送（mask=true）
    var send_w: std.Io.Writer.Allocating = .init(allocator);
    defer send_w.deinit();
    var dummy_r: std.Io.Reader = .fixed("");
    var client_ws = WebSocket.initClient(&dummy_r, &send_w.writer, allocator);
    try client_ws.sendBinary("\x00\x01\x02\xff");
    const sent = send_w.written();

    var server_r: std.Io.Reader = .fixed(sent);
    var server_w: std.Io.Writer.Allocating = .init(allocator);
    defer server_w.deinit();
    var server_ws = WebSocket.initServer(&server_r, &server_w.writer, allocator);

    var msg = try server_ws.receive();
    defer msg.deinit();
    try testing.expectEqual(OpCode.binary, msg.opcode);
    try testing.expectEqualSlices(u8, "\x00\x01\x02\xff", msg.payload);
}

test "receive auto-replies to ping with pong" {
    const allocator = testing.allocator;

    // 构造一个 ping 帧后跟一个 text 帧，作为"客户端发来的输入"
    var input_w: std.Io.Writer.Allocating = .init(allocator);
    defer input_w.deinit();
    try writeTestFrame(&input_w.writer, .ping, true, "pingdata", true, .{ 0xAA, 0xBB, 0xCC, 0xDD });
    try writeTestFrame(&input_w.writer, .text, true, "after-ping", true, .{ 0x11, 0x22, 0x33, 0x44 });
    const input = try allocator.dupe(u8, input_w.written());
    defer allocator.free(input);

    var r: std.Io.Reader = .fixed(input);
    var out_w: std.Io.Writer.Allocating = .init(allocator);
    defer out_w.deinit();
    var ws = WebSocket.initServer(&r, &out_w.writer, allocator);

    // receive 应跳过 ping（自动回 pong），返回 text
    var msg = try ws.receive();
    defer msg.deinit();
    try testing.expectEqual(OpCode.text, msg.opcode);
    try testing.expectEqualStrings("after-ping", msg.payload);

    // 验证服务端发出了 pong（payload 应等于 ping 的 "pingdata"）
    const sent = out_w.written();
    var sent_r: std.Io.Reader = .fixed(sent);
    const pong_frame = try frame_mod.decode(&sent_r, allocator, frame_mod.DEFAULT_MAX_PAYLOAD);
    defer allocator.free(pong_frame.payload);
    try testing.expectEqual(OpCode.pong, pong_frame.opcode);
    try testing.expectEqualStrings("pingdata", pong_frame.payload);
}

test "receive auto-replies to close and returns ConnectionClosed" {
    const allocator = testing.allocator;

    var input_w: std.Io.Writer.Allocating = .init(allocator);
    defer input_w.deinit();
    // 客户端发 close（code=1000, reason="bye"）
    var close_buf: [5]u8 = undefined;
    std.mem.writeInt(u16, close_buf[0..2], 1000, .big);
    @memcpy(close_buf[2..], "bye");
    try writeTestFrame(&input_w.writer, .close, true, &close_buf, true, .{ 0x01, 0x02, 0x03, 0x04 });
    const input = try allocator.dupe(u8, input_w.written());
    defer allocator.free(input);

    var r: std.Io.Reader = .fixed(input);
    var out_w: std.Io.Writer.Allocating = .init(allocator);
    defer out_w.deinit();
    var ws = WebSocket.initServer(&r, &out_w.writer, allocator);

    try testing.expectError(error.ConnectionClosed, ws.receive());

    // 验证回了一个 close
    const sent = out_w.written();
    var sent_r: std.Io.Reader = .fixed(sent);
    var reply = try frame_mod.decode(&sent_r, allocator, frame_mod.DEFAULT_MAX_PAYLOAD);
    defer allocator.free(reply.payload);
    try testing.expectEqual(OpCode.close, reply.opcode);
    try testing.expect(reply.payload.len >= 2);
    const reply_code = std.mem.readInt(u16, reply.payload[0..2], .big);
    try testing.expectEqual(@as(u16, 1000), reply_code);
}

test "receive assembles fragmented message" {
    const allocator = testing.allocator;

    // 三个帧：text FIN=0 "part1", continuation FIN=0 "part2", continuation FIN=1 "part3"
    var input_w: std.Io.Writer.Allocating = .init(allocator);
    defer input_w.deinit();
    const k1: [4]u8 = .{ 0xA0, 0xA1, 0xA2, 0xA3 };
    const k2: [4]u8 = .{ 0xB0, 0xB1, 0xB2, 0xB3 };
    try writeTestFrame(&input_w.writer, .text, false, "part1", true, k1);
    try writeTestFrame(&input_w.writer, .continuation, false, "part2", true, k2);
    try writeTestFrame(&input_w.writer, .continuation, true, "part3", true, k1);
    const input = try allocator.dupe(u8, input_w.written());
    defer allocator.free(input);

    var r: std.Io.Reader = .fixed(input);
    var out_w: std.Io.Writer.Allocating = .init(allocator);
    defer out_w.deinit();
    var ws = WebSocket.initServer(&r, &out_w.writer, allocator);

    var msg = try ws.receive();
    defer msg.deinit();
    try testing.expectEqual(OpCode.text, msg.opcode);
    try testing.expectEqualStrings("part1part2part3", msg.payload);
}

test "close method sends close frame and is idempotent" {
    const allocator = testing.allocator;

    var out_w: std.Io.Writer.Allocating = .init(allocator);
    defer out_w.deinit();
    var dummy_r: std.Io.Reader = .fixed("");
    var ws = WebSocket.initServer(&dummy_r, &out_w.writer, allocator);

    try ws.close(.normal_closure, "bye");
    // 二次 close 应幂等返回，不重复发帧
    try ws.close(.going_away, "");

    const sent = out_w.written();
    var sent_r: std.Io.Reader = .fixed(sent);
    var f = try frame_mod.decode(&sent_r, allocator, frame_mod.DEFAULT_MAX_PAYLOAD);
    defer allocator.free(f.payload);
    try testing.expectEqual(OpCode.close, f.opcode);
    try testing.expectEqual(@as(usize, 5), f.payload.len);
    const code = std.mem.readInt(u16, f.payload[0..2], .big);
    try testing.expectEqual(@as(u16, 1000), code);
    try testing.expectEqualStrings("bye", f.payload[2..]);
}

test {
    std.testing.refAllDecls(@This());
}
