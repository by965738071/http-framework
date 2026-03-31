# Zig 0.16-dev HTTP Server 实现

基于 Zig 0.16-dev 最新 HTTP 标准库的完整服务器实现。

 

## 核心功能

### 1. 参数解析

```zig
// Query 参数解析
const query_start = mem.indexOfScalar(u8, target, '?');
const path = if (query_start) |idx| target[0..idx] else target;
const query = if (query_start) |idx| target[idx + 1 ..] else "";

// 解析 query 参数
var pairs = mem.splitScalar(u8, query, '&');
while (pairs.next()) |pair| {
    // name=value 解析
}
```

### 2. Chunk 解析

Zig 0.16-dev 的 HTTP 库已经内置了 chunked 传输编码支持：

```zig
// 自动处理 chunked 或 content-length
const body_reader = request.readerExpectNone(&buffer);

// 读取 body 数据
while (true) {
    const n = body_reader.read(&temp_buf) catch |err| switch (err) {
        error.EndOfStream => break,
        else => return err,
    };
    // 处理数据...
}
```

### 3. 路由解析

```zig
fn matchRoute(method: http.Method, path: []const u8) !RouteResult {
    if (mem.eql(u8, path, "/")) {
        return .home;
    } else if (mem.eql(u8, path, "/hello")) {
        return .hello;
    }
    return .not_found;
}
```

### 4. 请求体读取

```zig
// 读取请求体（支持 content-length 和 chunked）
fn readRequestBody(request: *http.Server.Request, allocator: std.mem.Allocator) !?[]const u8 {
    var buffer: [8192]u8 = undefined;
    const body_reader = request.readerExpectNone(&buffer);
    
    var result = std.ArrayList(u8).init(allocator);
    var temp_buf: [4096]u8 = undefined;
    
    while (true) {
        const n = body_reader.read(&temp_buf) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        try result.appendSlice(temp_buf[0..n]);
    }
    
    return try result.toOwnedSlice();
}
```

### 5. 发送响应

```zig
// 简单响应
try request.respond("Hello, World!", .{
    .status = .ok,
    .extra_headers = &.{
        .{ .name = "Content-Type", .value = "text/plain" },
    },
});

// JSON 响应
try request.respond(json_str, .{
    .status = .ok,
    .extra_headers = &.{
        .{ .name = "Content-Type", .value = "application/json" },
    },
});

// 流式响应
var body_writer = try request.respondStreaming(&buffer, .{
    .respond_options = .{
        .status = .ok,
        .transfer_encoding = .chunked,
    },
});
try body_writer.writer.writeAll("data");
try body_writer.end();
```

### 6. WebSocket 支持

```zig
const upgrade = request.upgradeRequested();
switch (upgrade) {
    .websocket => |key| {
        if (key) |k| {
            var ws = try request.respondWebSocket(.{ .key = k });
            
            // 读取消息
            const msg = try ws.readSmallMessage();
            
            // 发送消息
            try ws.writeMessage("Hello", .text);
        }
    },
    else => {},
}
```

## 运行示例

```bash
# 编译并运行
zig run simple_http_handler.zig

# 测试
zig test simple_http_handler.zig
```

## API 端点

启动服务器后，可以访问：

- `http://127.0.0.1:8080/` - 首页
- `http://127.0.0.1:8080/hello` - Hello 接口
- `http://127.0.0.1:8080/hello?name=Zig` - 带参数的 Hello 接口
- `http://127.0.0.1:8080/api/test` - API 接口

## Zig 0.16-dev HTTP API 变化

相比 0.13/0.14 版本，0.16-dev 的主要变化：

1. **新的 IO API**: 使用 `std.Io.Reader` 和 `std.Io.Writer` 替代旧的流 API
2. **Server 初始化**: `http.Server.init(&reader, &writer)`
3. **Body 读取**: `request.readerExpectNone(&buffer)` 返回 `*std.Io.Reader`
4. **Chunked 处理**: 内置支持，无需手动解析
5. **WebSocket**: `request.respondWebSocket(.{ .key = key })`

## 依赖

- Zig 0.16.0-dev (最新 master 分支)
