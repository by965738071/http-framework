//! 连接级 keep-alive 状态机
//!
//! 设计原则（回应 bug.md §7）：
//! 把"HTTP 状态机 + keep-alive 循环"从 Server 里拆出来。这一层只负责
//! "从连接上循环读取请求、产出 Request 对象"，不负责 dispatch /
//! handler / middleware / 信号。
//!
//! ConnectionLoop 包装 std.http.Server，每次 `next()` 返回一个
//! `http_protocol.Request`。连接关闭时返回 null。

const http = std.http;
const protocol = @import("request.zig");

pub const ConnectionLoop = struct {
    server: *http.Server,
    arena: *std.heap.ArenaAllocator,
    io: std.Io,
    recoverable_errors: u32 = 0,

    const Self = @This();

    /// `server` 必须由调用方（ConnectionRunner）创建并持有。
    /// `arena` 是请求级 arena——每次 `next()` 调 `arena.reset()` 清理。
    pub fn init(io: std.Io, server: *http.Server, arena: *std.heap.ArenaAllocator) Self {
        return .{ .server = server, .arena = arena, .io = io };
    }

    /// next() 的返回值。
    /// `raw` 是指向 arena 分配的 std.http.Server.Request，ConnectionRunner 用它构建 Sink
    /// 和读取 streaming body。arena 分配保证其生命周期覆盖整个请求处理过程。
    /// 调用方必须在处理完这个请求（发送完响应）之后才能再次调 next()。
    pub const NextResult = struct {
        parsed: protocol.Request,
        raw: *http.Server.Request,
    };

    /// 读取下一个请求。
    ///
    /// 返回 `null` 表示连接已关闭（正常 EOF 或关服取消）。
    /// 返回 `error.ProtocolError` 表示客户端发了坏请求，应当回 400 并关连接。
    pub fn next(self: *Self) !?NextResult {
        // 清理上一个请求的 arena
        _ = self.arena.reset(.retain_capacity);

        // 在 arena 上分配 http_request，生命周期绑定请求 arena
        const http_request = try self.arena.allocator().create(http.Server.Request);
        http_request.* = self.server.receiveHead() catch |err| {
            if (isConnectionClosed(err)) return null;
            if (isProtocolError(err)) return error.ProtocolError;
            return err;
        };

        const parsed = try protocol.Request.init(self.arena.allocator(), http_request);
        return .{ .parsed = parsed, .raw = http_request };
    }

    /// 检查请求是否可以继续复用连接（keep-alive）。
    pub fn shouldKeepAlive(self: *const Self, req: *const protocol.Request) bool {
        _ = self;
        // HTTP/1.1 默认 keep-alive，除非显式 Connection: close
        if (req.getHeader("Connection")) |conn| {
            if (std.ascii.eqlIgnoreCase(conn, "close")) return false;
        }
        // HTTP/1.0 默认 close，除非显式 Connection: keep-alive
        if (req.version == .@"HTTP/1.0") {
            if (req.getHeader("Connection")) |conn| {
                if (std.ascii.eqlIgnoreCase(conn, "keep-alive")) return true;
            }
            return false;
        }
        return true;
    }

    pub fn deinit(self: *Self) void {
        _ = self;
        // server 和 arena 由调用方管理
    }
};

fn isConnectionClosed(err: anyerror) bool {
    return switch (err) {
        error.EndOfStream, error.ConnectionClosed, error.Canceled => true,
        else => false,
    };
}

fn isProtocolError(err: anyerror) bool {
    return switch (err) {
        error.HttpHeadersInvalid, error.HttpRequestHeadTooLarge, error.InvalidCharacter => true,
        else => false,
    };
}

const std = @import("std");
test {
    std.testing.refAllDecls(@This());
}
