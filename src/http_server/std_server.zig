//! std Server —— 所有与 zig std 运行时（`std.Io.Threaded`）绑定的代码集中于此（高内聚）。
//!
//! 与 `zio_server.zig` 平行：两份 server 各自只负责"跟运行时有关"的事
//! （监听/accept/背压、并发任务派发、信号关机、连接读写带超时、运行时启动），
//! 然后把"已建好的 std.Io reader/writer"交给后端无关的 ConnectionRunner
//! （connection.zig）跑纯 HTTP 逻辑。公开 API（init/setup/deinit/run/stats/...）
//! 与 zio 版完全对齐，入口换 `runStd` + `StdServer` 即完成切换。
//!
//! 运行时模型差异（std vs zio）：
//! - 并发：zio = 栈协程（单线程事件循环多路复用）；std = `std.Io.Group` 任务，
//!   由 Threaded 的 OS 线程池执行。连接数受背压信号量（max_connections）约束，
//!   但每条在途连接 ≈ 一个 OS 线程，成本远高于协程：std 后端建议把
//!   max_connections 调到与真实并发相当，而不是照搬 zio 后端的几千。
//! - per-operation 超时：POSIX 上用 `io.operateTimeout`（内部 poll + deadline，
//!   语义对齐 zio 的 reader/writer setTimeout，防慢攻击）。Windows 上 std 的
//!   Threaded 批处理尚未把 net_read/net_write 接入重叠 I/O（源码标注 TODO，
//!   `Batch.awaitConcurrent` 直接返回 ConcurrencyUnavailable），因此退化为纯
//!   阻塞读写——慢连接只能等关机时 `Group.cancel` 打断。`setup()` 会告警。
//! - 关机信号：std 没有 zio.Signal。信号处理器（POSIX sigaction / Windows
//!   SetConsoleCtrlHandler）运行在异步信号/C 上下文，只能碰进程级 atomic 标志，
//!   主线程轮询该标志（≤50ms 唤醒）。一个进程同一时刻只跑一个 std 后端 Server
//!   （与旧 std 实现同一约定）。

const std = @import("std");
const builtin = @import("builtin");
const http_app = @import("http_app");
const http_router = @import("http_router");
const ConnectionRunner = @import("connection.zig").ConnectionRunner;

const is_windows = builtin.os.tag == .windows;

/// 启动 zig std 运行时（`std.Io.Threaded`），在其上运行 `appFn(io, allocator)`，
/// 结束后清理。入口（main.zig）只需 `try stdServer.run(gpa, appMain)`，
/// 与 `zioServer.run` 对称；appFn 直接跑在主线程（没有协程上下文需要切换）。
pub fn run(
    allocator: std.mem.Allocator,
    comptime appFn: fn (std.Io, std.mem.Allocator) anyerror!void,
) !void {
    // std.Io.Threaded 是 zig 自带的运行时：阻塞 syscall + 惰性 OS 线程池。
    // - stack_size：handler/中间件路径会产生较大的栈临时量（如压缩的
    //   flate.Compress ~224KB），给工作线程 2MB，避免踩栈溢出。
    // - async_limit = unlimited：`Group.async` 在"所有线程都忙"时新建 OS 线程，
    //     否则饱和后会退化成"在 accept 循环线程内联跑连接任务"——一条慢连接
    //     卡死 accept。线程总数由背压信号量（max_connections）封顶，见文件头注释。
    var threaded = std.Io.Threaded.init(allocator, .{
        .stack_size = 2 * 1024 * 1024,
        .async_limit = .unlimited,
    });
    defer threaded.deinit();
    try appFn(threaded.io(), allocator);
}

/// TCP 监听器 + 并发连接背压（std.Io.net.Server + std.Io.Semaphore）。
const Listener = struct {
    server: std.Io.net.Server,
    semaphore: std.Io.Semaphore,

    fn init(io: std.Io, config: *const http_app.NetworkConfig) !Listener {
        // 死开关防护（对齐 zio 版）：max_connections=0 意味着零许可，
        // semaphore.wait 永远阻塞——服务能启动却永不接受任何连接。显式报错。
        if (config.max_connections == 0) return error.MaxConnectionsZero;
        // 纯 IP 字面量解析（无 DNS），与 zio 版 parseIp 语义一致；
        // 要监听主机名请自行先解析成 IP。
        const address = try std.Io.net.IpAddress.parse(config.address, config.port);
        const server = try address.listen(io, .{
            .kernel_backlog = config.tcp_backlog,
            .reuse_address = config.reuse_address,
        });
        return .{ .server = server, .semaphore = .{ .permits = config.max_connections } };
    }

    fn deinit(self: *Listener, io: std.Io) void {
        self.server.deinit(io);
    }
};

/// Server — zig std 版组装器。
pub const Server = struct {
    io: std.Io,
    config: http_app.Config,
    runtime: http_app.RuntimeState,
    /// 监听器在 `setup()` 里创建。用 optional 而不是 `undefined`：
    /// 若 setup 失败（端口占用最常见），deinit 对 undefined 的句柄调 close
    /// 会关掉进程里任意一个句柄或直接 UB（与 zio 版同一防护）。
    listener: ?Listener = null,
    router: *const http_router.Router,
    lifecycle: http_app.Lifecycle,
    group: std.Io.Group,
    allocator: std.mem.Allocator,
    services: ?*const http_app.Services = null,

    /// io 建议来自 `stdServer.run` 创建的 Threaded（async_limit 已按本后端调优）。
    /// 传入其它 std.Io 实现时并发/超时行为取决于该实现的语义。
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
            .router = router,
            .lifecycle = .{},
            .group = .init,
            .allocator = allocator,
        };
    }

    pub fn setup(self: *Server) !void {
        // P2-38：对"已设置但未实现"的配置项告警（与 zio 版同一组死开关）。
        if (self.config.body.lazy_read_size != 0) {
            std.log.warn("config: body.lazy_read_size is set but not implemented (no effect)", .{});
        }
        if (self.config.network.idle_timeout_ns != 60_000_000_000) {
            std.log.warn("config: network.idle_timeout_ns is not implemented; keep-alive idle is bounded by read_timeout_ns", .{});
        }
        if (self.config.http.access_log_enabled) {
            std.log.warn("config: http.access_log_enabled has no effect; register a LoggingHook/LoggingMiddleware for access logs", .{});
        }
        if (comptime is_windows) {
            // 见文件头"运行时模型差异"：Windows 上 std 尚未支持 net 操作的
            // 带超时批处理，read/write_timeout_ns 在本后端 + Windows 上不生效。
            std.log.warn("std runtime on Windows: read/write_timeout_ns are NOT enforced (std Threaded net batching lacks overlapped I/O); slow connections are only released at shutdown", .{});
        }
        self.listener = try Listener.init(self.io, &self.config.network);
    }

    pub fn deinit(self: *Server) void {
        if (self.listener) |*l| l.deinit(self.io);
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

    /// 主运行循环。在调用线程（通常就是 main）上跑：
    /// 1. 把 accept 循环 spawn 为可取消的 group 任务；
    /// 2. 当前线程装好信号处理器后轮询 shutdown 标志（SIGINT/SIGTERM/Ctrl+C）；
    /// 3. 收到信号：置关机标志、cancel accept（阻塞的 accept 被 std 打断）；
    /// 4. drain 在途连接（限时），仍未退出的再强制 cancel 并回收。
    pub fn run(self: *Server) !void {
        // 允许同进程内重启：清掉上一轮遗留的关机标志。
        shutdown_requested.store(false, .monotonic);
        installShutdownHandlers();
        defer uninstallShutdownHandlers();

        var accept_group: std.Io.Group = .init;
        accept_group.async(self.io, acceptLoop, .{self});
        // 无论从哪条路径退出，在途任务都必须被取消并回收——否则任务线程在
        // Server 析构后仍持有 self/listener 指针。
        errdefer {
            self.runtime.shutting_down.store(true, .monotonic);
            accept_group.cancel(self.io);
            self.group.cancel(self.io);
            accept_group.await(self.io) catch {};
            self.group.await(self.io) catch {};
        }

        self.waitForShutdownSignal();

        self.runtime.shutting_down.store(true, .monotonic);
        accept_group.cancel(self.io);
        accept_group.await(self.io) catch {};

        // 优雅关机顺序（对齐 zio 版修复）：先 drain 让在途请求自然完成
        // （空闲 keep-alive 连接在 POSIX 上会被 read_timeout 唤醒后检查
        // shutting_down 退出）；超过上限仍未退出的才 cancel 强制打断。
        // cancel 使阻塞在 syscall 里的任务线程被 std 唤醒（POSIX 经 EINTR、
        // Windows 经 CancelIoEx/APC），await 之后所有任务保证已退出。
        self.drain();
        self.group.cancel(self.io);
        self.group.await(self.io) catch {};
    }

    /// 轮询信号处理器置位的原子标志。std 没有信号 select 原语，处理器只能
    /// 写全局 atomic（见文件头约定），代价是关机唤醒最多延迟一个轮询周期。
    fn waitForShutdownSignal(self: *Server) void {
        while (!shutdown_requested.load(.monotonic)) {
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(50), .awake) catch break;
        }
    }

    /// 等所有活跃连接结束，最多等 config.network.drain_timeout_ns（兜底）。
    fn drain(self: *Server) void {
        const drain_timeout_ns: u64 = self.config.network.drain_timeout_ns;
        // 用单调时钟（.awake）而不是墙钟（.real）：NTP 校正/手工改时间会让
        // 墙钟差值变成负数或巨大值（与 zio 版同一理由）。
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

    /// accept 循环：跑在 group 任务线程上。semaphore.wait / server.accept 都是
    /// 可取消的阻塞调用，关机时由 Group.cancel 唤醒。
    fn acceptLoop(self: *Server) void {
        while (true) {
            if (self.isShuttingDown()) break;

            self.listener.?.semaphore.wait(self.io) catch break; // 背压 + Canceled 退出

            const stream = self.listener.?.server.accept(self.io) catch |err| {
                self.listener.?.semaphore.post(self.io);
                if (err == error.Canceled) break;
                if (self.isShuttingDown()) break;
                _ = self.runtime.accept_errors.fetchAdd(1, .monotonic);
                std.log.warn("accept error: {s}", .{@errorName(err)});
                continue;
            };

            self.spawnConnection(stream) catch |e| {
                // spawnConnection 内部已用 errdefer 回滚（关流/释放/还名额），
                // 这里只记录，accept 循环继续。
                std.log.warn("connection spawn failed: {s}", .{@errorName(e)});
            };
        }
    }

    /// 派发一个连接。返回错误时（分配失败）已回滚全部已认领资源，可安全重试。
    fn spawnConnection(self: *Server, stream: std.Io.net.Stream) !void {
        const conn = self.allocator.create(Conn) catch {
            stream.close(self.io);
            self.listener.?.semaphore.post(self.io);
            return error.OutOfMemory;
        };

        // 每个资源在"到手之后"注册 errdefer（LIFO 逆序回滚），与 zio 版同构。
        errdefer self.allocator.destroy(conn);
        errdefer stream.close(self.io);
        errdefer self.listener.?.semaphore.post(self.io);

        const read_buf = try self.allocator.alloc(u8, @max(self.config.http.read_buffer_size, MIN_READ_BUF));
        errdefer self.allocator.free(read_buf);

        const write_buf = try self.allocator.alloc(u8, @max(self.config.http.write_buffer_size, MIN_WRITE_BUF));
        errdefer self.allocator.free(write_buf);

        // accept 返回的 socket.address 即对端地址（内核提供，不可伪造），
        // 供 per-IP 限流 / 审计日志 / Geofence 使用。
        conn.* = .{
            .server = self,
            .stream = stream,
            .peer_ip = stream.socket.address,
            .read_buf = read_buf,
            .write_buf = write_buf,
        };

        // Group.async 无返回值：线程池饱和时任务会内联跑（阻塞本任务=accept
        // 循环），这正是 `run` 把 async_limit 设为 unlimited 的原因——
        // 并发上限完全交给背压信号量。
        self.group.async(self.io, connectionTask, .{conn});
    }

    /// 每连接的 std 侧资源 + 生命周期。持有 net.Stream 与缓冲区，
    /// 建好带超时的 reader/writer 后交给后端无关的 ConnectionRunner。
    const Conn = struct {
        server: *Server,
        stream: std.Io.net.Stream,
        read_buf: []u8,
        write_buf: []u8,
        /// 对端 IP（accept 时内核提供，不可伪造）。
        peer_ip: ?std.Io.net.IpAddress,

        fn run(self: *Conn) void {
            const s = self.server;
            defer self.stream.close(s.io);

            // std 原生 reader/writer 没有 per-operation 超时，这里用
            // TimedReader/TimedWriter 对齐 zio 后端的 setTimeout 语义。
            var reader = TimedReader.init(
                s.io,
                self.stream.socket.handle,
                timeoutFromNs(s.config.network.read_timeout_ns),
                self.read_buf,
            );
            var writer = TimedWriter.init(
                s.io,
                self.stream.socket.handle,
                timeoutFromNs(s.config.network.write_timeout_ns),
                self.write_buf,
            );

            // 汇合点：把 std.Io 读写接口交给后端无关的 HTTP 引擎。
            var runner = ConnectionRunner{
                .reader = &reader.interface,
                .writer = &writer.interface,
                .io = s.io,
                .router = s.router,
                .config = &s.config,
                .lifecycle = s.lifecycle,
                .stats = &s.runtime,
                .allocator = s.allocator,
                .services = s.services,
                .peer_ip = self.peer_ip,
            };
            runner.run();

            // 可观测性：超时/断连的底层原因藏在 ReadFailed/WriteFailed 后面，
            // ConnectionRunner 只能看到笼统错误，这里补记真实原因。
            if (reader.err) |err| std.log.debug("read ended by: {s}", .{@errorName(err)});
            if (writer.err) |err| std.log.debug("write ended by: {s}", .{@errorName(err)});
        }

        fn destroy(self: *Conn) void {
            const s = self.server;
            s.allocator.free(self.read_buf);
            s.allocator.free(self.write_buf);
            s.allocator.destroy(self);
            s.listener.?.semaphore.post(s.io); // 归还背压名额
        }
    };

    fn connectionTask(conn: *Conn) void {
        conn.run();
        conn.destroy();
    }
};

const MIN_READ_BUF = 2 * 1024;
const MIN_WRITE_BUF = 512;

/// ns → Io.Timeout。0 表示不设超时（`.none` 时 operateTimeout 直接走 operate）。
fn timeoutFromNs(ns: u64) std.Io.Timeout {
    if (ns == 0) return .none;
    return .{ .duration = .{
        .raw = std.Io.Duration.fromNanoseconds(@intCast(ns)),
        .clock = .awake,
    } };
}

/// 带 per-operation 超时的 socket 读适配器。vtable 形状照抄 std 的
/// `net.Stream.Reader`，差别只在底层 `net_read` 操作经由 `io.operateTimeout`
/// 执行：超时 → `error.ReadFailed`，并把底层原因记进 `err`
/// （`error.TimedOut` 表示读超时），ConnectionRunner 看到 ReadFailed 即关连接。
///
/// Windows 例外：std Threaded 的批处理对 net_read/net_write 尚未接重叠 I/O
/// （源码 TODO，`operateTimeout` 返回 ConcurrencyUnavailable），退化为纯阻塞读。
const TimedReader = struct {
    io: std.Io,
    handle: std.Io.net.Socket.Handle,
    timeout: std.Io.Timeout,
    /// 最近一次失败的底层错误，仅供诊断日志。
    err: ?anyerror = null,
    interface: std.Io.Reader,

    /// 与 std `net.Stream.max_iovecs_len` 一致（0.17 中该常量为私有，这里对齐其值）。
    const max_iovecs = 8;

    fn init(io: std.Io, handle: std.Io.net.Socket.Handle, timeout: std.Io.Timeout, buffer: []u8) TimedReader {
        return .{
            .io = io,
            .handle = handle,
            .timeout = timeout,
            .interface = .{
                .vtable = &.{ .stream = streamImpl, .readVec = readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    /// 底层 `net_read` 的结果：0.17 是 `Error!usize`；0.18 起改成
    /// `Error!net.Stream.ReadResult`（字节数在 `data_len`）。用 `@hasDecl` 探测
    /// 后取字节数，同一份源码两个工具链都能编译。
    fn timedRead(self: *TimedReader, buffers: [][]u8) (std.Io.net.Stream.Reader.Error || error{TimedOut})!usize {
        const op: std.Io.Operation = .{ .net_read = .{
            .socket_handle = self.handle,
            .data = buffers,
        } };
        const result = if (is_windows) blk: {
            break :blk self.io.operate(op) catch |err| {
                self.err = err;
                return err;
            };
        } else self.io.operateTimeout(op, self.timeout) catch |err| switch (err) {
            error.Timeout => {
                self.err = error.TimedOut;
                return error.TimedOut;
            },
            // POSIX 的 batchAwaitConcurrent 对 net_read 用 poll 内联执行，不占并发额度。
            error.ConcurrencyUnavailable => unreachable,
            error.Canceled => |e| {
                self.err = e;
                return e;
            },
        };
        const got = result.net_read catch |err| {
            self.err = err;
            return err;
        };
        // comptime 已知为真的 if 不会对未选分支做语义分析，死分支里的
        // `.data_len` / `usize` 转换在对应版本上不会报错。
        return if (@hasDecl(std.Io.net.Stream, "ReadResult")) got.data_len else got;
    }

    fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const r: *TimedReader = @alignCast(@fieldParentPtr("interface", io_r));
        var iovecs_buffer: [max_iovecs][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        std.debug.assert(dest[0].len > 0);
        const n = r.timedRead(dest) catch {
            return error.ReadFailed; // 底层原因已由 timedRead 记进 r.err
        };
        if (n == 0) return error.EndOfStream;
        if (n > data_size) {
            // writableVector 可能把读区扩展到 reader 自有 buffer 的空闲尾部，
            // 多读到的字节计入 buffered 而不是丢弃（与 std Stream.Reader 同处理）。
            io_r.end += n - data_size;
            return data_size;
        }
        return n;
    }
};

/// 带 per-operation 超时的 socket 写适配器。照抄 std `net.Stream.Writer` 的
/// drain 形状（不含 control/sendFile——默认 vtable 会退回逐块写路径），
/// 底层 `net_write` 走 `io.operateTimeout`；Windows 同 `TimedReader` 退化。
const TimedWriter = struct {
    io: std.Io,
    handle: std.Io.net.Socket.Handle,
    timeout: std.Io.Timeout,
    err: ?anyerror = null,
    interface: std.Io.Writer,

    fn init(io: std.Io, handle: std.Io.net.Socket.Handle, timeout: std.Io.Timeout, buffer: []u8) TimedWriter {
        return .{
            .io = io,
            .handle = handle,
            .timeout = timeout,
            .interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = buffer,
            },
        };
    }

    fn timedWrite(self: *TimedWriter, op: std.Io.Operation) (std.Io.net.Stream.Writer.Error || error{TimedOut})!std.Io.Operation.Result {
        if (comptime is_windows) {
            return self.io.operate(op) catch |err| {
                self.err = err;
                return err;
            };
        }
        return self.io.operateTimeout(op, self.timeout) catch |err| switch (err) {
            error.Timeout => {
                self.err = error.TimedOut;
                return error.TimedOut;
            },
            error.ConcurrencyUnavailable => unreachable,
            error.Canceled => |e| {
                self.err = e;
                return e;
            },
        };
    }

    fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const w: *TimedWriter = @alignCast(@fieldParentPtr("interface", io_w));
        const buffered = io_w.buffered();
        const op: std.Io.Operation = .{ .net_write = .{
            .socket_handle = w.handle,
            .header = buffered,
            .data = data,
            .splat = splat,
        } };
        const result = w.timedWrite(op) catch {
            return error.WriteFailed; // 底层原因已由 timedWrite 记进 w.err
        };
        const n = result.net_write catch |err| {
            w.err = err;
            return error.WriteFailed;
        };
        return io_w.consume(n);
    }
};

// ── 关机信号（平台分支全部收在本文件内）──────────────────────────────

/// 进程级关机标志：信号处理器只能是无捕获的 C 函数（POSIX 异步信号上下文），
/// 只能碰全局。一个进程同一时刻只跑一个 std 后端 Server（旧 std 实现同约定）。
var shutdown_requested: std.atomic.Value(bool) = .init(false);

fn markShutdownRequested() void {
    shutdown_requested.store(true, .monotonic);
}

fn posixSignalHandler(sig: std.posix.SIG) callconv(.c) void {
    _ = sig;
    markShutdownRequested();
}

const win = if (is_windows) struct {
    const windows = std.os.windows;

    extern "kernel32" fn SetConsoleCtrlHandler(
        handler: ?*const fn (windows.DWORD) callconv(.winapi) windows.BOOL,
        add: windows.BOOL,
    ) callconv(.winapi) windows.BOOL;

    /// Ctrl+C (0)、Ctrl+Break (1)、控制台关闭 (2) 均触发优雅关机。
    /// 返回 TRUE 表示已自行处理——进程必须在 run() 退出后自行终止；控制台
    /// 关闭场景下系统只等约 5 秒便会强杀进程。
    fn ctrlHandler(ctrl_type: windows.DWORD) callconv(.winapi) windows.BOOL {
        return switch (ctrl_type) {
            0, 1, 2 => blk: {
                markShutdownRequested();
                break :blk .TRUE;
            },
            else => .FALSE, // 注销/关机事件交给系统默认处理
        };
    }

    fn install() bool {
        return SetConsoleCtrlHandler(ctrlHandler, .TRUE) != .FALSE;
    }

    fn uninstall() void {
        _ = SetConsoleCtrlHandler(ctrlHandler, .FALSE);
    }
} else void;

fn installShutdownHandlers() void {
    if (comptime is_windows) {
        if (!win.install()) {
            std.log.warn("SetConsoleCtrlHandler 注册失败：优雅关机不可用，进程只能被外部 kill", .{});
        }
    } else {
        // 不设 SA_RESTART：信号打断阻塞 syscall 后走 Threaded 的 EINTR 路径，
        // 与 std 自身 SIG.IO 取消机制行为一致（非取消的 EINTR 会自动重试）。
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = posixSignalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &act, null);
        std.posix.sigaction(.TERM, &act, null);
    }
}

fn uninstallShutdownHandlers() void {
    if (comptime is_windows) win.uninstall();
}

test "max_connections=0 is rejected at startup" {
    var config = http_app.NetworkConfig{ .max_connections = 0 };
    try std.testing.expectError(error.MaxConnectionsZero, Listener.init(std.testing.io, &config));
}
