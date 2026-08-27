//! zio Server —— 所有与 zio 运行时绑定的代码集中于此（高内聚）。
//!
//! 这是 http_server 里唯一 `@import("zio")` 的文件。它负责一切"跟运行时有关"
//! 的事：监听/accept/背压、并发任务派发、信号关机、连接读写（带超时）、
//! 运行时启动。然后把"已建好的 reader/writer"交给后端无关的 ConnectionRunner
//! （connection.zig）跑纯 HTTP 逻辑。
//!
//! 换别的运行时（明天的 xio）：整份复制成 xio_server.zig，按那个库的 API
//! 重写这里的 zio.* 调用即可——ConnectionRunner / router / 中间件
//! 全部复用，一行不改。不需要预先设计"通用契约"（因为我们并不知道下一个库
//! 长什么样）；到真有第二个库时，对比两份 server 再抽公共部分也不迟。

const std = @import("std");
const zio = @import("zio");
const http_app = @import("http_app");
const http_router = @import("http_router");
const ConnectionRunner = @import("connection.zig").ConnectionRunner;

/// 启动 zio 运行时，在其协程上下文中运行 `appFn(io, allocator)`，结束后清理。
/// 入口（main.zig）只需 `try zioServer.run(gpa, appMain)`，无需直接依赖 zio。
pub fn run(
    allocator: std.mem.Allocator,
    comptime appFn: fn (std.Io, std.mem.Allocator) anyerror!void,
) !void {
    // zio 协程默认只提交 256KB 栈。某些 handler/中间件路径会产生较大的栈临时量，
    // 典型如响应压缩：`flate.Compress` 是 ~224KB 的巨型 struct（std 源码注释：
    // "Allocates statically ~224K"），`try flate.Compress.init(...)` 会在栈上
    // 生成该体积的临时值。叠加其它帧后溢出 256KB 提交栈、踩到 guard page，
    // 在 macOS/kqueue 的栈增长 fault 路径上表现为请求挂起 + WriteFailed/EFAULT。
    // 把提交栈提到 1MB，给这类大栈帧留足空间（虚拟保留上限仍是默认 8MB）。
    const rt = try zio.Runtime.init(allocator, .{
        .stack_pool = .{
            .maximum_size = 8 * 1024 * 1024,
            .committed_size = 1024 * 1024,
        },
    });
    defer rt.deinit();
    var handle = try zio.spawn(appFn, .{ rt.io(), allocator });
    handle.join() catch |err| {
        std.log.err("zio app failed: {s}", .{@errorName(err)});
        return err;
    };
}

/// TCP 监听器 + 并发连接背压（zio.net.Server + zio.Semaphore）。
const Listener = struct {
    server: zio.net.Server,
    semaphore: zio.Semaphore,

    fn init(config: *const http_app.NetworkConfig) !Listener {
        const address = try zio.net.IpAddress.parseIp4(config.address, config.port);
        const server = try address.listen(.{
            .kernel_backlog = config.tcp_backlog,
            .reuse_address = config.reuse_address,
        });
        return .{ .server = server, .semaphore = .{ .permits = config.max_connections } };
    }

    fn deinit(self: *Listener) void {
        self.server.close();
    }
};

/// Server — zio 版组装器。
pub const Server = struct {
    io: std.Io,
    config: http_app.Config,
    runtime: http_app.RuntimeState,
    /// 监听器在 `setup()` 里创建。用 optional 而不是 `undefined`：
    /// 标准用法是 `init` → `defer deinit()` → `setup()`，若 setup 失败
    /// （端口占用是最常见的启动失败），deinit 会对 undefined 的 fd 调 close()
    /// —— 关掉进程里任意一个句柄，或直接 UB。
    listener: ?Listener = null,
    router: *const http_router.Router,
    lifecycle: http_app.Lifecycle,
    group: zio.Group,
    allocator: std.mem.Allocator,
    services: ?*const http_app.Services = null,

    /// io 必须来自 zio.Runtime.io()（run 需在 zio 协程上下文中运行）。
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: http_app.Config,
        router: *const http_router.Router,
    ) !Server {
        return .{
            .io = io,
            .config = config,
            .runtime = .{},
            .listener = null,
            .router = router,
            .lifecycle = .{},
            .group = .init,
            .allocator = allocator,
        };
    }

    pub fn setup(self: *Server) !void {
        // P2-38：对“已设置但未实现”的配置项告警。死开关比没有配置更危险：
        // 运维会以为自己改变了行为，实际无效。仅在非默认值时提醒，避免噪声。
        if (self.config.body.lazy_read_size != 0) {
            std.log.warn("config: body.lazy_read_size is set but not implemented (no effect)", .{});
        }
        if (self.config.network.idle_timeout_ns != 60_000_000_000) {
            std.log.warn("config: network.idle_timeout_ns is not implemented; keep-alive idle is bounded by read_timeout_ns", .{});
        }
        if (self.config.http.access_log_enabled) {
            std.log.warn("config: http.access_log_enabled has no effect; register a LoggingHook/LoggingMiddleware for access logs", .{});
        }
        self.listener = try Listener.init(&self.config.network);
    }

    pub fn deinit(self: *Server) void {
        if (self.listener) |*l| l.deinit();
        self.listener = null;
    }

    pub fn setLifecycle(self: *Server, lifecycle: http_app.Lifecycle) void {
        self.lifecycle = lifecycle;
    }

    pub fn setServices(self: *Server, services: *const http_app.Services) void {
        self.services = services;
    }

    pub fn stats(self: *const Server) http_app.ServerStats {
        return .{
            .active_connections = self.runtime.active_connections.load(.monotonic),
            .total_connections = self.runtime.total_connections.load(.monotonic),
            .active_requests = self.runtime.active_requests.load(.monotonic),
            .accept_errors = self.runtime.accept_errors.load(.monotonic),
            .shutting_down = self.runtime.shutting_down.load(.monotonic),
        };
    }

    /// 标记服务器进入关闭状态（新连接会被 ConnectionRunner 拒绝）。
    fn isShuttingDown(self: *const Server) bool {
        return self.runtime.shutting_down.load(.monotonic);
    }

    /// 主运行循环。在 zio 协程里跑：
    /// 1. 把 accept 循环 spawn 为可取消的 group 任务；
    /// 2. 当前协程阻塞等 SIGINT **或 SIGTERM**；
    /// 3. 收到信号：置关机标志、cancel accept（accept 返回 Canceled）；
    /// 4. 取消并等待在途连接任务，drain 兜底。
    pub fn run(self: *Server) !void {
        var accept_group: zio.Group = .init;
        try accept_group.spawn(acceptLoop, .{self});
        // 无论从哪条路径退出（信号等待失败、wait 报错），在途任务都必须被取消并回收，
        // 否则协程在 Server 析构后仍持有 self/listener 指针。
        errdefer {
            self.runtime.shutting_down.store(true, .monotonic);
            accept_group.cancel();
            accept_group.wait() catch {};
            self.group.cancel();
            self.group.wait() catch {};
        }

        try waitForShutdownSignal(&accept_group);

        self.runtime.shutting_down.store(true, .monotonic);
        accept_group.cancel();
        try accept_group.wait();

        self.group.cancel();
        try self.group.wait();
        self.drain();
    }

    /// 等待 SIGINT 或 SIGTERM 之一。
    ///
    /// 必须同时监听 SIGTERM：容器（docker stop）、systemd、k8s 发的都是 SIGTERM，
    /// 只监听 SIGINT 等于「优雅关机在生产环境不生效」——进程被 SIGKILL 强杀，
    /// 在途请求直接断、drain 逻辑白写。
    fn waitForShutdownSignal(accept_group: *zio.Group) !void {
        var sigint = zio.Signal.init(.interrupt) catch |err| {
            std.log.warn("signal init (SIGINT) failed: {s}", .{@errorName(err)});
            accept_group.wait() catch {};
            return;
        };
        defer sigint.deinit();

        var sigterm = zio.Signal.init(.terminate) catch |err| {
            // SIGTERM 注册失败不致命，退化成只等 SIGINT。
            std.log.warn("signal init (SIGTERM) failed: {s}", .{@errorName(err)});
            try sigint.wait();
            std.log.info("shutdown signal received (SIGINT)", .{});
            return;
        };
        defer sigterm.deinit();

        switch (try zio.select(.{ .int = &sigint, .term = &sigterm })) {
            .int => std.log.info("shutdown signal received (SIGINT)", .{}),
            .term => std.log.info("shutdown signal received (SIGTERM)", .{}),
        }
    }

    /// 等所有活跃连接结束，最多等 drain_timeout_ns（兜底）。
    fn drain(self: *Server) void {
        const drain_timeout_ns: u64 = 30 * std.time.ns_per_s;
        // 用单调时钟（.awake）而不是墙钟（.real）：NTP 校正/手工改时间会让
        // 墙钟差值变成负数或巨大值 —— 前者让 drain 卡满 30s，后者让它立刻放弃。
        const start = std.Io.Timestamp.now(self.io, .awake).nanoseconds;
        while (true) {
            if (self.runtime.active_connections.load(.monotonic) == 0) return;
            const elapsed = std.Io.Timestamp.now(self.io, .awake).nanoseconds - start;
            if (elapsed >= drain_timeout_ns) {
                std.log.warn("drain timed out with {d} connections still active", .{
                    self.runtime.active_connections.load(.monotonic),
                });
                return;
            }
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
        }
    }

    fn acceptLoop(self: *Server) !void {
        while (true) {
            if (self.isShuttingDown()) break;

            try self.listener.?.semaphore.wait(); // 背压 + Canceled 退出

            const stream = self.listener.?.server.accept(.{}) catch |err| {
                self.listener.?.semaphore.post();
                if (err == error.Canceled) break;
                if (self.isShuttingDown()) break;
                _ = self.runtime.accept_errors.fetchAdd(1, .monotonic);
                std.log.warn("accept error: {s}", .{@errorName(err)});
                continue;
            };

            self.spawnConnection(stream);
        }
    }

    fn spawnConnection(self: *Server, stream: zio.net.Stream) void {
        const conn = self.allocator.create(Conn) catch {
            stream.close();
            self.listener.?.semaphore.post();
            return;
        };
        conn.* = .{
            .server = self,
            .stream = stream,
            .read_buf = self.allocator.alloc(u8, @max(self.config.http.read_buffer_size, MIN_READ_BUF)) catch {
                self.allocator.destroy(conn);
                stream.close();
                self.listener.?.semaphore.post();
                return;
            },
            .write_buf = self.allocator.alloc(u8, @max(self.config.http.write_buffer_size, MIN_WRITE_BUF)) catch {
                self.allocator.free(conn.read_buf);
                self.allocator.destroy(conn);
                stream.close();
                self.listener.?.semaphore.post();
                return;
            },
        };

        self.group.spawn(connectionTask, .{conn}) catch {
            conn.run(); // 派发失败：同步降级
            conn.destroy();
        };
    }

    /// 每连接的 zio 侧资源 + 生命周期。持有 zio.net.Stream 与缓冲区，
    /// 建好带超时的 reader/writer 后交给后端无关的 ConnectionRunner。
    const Conn = struct {
        server: *Server,
        stream: zio.net.Stream,
        read_buf: []u8,
        write_buf: []u8,

        fn run(self: *Conn) void {
            defer self.stream.close();

            // zio 原生 reader/writer：带 per-operation 超时（防慢攻击）。
            var reader = self.stream.reader(self.read_buf);
            var writer = self.stream.writer(self.write_buf);
            reader.setTimeout(zio.Timeout.fromNanoseconds(self.server.config.network.read_timeout_ns));
            writer.setTimeout(zio.Timeout.fromNanoseconds(self.server.config.network.write_timeout_ns));

            // 汇合点：把 std.Io 读写接口交给后端无关的 HTTP 引擎。
            var runner = ConnectionRunner{
                .reader = &reader.interface,
                .writer = &writer.interface,
                .io = self.server.io,
                .router = self.server.router,
                .config = &self.server.config,
                .lifecycle = self.server.lifecycle,
                .stats = &self.server.runtime,
                .allocator = self.server.allocator,
                .services = self.server.services,
            };
            runner.run();
        }

        fn destroy(self: *Conn) void {
            const server = self.server;
            server.allocator.free(self.read_buf);
            server.allocator.free(self.write_buf);
            server.allocator.destroy(self);
            server.listener.?.semaphore.post(); // 归还背压名额
        }
    };

    fn connectionTask(conn: *Conn) void {
        conn.run();
        conn.destroy();
    }
};

const MIN_READ_BUF = 2 * 1024;
const MIN_WRITE_BUF = 512;
