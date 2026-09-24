//! `http_websocket` — WebSocket (RFC 6455) addon
//!
//! 提供完整的 WebSocket 实现：
//! - 握手升级（HTTP → WebSocket，§4）
//! - 帧编解码（RFC §5）
//! - 连接级读写 API（分片、ping/pong、close 自动处理）
//!
//! # 模块结构
//!
//! ```
//! http_websocket
//! ├── frame.zig      — 帧编解码（OpCode, Frame, encode, decode, applyMask）
//! ├── handshake.zig  — 握手升级（handshake, computeAcceptKey, WS_GUID）
//! ├── connection.zig — 连接（WebSocket, Message, CloseCode）
//! └── root.zig       — 模块入口 + re-exports
//! ```
//!
//! # 与框架的集成
//!
//! 依赖 `http_app`（Context）和 `http_protocol`（Response）。
//!
//! 推荐用 `upgrade(ctx, res, user_ptr, handlerFn)` 一步完成：共享校验 + 注册
//! 连接劫持。`user_ptr` 是类型化指针（F-20，不再是 `*anyopaque`），`handlerFn`
//! 尾参类型由调用点编译期校验。ConnectionRunner 在 dispatch 结束后把裸
//! reader/writer 交给回调，由回调直写 101 并跑帧循环。
//!
//! `handshake(ctx, res)` 只校验请求头并把 101 + 握手响应头写进 `res`，
//! **不接管连接**——除非你要自行完成“发送响应 + 接管 stream”，否则不要只调
//! 它（客户端会收到 101 却等不到 WS 帧）。内部与 `upgrade()` 共用同一套
//! 校验（`validateUpgradeRequest`）。
//!
//! # 设计取舍
//!
//! - 帧编解码操作于抽象 `std.Io.Reader`/`std.Io.Writer`，不绑死 socket，
//!   方便单元测试（用 fixed buffer / Allocating writer）。
//! - decode 出的 payload 是 owned 内存（由 allocator 分配），不指向 reader
//!   内部缓冲——避免 use-after-free。
//! - mask 策略由 `is_client` 标志决定：服务端发送不 mask，客户端发送 mask。
//!   这是协议硬约束（RFC §5.1），不是配置项。

const std = @import("std");
const http_app = @import("http_app");
const http_protocol = @import("http_protocol");

pub const Context = http_app.Context;
pub const Response = http_protocol.Response;

pub const frame = @import("frame.zig");
pub const handshake_mod = @import("handshake.zig");
pub const connection = @import("connection.zig");

// 主要类型的 re-export，方便 `http_framework.WebSocket` 等聚合访问。
pub const OpCode = frame.OpCode;
pub const Frame = frame.Frame;
pub const encode = frame.encode;
pub const decode = frame.decode;
pub const applyMask = frame.applyMask;

pub const handshake = handshake_mod.handshake;
pub const upgrade = handshake_mod.upgrade;
pub const computeAcceptKey = handshake_mod.computeAcceptKey;
pub const WS_GUID = handshake_mod.WS_GUID;
pub const ACCEPT_KEY_LEN = handshake_mod.ACCEPT_KEY_LEN;

pub const WebSocket = connection.WebSocket;
pub const Message = connection.Message;
pub const CloseCode = connection.CloseCode;

test {
    std.testing.refAllDecls(@This());
}
