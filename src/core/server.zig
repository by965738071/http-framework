//! HTTP 服务器实现
//!
//! # 性能与设计说明
//!
//! ## 关键优化（基于 1000 并发压测结果）
//!
//! ### 1. HTTP/1.1 keep-alive
//! 在同一个 TCP 连接上循环处理多个请求，直到客户端关闭、
//! 发送 `Connection: close`、或配置禁用了 keep-alive。
//!
//! ### 2. 低分配请求处理
//! - `Response` 在栈上分配，头部/Cookie 字符串请求结束时统一释放
//! - 路由匹配先无分配 dry-run，命中后才提取路径参数
//! - 读写缓冲区在连接生命周期内复用
//!
//! ### 3. 错误弹性与响应保证
//! - `accept` 错误不终止服务器
//! - 任何请求路径（404/405/中间件拦截/handler 错误）都保证发送响应
//! - 请求体读取失败（BodyTooLarge 等）会将连接标记为 poisoned，
//!   响应后关闭连接，避免残余字节污染下一个请求的解析
//!
//! ### 4. 优雅关闭
//! - SIGINT/SIGTERM（POSIX）或控制台 Ctrl 事件（Windows）触发 shutdown
//! - 信号处理器只做一次原子写（async-signal-safe），不关 fd、不打日志
//! - accept 循环跑在 `io.concurrent` 的工作线程上，由 `Future.cancel` 唤醒；
//!   监听套接字在 accept 循环退出之后才关闭
//! - drain 只等处理中的请求；空闲的 keep-alive 连接随后由 `Group.cancel` 取消

const std = @import("std");
const builtin = @import("builtin");
const http = std.http;
const net = std.Io.net;

const Config = @import("config.zig").Config;
const RequestContext = @import("request.zig");
const Response = @import("response.zig");
const Router = @import("router.zig");
const log = @import("log.zig");
const Logger = log.Logger;
const observer_mod = @import("observer.zig");
const RequestObserver = observer_mod.RequestObserver;
const RequestInfo = observer_mod.RequestInfo;
const Worker = @import("worker.zig").Worker;
const conn_state_mod = @import("conn_state.zig");
const ConnState = conn_state_mod.ConnState;
const ConnStatePool = conn_state_mod.ConnStatePool;
const PoolStats = conn_state_mod.Stats;

/// 读/写缓冲区的下限。
///
/// 这里只兜底最小值，**不设上限**：缓冲区改成按 config 堆分配之后，
/// 配多大就真占多大，没有理由再截断用户的意图。
/// （从前的 64KiB 上限是栈分配时代的产物——栈帧按编译期常量开，
///   config 调小一个字节都省不下来，只能靠常量封顶。）
///
/// 下限仍然必要：`std.http.Server.receiveHead` 要求整个请求头装得进读缓冲，
/// 缓冲区太小会让所有请求都变成 `HttpHeadersOversize`。
const MIN_READ_BUF_SIZE: usize = 2 * 1024;
const MIN_WRITE_BUF_SIZE: usize = 512;

/// 后台 Worker 的 tick 间隔（纳秒）
const WORKER_TICK_INTERVAL_NS: u64 = 50_000_000; // 50ms

/// run() 不再轮询停止标志：信号处理器/外部调用通过 `std.Io.Event.set`
/// 做 futex 唤醒，`run()` 用 `Event.wait` 阻塞，无需轮询间隔常量。
allocator: std.mem.Allocator,
io: std.Io,
tcp_server: net.Server,
/// 路由器（指针引用，生命周期由调用方管理，必须长于 Server）。
/// 使用指针而非值拷贝：值拷贝会让 Server.init 之后注册的路由静默失效
/// （ArrayList 共享底层指针但长度不同步）。
router: *Router,
config: Config,

/// 日志接收端（可选）。未设置时退回内置的 `std.log` 转发实现。
/// 实现由调用方持有并负责释放，Server 只保存一份轻量句柄。
logger: ?Logger = null,

/// 未显式设置 logger 时使用的兜底实现（转发到 `std.log`）
default_logger: log.StdLogger = .{},

/// 请求观察者（可选）：metrics / tracing 等由 addon 实现
observer: ?RequestObserver = null,

/// 周期性后台工作者（可选）：任务队列排空、会话清理等由 addon 实现
worker: ?Worker = null,

/// 当前活跃连接数（原子操作，含 keep-alive 空闲等待中的连接）
active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

/// 累计接受过的连接数
total_connections: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

/// `accept` 返回错误的次数（不含关服时的取消）
accept_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

/// 派发不出并发任务、只能在 accept 线程上就地处理连接的次数。
///
/// 这个数只要不是 0，就说明 `max_connections` 配得比底层 `Io` 实际能跑的
/// 并发任务数还高——信号量放行了，但 `Io` 已经没有容量了。
/// 详见 `acceptLoop` 里的处理。
inline_fallbacks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

/// 因内存不足借不到 ConnState 而放弃的连接数
conn_state_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

/// 当前正在处理中的请求数（原子操作，优雅关闭的等待对象）。
///
/// 关闭时等的是「请求」而不是「连接」：keep-alive 空闲连接会一直挂在
/// receiveHead 上（当前读取器不带空闲超时，不会自行断开），拿它当等待条件
/// 会让 Ctrl+C 一直卡到这些连接被取消。空闲连接在 drain 之后由
/// `conn_group.cancel` 直接取消。
active_requests: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

/// 优雅关闭等待超时（纳秒，默认 30 秒）
drain_timeout_ns: u64 = 30_000_000_000,

/// 是否正在关闭（原子标志）
shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

/// 服务器运行标志（原子，shutdown 可能从信号处理器线程调用）
running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

/// tcp_server 是否已被关闭（原子，防止 shutdown + deinit 双重释放）
server_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

/// 关闭信号事件（futex 原语），代替 run() 里的 sleep 轮询。
/// 信号处理器 / 外部调用通过 `shutdown()` 做原子置位 + futex 唤醒，
/// `run()` 用 `Event.wait` 阻塞，不空转、不延迟。
/// 初始为 `unset`；`set` 是 sticky 的（置位后保持），`run()` 只调用一次，无需 reset。
shutdown_event: std.Io.Event = .unset,

/// 优雅关闭 drain 用的完成事件（futex 原语），代替原 `drainConnections` 里的
/// 10ms sleep 轮询。在途请求归零时由连接完成路径 `set`，`drainConnections` 用
/// `Event.waitTimeout` 阻塞等待（带绝对截止时间）；超时则带剩余请求返回。
/// `run()` 只调用一次，事件初始 `unset`，不会被提前置位。
drain_event: std.Io.Event = .unset,

/// 后台 drain 循环的句柄（shutdown 时取消并等待）
bg_future: ?std.Io.Future(void) = null,

/// 并发连接信号量（背压）。
/// permits 初始化为 config.max_connections；accept 循环在接收新连接前
/// 获取一个许可，连接结束时归还。达到上限时 accept 阻塞，由内核 backlog
/// 排队新连接。max_connections 为 0 时不启用（无限制）。
conn_semaphore: std.Io.Semaphore = .{ .permits = 0 },

/// 连接处理任务组。
/// 不能用裸 `io.concurrent` 派发连接：那样返回的 Future 没有任何人 await/cancel，
/// 每条连接都会泄漏一个 Future 分配。Group 保证任务一返回就释放自身资源，
/// 关闭时再用 `cancel` 收尾（对已结束的任务是 no-op）。
conn_group: std.Io.Group = .init,

/// 连接内存池：读缓冲 + 写缓冲 + 每请求 arena。
///
/// 每条连接从这里借一套，连接结束时归还。缓冲区因此**跨连接复用**，
/// 而不是每条连接现开一份（更不是每条连接在栈上开固定 128KiB）。
conn_pool: ConnStatePool,

const Self = @This();
pub const Server = Self;

// =========================================================================
// 初始化与启动
// =========================================================================

pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config, router: *Router) !Self {
    // TLS 配置存在但未实现：诚实报错，而不是静默退回明文 HTTP
    if (config.tls_enabled) {
        return error.TlsNotSupported;
    }

    const address = try net.IpAddress.parseIp4(config.address, config.port);
    const tcp_server = try address.listen(io, .{
        .kernel_backlog = config.tcp_backlog,
        .reuse_address = config.reuse_address,
    });

    const conn_pool = try ConnStatePool.init(allocator, .{
        .read_size = @max(config.read_buffer_size, MIN_READ_BUF_SIZE),
        .write_size = @max(config.write_buffer_size, MIN_WRITE_BUF_SIZE),
        .pool_size = config.conn_pool_size,
    });

    var server: Self = .{ .allocator = allocator, .io = io, .tcp_server = tcp_server, .router = router, .config = config, .conn_pool = conn_pool };
    server.conn_semaphore.permits = config.max_connections;
    return server;
}

/// 服务器运行时快照。
///
/// 这些数字里最值钱的是**快路径什么时候失效**：`pool_misses`、
/// `inline_fallbacks`、`conn_state_failures` 都是「配置和实际负载对不上」
/// 的直接证据，而不是内部实现细节。拿它们喂 metrics 比看 QPS 更能定位问题。
pub const Stats = struct {
    /// 当前活跃连接数（含 keep-alive 空闲等待中的）
    active_connections: u32,
    /// 当前正在处理中的请求数
    active_requests: u32,
    /// 累计接受过的连接数
    total_connections: u64,
    /// accept 出错次数（不含关服取消）
    accept_errors: u64,
    /// 并发容量耗尽、退化为就地处理的次数。
    /// **非 0 说明 `max_connections` 高于底层 Io 的并发上限。**
    inline_fallbacks: u64,
    /// 内存不足借不到 ConnState 而放弃的连接数
    conn_state_failures: u64,
    /// 连接内存池计数。`pool_misses` 持续增长说明 `conn_pool_size`
    /// 低于实际并发（每条溢出连接都要现场堆分配）；`discarded`
    /// 增长说明峰值已过、池在缩容。稳态下两者都应停止增长。
    pool: PoolStats,
};

/// 取运行时快照。可从任意线程调用。
pub fn stats(self: *Self) Stats {
    return .{
        .active_connections = self.active_connections.load(.monotonic),
        .active_requests = self.active_requests.load(.monotonic),
        .total_connections = self.total_connections.load(.monotonic),
        .accept_errors = self.accept_errors.load(.monotonic),
        .inline_fallbacks = self.inline_fallbacks.load(.monotonic),
        .conn_state_failures = self.conn_state_failures.load(.monotonic),
        .pool = self.conn_pool.stats(self.io),
    };
}

/// 注入日志实现（如 `observability.FileLogger`）。
/// 句柄指向的实现由调用方持有，其生命周期必须长于 Server。
pub fn setLogger(self: *Self, logger: Logger) void {
    self.logger = logger;
}

/// 注入请求观察者（如 `observability.MetricsCollector`）
pub fn setObserver(self: *Self, obs: RequestObserver) void {
    self.observer = obs;
}

/// 注入周期性后台工作者（如 `background.BackgroundQueue`）
pub fn setWorker(self: *Self, w: Worker) void {
    self.worker = w;
}

/// 当前生效的日志句柄：未注入时退回内置 `std.log` 实现。
fn sink(self: *Self) Logger {
    return self.logger orelse self.default_logger.logger();
}

/// 启动服务器事件循环，阻塞至服务器被关闭。
pub fn run(self: *Self) !void {
    // 把日志句柄注入 Router。必须在这里做（而不是 init）：Server 按值返回，
    // 只有此刻 self.default_logger 才有稳定地址。
    self.router.setLogger(self.sink());

    self.running.store(true, .monotonic);
    self.serverLog(.info, "Server listening on {s}:{d}", .{ self.config.address, self.config.port });

    // 设置信号处理（优雅关闭）
    try self.setupSignalHandlers();
    // 后台工作者：独立 tick 循环，与连接处理解耦。
    // （不挂在每个连接的请求循环上——那样没有请求时任务永远不会执行，
    //   且会阻塞该连接的后续请求。）
    if (self.worker != null) {
        const future = try self.io.concurrent(struct {
            fn loop(s: *Self) void {
                s.workerLoop();
            }
        }.loop, .{self});
        self.bg_future = future;
    }

    // accept 循环必须跑在 std.Io 的工作线程上，不能留在主线程：
    // Threaded 的取消是给工作线程发 SIGIO 打断阻塞中的 syscall，而主线程不在
    // 它的线程表里（Thread.current == null），对主线程取消是 no-op——
    // accept 会一直阻塞，唤醒不了。
    var accept_future = self.io.concurrent(struct {
        fn loop(s: *Self) !void {
            try s.acceptLoop();
        }
    }.loop, .{self}) catch |err| {
        // 派发失败就没法提供服务了。先收掉已经起来的 worker 循环——
        // 它还持有 self，run() 一返回调用方就可能销毁 Server。
        self.running.store(false, .monotonic);
        self.shutting_down.store(true, .monotonic);
        if (self.bg_future) |*f| {
            f.cancel(self.io);
            self.bg_future = null;
        }
        return err;
    };

    // 主线程只等停止信号。用 Event.wait 阻塞在 futex 上，而不是 sleep 轮询：
    // 信号处理器 / 外部调用通过 shutdown() 做一次原子置位 + futex 唤醒，
    // 这里立刻返回，不空转、不延迟。wait 是取消点，被打断时直接退出循环。
    self.shutdown_event.wait(self.io) catch {};

    // =========================================================================
    // 优雅关闭：drain 阶段
    // =========================================================================

    self.serverLog(.info, "Shutting down server gracefully...", .{});

    // 唤醒并等待 accept 循环退出。cancel 会持续给工作线程发信号，
    // 直到阻塞中的 accept 返回 error.Canceled 且任务真正结束。
    // cancel 返回 accept 任务的错误结果（若其因并发耗尽而返回），关服阶段忽略。
    accept_future.cancel(self.io) catch {};

    self.shutting_down.store(true, .monotonic);

    // accept 循环已确定退出，此时关监听 fd 才没有并发使用者。
    self.closeListener();

    // 停止后台 worker 循环并等待其退出
    if (self.bg_future) |*f| {
        f.cancel(self.io);
        self.bg_future = null;
    }

    self.drainConnections();

    // 收尾：drain 超时后仍然挂起的连接在这里被取消，同时释放任务组资源。
    // 对已经跑完的连接任务是 no-op。
    self.conn_group.cancel(self.io);
}

/// accept 循环：接收连接并为每个连接派发处理任务。
/// 运行在 `io.concurrent` 的工作线程上，靠 `Future.cancel` 唤醒退出。
/// 派发失败（`concurrent` 返回错误）即结束本循环并向上返回错误——
/// 不在此就地执行，也不静默降级。
fn acceptLoop(self: *Self) !void {
    while (self.running.load(.monotonic)) {
        // 并发连接限流：达到上限时阻塞 accept 线程，新连接由内核 backlog 排队。
        if (self.config.max_connections > 0) {
            self.conn_semaphore.wait(self.io) catch |werr| {
                if (werr == error.Canceled) break;
                continue;
            };
        }

        const stream = self.tcp_server.accept(self.io) catch |accept_err| {
            // 未能建立连接：归还刚刚获取的许可
            if (self.config.max_connections > 0) self.conn_semaphore.post(self.io);
            // shutdown 触发的取消 → 退出循环
            if (accept_err == error.Canceled or accept_err == error.SocketNotListening) {
                break;
            }
            // 其它错误（如 fd 暂时耗尽）→ 记录并继续
            _ = self.accept_errors.fetchAdd(1, .monotonic);
            self.serverLog(.warn, "Accept error: {}", .{accept_err});
            continue;
        };

        _ = self.total_connections.fetchAdd(1, .monotonic);

        // 为每个新 TCP 连接派发一个并发任务。
        // 许可由 handleConnection 在连接结束时归还（无论走哪条路径）。
        const Dispatch = struct {
            // `conn_group` 的任务函数只能是 `void` 或 `error{Canceled}!void`，
            // 所以这里把 `handleConnection` 的 `!void` 错误在边界收掉：
            // 连接级错误（如 OOM）直接结束这条连接任务，由关服时的
            // `conn_group.cancel` 统一回收。
            fn handler(ctx: *Self, sock: net.Stream) void {
                handleConnection(ctx, sock) catch |err| {
                    std.log.err( "server error :{}", .{err});
                };
            }
        };
        self.conn_group.concurrent(
            self.io,
            Dispatch.handler,
            .{ self, stream },
        ) catch |conc_err| {
            // 到这里说明信号量放行了、但底层 Io 已经没有并发容量
            // ——`max_connections` 配得比 Io 实际能跑的任务数还高。
            //
            // 从前这里直接 `stream.close()`：客户端收到一个 RST，
            // 日志只写一句"并发上限"，请求就这么凭空消失了。这不是背压，
            // 是丢流量——真正的背压应该让**新连接排队**，而不是把已经
            // 三次握手完成的连接扔掉。
            //
            // 改成 `Group.async`：它不返回错误，派发不出去就在当前线程
            // 就地执行。代价是这条连接处理完之前 accept 循环不再收新连接，
            // 内核 backlog 替我们排队——这正是想要的形状。
            // 单线程 Io 下这也是服务器唯一能工作的路径。
            self.serverLog(
                .warn,
                "Io concurrency exhausted ({}), dropping connection; " ++
                    "consider lowering max_connections (currently {d}) to match the Io concurrency limit",
                .{ conc_err, self.config.max_connections },
            );
            stream.close(self.io);
            return conc_err;
        };
    }
}

/// 后台工作者 tick 循环：周期执行，直到服务器关闭。
fn workerLoop(self: *Self) void {
    const w = self.worker orelse return;
    while (!self.shutting_down.load(.monotonic)) {
        w.tick();
        self.io.sleep(std.Io.Duration{ .nanoseconds = WORKER_TICK_INTERVAL_NS }, .awake) catch return;
    }
    // 关闭前最后执行一次，尽量不丢任务
    w.tick();
}

// =========================================================================
// 连接处理（keep-alive 循环）
// =========================================================================

/// 处理一个完整的 TCP 连接生命周期。
/// 返回 `!void`：连接级错误（如连接池借不到内存）向上传播，由 `conn_group`
/// 的任务框架在关服 cancel 时丢弃；正常的连接关闭 / 协议错误已在函数内处理。
fn handleConnection(self: *Self, stream: net.Stream) !void {
    const io = self.io;
    defer stream.close(io);
    // 归还并发连接许可（与 accept 循环的获取配对）
    const release_conn = self.config.max_connections > 0;
    defer if (release_conn) self.conn_semaphore.post(io);

    // 服务器正在关闭，拒绝新连接
    if (self.shutting_down.load(.monotonic)) {
        return;
    }

    _ = self.active_connections.fetchAdd(1, .monotonic);
    defer _ = self.active_connections.fetchSub(1, .monotonic);

    // 从池里借一套「读缓冲 + 写缓冲 + 每请求 arena」。稳态下这只是摘一个链表节点；
    // 池空时会现场堆分配（计入 pool_misses），仍然不会卡住 accept。
    // 借不到（OOM）直接向上传播错误，由任务框架在关服 cancel 时丢弃。
    const state = try self.conn_pool.acquire(io);
    defer self.conn_pool.release(io, state);

    // 用标准库 `net.Reader` 读取 HTTP。它不带空闲超时：
    // 当前 `std.Io` 后端（含 Windows Threaded）暂不支持带超时的 socket 读，
    // 空闲 keep-alive 连接靠客户端关闭或关服取消来释放。
    var reader = stream.reader(io, state.read_buf);
    var writer = stream.writer(io, state.write_buf);

    var http_server = http.Server.init(&reader.interface, &writer.interface);

    // 可恢复错误计数器：防止无限重试导致资源泄漏
    var recoverable_errors: u32 = 0;
    const max_recoverable_errors: u32 = 10;

    // ---------- keep-alive 主循环 ----------
    while (true) {
        if (self.shutting_down.load(.monotonic)) break;

        // --- 步骤 1: 接收 HTTP 请求头 ---
        var http_request = http_server.receiveHead() catch |head_err| {
            if (isConnectionClosed(head_err)) {
                break;
            }
            if (isProtocolError(head_err)) {
                self.requestLog("[REQUEST] Protocol error: Bad Request", .{});
                writeErrorResponse(&writer.interface, .bad_request, "Bad Request");
                break;
            }
            // `error.ReadFailed` 不带原因，真实错误在 reader.err 里。
            // 关服时的取消（Canceled）是正常的连接结束，不记为错误。
            if (reader.err) |read_err| switch (read_err) {
                error.Canceled => break,
                else => {},
            };
            self.requestLog("[REQUEST] receiveHead error: {}", .{head_err});
            break;
        };

        // --- 步骤 2: 处理单个请求 ---
        _ = self.active_requests.fetchAdd(1, .monotonic);
        const keep = self.processRequest(io, state, &http_request, &recoverable_errors);
        // 请求处理完：递减在途计数，归零时唤醒 drain（sticky 事件，set 一次即可）。
        const prev = self.active_requests.fetchSub(1, .monotonic);
        if (prev == 1) self.drain_event.set(io);

        // 一次性回收本请求的全部分配。留一段容量给同一连接上的下个请求，
        // 否则 keep-alive 的每个请求都要重新向 OS 要内存。
        state.resetArena(self.config.request_arena_retain_bytes);

        if (recoverable_errors >= max_recoverable_errors) {
            self.requestLog("Too many recoverable errors ({d}), closing connection", .{recoverable_errors});
            break;
        }
        if (!keep) break;
    }
}

/// 处理单个 HTTP 请求。返回 true 表示连接可继续复用（keep-alive）。
///
/// `state` 提供每请求 arena。ctx / response 的所有分配都走它，
/// 请求结束后由调用方一次 `resetArena` 回收——单次 `free` 在 arena 上是
/// no-op，这正是想要的：请求路径上不再有逐块归还的开销。
///
/// 因此**不要把 ctx / response 分配的内存存到请求之外**（会话存储、
/// 后台队列等），它在下一个请求开始前就失效了。跨请求存活的数据请用
/// 各 addon 自己的 allocator。
fn processRequest(
    self: *Self,
    io: std.Io,
    state: *ConnState,
    http_request: *http.Server.Request,
    recoverable_errors: *u32,
) bool {
    const arena = state.allocator();

    // --- 初始化请求上下文 ---
    var ctx = RequestContext.init(arena, io, http_request) catch |ctx_err| {
        self.requestLog("[ERROR] RequestContext init failed: {}", .{ctx_err});
        return false;
    };
    defer ctx.deinit();
    ctx.body_size_limit = self.config.body_size_limit;
    ctx.lazy_read_size = self.config.lazy_read_size;
    ctx.trust_proxy = self.config.trust_proxy_headers;

    // 记录请求到达（访问日志，可配置关闭）
    if (self.config.access_log_enabled) {
        self.requestLog("[REQUEST] {s} {s}", .{
            @tagName(ctx.method),
            ctx.path,
        });
    }

    // --- 初始化响应构建器 ---
    var response = Response.init(arena, http_request);
    defer response.deinit();
    response.server_name = self.config.server_name;
    response.accept_encoding = ctx.getHeader("Accept-Encoding");

    // --- 路由分发 ---
    // 注：CORS / 鉴权等横切逻辑一律走 `router.use()` 全局中间件，
    // Server 不为任何具体 addon 开后门。
    const dispatch_start = std.Io.Timestamp.now(io, .awake).nanoseconds;
    const matched = self.router.dispatch(&ctx, &response) catch |dispatch_err| {
        self.requestLog("[ERROR] {s} {s} -> dispatch: {}", .{
            @tagName(ctx.method),
            ctx.path,
            dispatch_err,
        });
        self.handleDispatchError(&ctx, &response, dispatch_err);
        recoverable_errors.* += 1;
        return self.shouldKeepAlive(http_request, &ctx, &response);
    };

    if (!matched) {
        // 无匹配路由且无自定义 404 处理器 → 发送默认 404 页面
        sendErrorPage(&response, .not_found, null);
    } else {
        // 请求成功：重置错误计数器
        recoverable_errors.* = 0;
    }

    // 响应兜底：任何"已处理"路径（中间件拦截、405、handler 忘记写响应）
    // 都必须真正发送响应，否则客户端会挂起
    if (!response.responded) {
        response.text("") catch |send_err| {
            self.requestLog("[RESPONSE] fallback send failed: {}", .{send_err});
        };
    } else if (response.stream_open) {
        // handler 开了流但没 end()。响应头已经发出去了，这里补不回来，
        // 只能记一笔并让 shouldKeepAlive 关掉连接（由 close 给客户端一个了断）。
        self.requestLog("[RESPONSE] {s} {s} -> stream left open, closing connection", .{
            @tagName(ctx.method),
            ctx.path,
        });
    }

    // 记录响应状态（访问日志）
    if (self.config.access_log_enabled) {
        self.requestLog("[RESPONSE] {s} {s} -> {s}", .{
            @tagName(ctx.method),
            ctx.path,
            @tagName(response.status),
        });
    }

    // 通知请求观察者（route pattern 而非原始路径，避免指标标签基数爆炸）
    if (self.observer) |obs| {
        const latency = std.Io.Timestamp.now(io, .awake).nanoseconds - dispatch_start;
        obs.record(RequestInfo{
            .method = ctx.method,
            .route_pattern = ctx.route_pattern,
            .status = response.status,
            .latency_ns = @intCast(latency),
        });
    }

    return self.shouldKeepAlive(http_request, &ctx, &response);
}

/// 判定当前请求处理后连接是否可继续复用。
fn shouldKeepAlive(
    self: *Self,
    http_request: *http.Server.Request,
    ctx: *const RequestContext,
    response: *const Response,
) bool {
    // 流式响应没收尾：chunked 缺结束块 / content-length 没写满，
    // 报文本身就是残缺的，复用连接只会让下一个请求跟着错位
    if (response.stream_open) return false;
    // 请求体未完整消费：残余字节会污染下一个请求的解析，必须关闭
    if (ctx.poisoned) return false;
    // handler 用 bodyStream() 开了流但没读到 EOF：同上，socket 上还压着
    // 本请求的 body 字节，复用会把它们当成下一个请求的头部
    if (ctx.body_streaming and !ctx.bodyDrained()) return false;
    // WebSocket 升级后连接已被接管/结束
    if (ctx.is_websocket) return false;
    if (self.shutting_down.load(.monotonic)) return false;
    if (!self.config.keep_alive_enabled) return false;
    return http_request.head.keep_alive;
}

// =========================================================================
// 错误分类与处理
// =========================================================================

fn isConnectionClosed(err: std.http.Server.ReceiveHeadError) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "HttpConnectionClosing") or
        std.mem.eql(u8, name, "EndOfStream") or
        std.mem.eql(u8, name, "BrokenPipe") or
        std.mem.eql(u8, name, "ConnectionResetByPeer");
}

fn isProtocolError(err: anytype) bool {
    const name = @errorName(err);
    return std.mem.eql(u8, name, "HttpHeadersOversize") or
        std.mem.eql(u8, name, "HttpHeadersInvalid");
}

fn handleDispatchError(self: *Self, ctx: *RequestContext, response: *Response, err: anyerror) void {
    // handler 已发送（部分）响应：无法再次写入，只能让连接层关闭
    if (response.responded) return;

    if (self.router.error_handler) |eh| {
        eh(err, ctx, response) catch |eh_err| {
            self.requestLog("Error handler failed: {}", .{eh_err});
            if (!response.responded) {
                sendErrorPage(response, .internal_server_error, null);
            }
        };
    } else {
        // 默认错误映射：可识别的客户端错误返回对应状态码
        const status: http.Status = switch (err) {
            error.BodyTooLarge, error.BodyTooLargeToBuffer => .payload_too_large,
            error.HttpExpectationFailed => .expectation_failed,
            error.EmptyBody, error.NoContentType => .bad_request,
            error.UnsupportedContentType => .unsupported_media_type,
            else => .internal_server_error,
        };
        sendErrorPage(response, status, null);
    }
}

/// 在协议错误（请求头无法解析）时直接写原始错误响应。
/// 此时没有可用的 std.http.Server.Request 状态机，直接写 socket 并关闭连接。
fn writeErrorResponse(writer: *std.Io.Writer, status: http.Status, body: []const u8) void {
    const status_text = http.Status.phrase(status) orelse "Error";
    writer.print(
        "HTTP/1.1 {d} {s}\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ @backingInt(status), status_text, body.len, body },
    ) catch return;
    writer.flush() catch {};
}

// =========================================================================
// 清理
// =========================================================================

pub fn deinit(self: *Self) void {
    self.serverLog(.info, "Server shutting down", .{});
    self.running.store(false, .monotonic);
    self.shutting_down.store(true, .monotonic);
    // 唤醒可能阻塞在 run() 的 Event.wait 上的主线程（与旧实现里
    // run 轮询 running 标志的语义一致）。无等待者时 set 是 no-op。
    self.shutdown_event.set(self.io);
    self.closeListener();

    // 必须先收干净连接任务，再销毁内存池：每条在跑的连接都持有一个借出的
    // ConnState，池先死会让它们对着已释放的缓冲区读写。
    // `run()` 正常返回时这里是 no-op（Group 的 token 已为 null），
    // 但 deinit 也可能在没跑过 run() 的路径上被调用（测试、init 后即弃）。
    self.conn_group.cancel(self.io);
    self.conn_pool.deinit(self.io);

    // 摘掉 Router 持有的日志句柄：它可能指向 self.default_logger，
    // Router 比 Server 活得久时会变成悬垂指针。
    self.router.clearLogger();
}

/// 关闭监听套接字（幂等，shutdown/deinit 共用）
fn closeListener(self: *Self) void {
    if (self.server_closed.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
        self.tcp_server.deinit(self.io);
    }
}

// =========================================================================
// 优雅关闭支持
// =========================================================================

fn setupSignalHandlers(self: *Self) !void {
    const S = struct {
        var server_ptr: ?*Self = null;

        fn posixHandler(sig: std.posix.SIG) callconv(.c) void {
            _ = sig;
            if (server_ptr) |s| s.shutdown();
        }

        fn windowsHandler(ctrl_type: u32) callconv(.c) i32 {
            _ = ctrl_type;
            if (server_ptr) |s| {
                s.shutdown();
            }
            return 1;
        }
    };
    S.server_ptr = self;

    if (builtin.os.tag == .windows) {
        const handler_fn = @extern(*const fn (handler: *const fn (u32) callconv(.c) i32, add: i32) callconv(.c) i32, .{ .library_name = "kernel32", .name = "SetConsoleCtrlHandler" });
        _ = handler_fn(S.windowsHandler, 1);
    } else {
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = S.posixHandler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(.INT, &act, null);
        std.posix.sigaction(.TERM, &act, null);
    }
}

/// 请求停止服务器。可从任意线程调用，也可从信号处理器调用。
///
/// 这里只做两件 async-signal-safe 的事，别加任何东西：
/// - `running.store(false)`：原子写，信号安全；
/// - `shutdown_event.set`：原子交换 + 裸 futex 唤醒（Threaded 后端是 `__ulock` /
///   `futex` syscall，不持锁、不分配），同样信号安全。
///
/// 真正的 accept 唤醒由 `run()` 里对 accept 任务的 `Future.cancel` 完成，
/// 监听套接字也在那之后才关闭。
pub fn shutdown(self: *Self) void {
    self.running.store(false, .monotonic);
    self.shutdown_event.set(self.io);
}

/// 等待处理中的请求跑完（或超时）。在 run() 中 accept 循环退出后自动调用。
///
/// 等的是 `active_requests` 而不是 `active_connections`：keep-alive 空闲连接
/// 会一直挂在 receiveHead 上（当前读取器不带空闲超时，不会自行断开），
/// 只能由调用方随后的 `conn_group.cancel` 取消。所以不能等 `active_connections`，
/// 否则会卡到 cancel 才结束。
///
/// 阻塞在 `std.Io.Event`（`drain_event`）上（带绝对截止时间），而不是 10ms sleep
/// 轮询：在途请求归零时由 `handleConnection` 的完成路径 `set` 唤醒。超时则带着
/// 剩余在途请求返回，交给随后的 `conn_group.cancel` 收尾。
pub fn drainConnections(self: *Self) void {
    self.shutting_down.store(true, .monotonic);

    const initial = self.active_requests.load(.monotonic);
    self.serverLog(.info, "Graceful shutdown: draining {d} in-flight requests ({d} open connections)...", .{
        initial,
        self.active_connections.load(.monotonic),
    });

    if (initial > 0) {
        // 一次性绝对截止时间：总等待不超过 drain_timeout_ns（waitTimeout 内部用绝对
        // 截止时间，反复进入也不会重置计时）。
        const dur: std.Io.Clock.Duration = .{
            .raw = std.Io.Duration{ .nanoseconds = self.drain_timeout_ns },
            .clock = .awake,
        };
        const deadline: std.Io.Clock.Timestamp = std.Io.Clock.Timestamp.fromNow(self.io, dur);
        const timeout: std.Io.Timeout = .{ .deadline = deadline };

        // 阻塞在 drain_event 上直到在途请求归零（完成路径 set 唤醒），或超时。
        // 完成路径只在计数归零时 set 一次，事件 sticky，不会丢唤醒。
        while (self.active_requests.load(.monotonic) > 0) {
            self.drain_event.waitTimeout(self.io, timeout) catch break;
        }
    }

    const remaining = self.active_requests.load(.monotonic);
    self.serverLog(.info, "Graceful shutdown complete: {d} requests still in flight", .{remaining});
}

pub fn isRunning(self: *const Self) bool {
    return self.running.load(.monotonic);
}

// =========================================================================
// 日志辅助函数
// =========================================================================

/// 服务器级日志（生命周期事件）
fn serverLog(self: *Self, level: log.Level, comptime fmt: []const u8, args: anytype) void {
    self.sink().print(level, fmt, args);
}

/// 请求级日志（高频，固定 debug 级别，由日志实现自行过滤）
fn requestLog(self: *Self, comptime fmt: []const u8, args: anytype) void {
    self.sink().print(.debug, fmt, args);
}

// =========================================================================
// 自定义错误页面
// =========================================================================

fn sendErrorPage(response: *Response, status: http.Status, message: ?[]const u8) void {
    const status_text = http.Status.phrase(status) orelse "Unknown Error";
    const msg = message orelse status_text;

    var buf: [1024]u8 = undefined;
    const html = std.fmt.bufPrint(&buf,
        \\<!DOCTYPE html>
        \\<html>
        \\<head><title>{s}</title></head>
        \\<body>
        \\  <h1>{s}</h1>
        \\  <p>{s}</p>
        \\</body>
        \\</html>
    , .{ status_text, status_text, msg }) catch "Error";

    response.statusCode(status).html(html) catch {};
}

// ===========================================================================
// 测试
// ===========================================================================

test "graceful shutdown: active_connections counter" {
    var counter = std.atomic.Value(u32).init(0);

    // 模拟连接进入
    _ = counter.fetchAdd(1, .monotonic);
    try std.testing.expectEqual(@as(u32, 1), counter.load(.monotonic));

    _ = counter.fetchAdd(1, .monotonic);
    try std.testing.expectEqual(@as(u32, 2), counter.load(.monotonic));

    // 模拟连接退出
    _ = counter.fetchSub(1, .monotonic);
    try std.testing.expectEqual(@as(u32, 1), counter.load(.monotonic));

    _ = counter.fetchSub(1, .monotonic);
    try std.testing.expectEqual(@as(u32, 0), counter.load(.monotonic));
}

test "graceful shutdown: shutting_down flag" {
    var flag = std.atomic.Value(bool).init(false);

    try std.testing.expectEqual(false, flag.load(.monotonic));

    flag.store(true, .monotonic);
    try std.testing.expectEqual(true, flag.load(.monotonic));

    flag.store(false, .monotonic);
    try std.testing.expectEqual(false, flag.load(.monotonic));
}

test "graceful shutdown: drainConnections when no active connections" {
    const allocator = std.testing.allocator;

    var test_config = Config.defaults();
    test_config.port = 0; // ephemeral port

    var router = Router.init(allocator);
    defer router.deinit();

    const io = std.testing.io;
    var server = Self.init(allocator, io, test_config, &router) catch {
        // 端口绑定失败时跳过测试
        return;
    };
    defer server.deinit();

    // 不调用 run()，直接测试 drain
    // 所有连接都应已处理完毕（0 个活跃连接）
    server.drainConnections();

    // drain 完成后，active_connections 应为 0
    try std.testing.expectEqual(@as(u32, 0), server.active_connections.load(.monotonic));
    try std.testing.expectEqual(true, server.shutting_down.load(.monotonic));
}

test "graceful shutdown: drainConnections respects timeout" {
    const allocator = std.testing.allocator;

    var test_config = Config.defaults();
    test_config.port = 0; // ephemeral port

    var router = Router.init(allocator);
    defer router.deinit();

    const io = std.testing.io;
    var server = Self.init(allocator, io, test_config, &router) catch {
        return;
    };
    defer server.deinit();

    // 模拟有一个处理中的请求（drain 等的是请求，不是连接）
    _ = server.active_requests.fetchAdd(1, .monotonic);

    // 设置极短的超时（1ms），确保超时触发
    server.drain_timeout_ns = 1_000_000;

    server.drainConnections();

    // 超时后请求计数仍为 1（请求未真正结束），但 shutting_down 标志应已设置
    try std.testing.expectEqual(@as(u32, 1), server.active_requests.load(.monotonic));
    try std.testing.expectEqual(true, server.shutting_down.load(.monotonic));
}

test "graceful shutdown: 空闲 keep-alive 连接不拖慢 drain" {
    const allocator = std.testing.allocator;

    var test_config = Config.defaults();
    test_config.port = 0; // ephemeral port

    var router = Router.init(allocator);
    defer router.deinit();

    const io = std.testing.io;
    var server = Self.init(allocator, io, test_config, &router) catch {
        return;
    };
    defer server.deinit();

    // 一条已建立但空闲的 keep-alive 连接：active_connections 计数，
    // 但没有请求在处理中。drain 不应该等它。
    _ = server.active_connections.fetchAdd(1, .monotonic);
    server.drain_timeout_ns = 30_000_000_000;

    const start = std.Io.Timestamp.now(io, .awake).nanoseconds;
    server.drainConnections();
    const elapsed = std.Io.Timestamp.now(io, .awake).nanoseconds - start;

    // 立即返回，而不是耗满 30s 超时
    try std.testing.expect(elapsed < 1_000_000_000);
}

test "连接池: 按 config 尺寸预分配，缓冲区不再是编译期常量" {
    const allocator = std.testing.allocator;

    var test_config = Config.defaults();
    test_config.port = 0;
    test_config.read_buffer_size = 4096;
    test_config.write_buffer_size = 1024;
    test_config.conn_pool_size = 8;

    var router = Router.init(allocator);
    defer router.deinit();

    const io = std.testing.io;
    var server = Self.init(allocator, io, test_config, &router) catch return;
    defer server.deinit();

    // 预分配到位：稳态并发下 acquire 全部走快路径
    try std.testing.expectEqual(@as(u32, 8), server.stats().pool.idle);

    // 借出来的缓冲区是 config 说的大小，不是从前那个 64KiB 编译期上限
    const state = try server.conn_pool.acquire(io);
    defer server.conn_pool.release(io, state);
    try std.testing.expectEqual(@as(usize, 4096), state.read_buf.len);
    try std.testing.expectEqual(@as(usize, 1024), state.write_buf.len);
}

test "连接池: 过小的 buffer 配置被抬到下限而不是让请求头永远装不下" {
    const allocator = std.testing.allocator;

    var test_config = Config.defaults();
    test_config.port = 0;
    test_config.read_buffer_size = 16; // 荒谬的小值
    test_config.write_buffer_size = 1;
    test_config.conn_pool_size = 1;

    var router = Router.init(allocator);
    defer router.deinit();

    const io = std.testing.io;
    var server = Self.init(allocator, io, test_config, &router) catch return;
    defer server.deinit();

    const state = try server.conn_pool.acquire(io);
    defer server.conn_pool.release(io, state);
    try std.testing.expectEqual(MIN_READ_BUF_SIZE, state.read_buf.len);
    try std.testing.expectEqual(MIN_WRITE_BUF_SIZE, state.write_buf.len);
}

test "连接池: 并发超过池容量时落空计数可见" {
    const allocator = std.testing.allocator;

    var test_config = Config.defaults();
    test_config.port = 0;
    test_config.conn_pool_size = 1;

    var router = Router.init(allocator);
    defer router.deinit();

    const io = std.testing.io;
    var server = Self.init(allocator, io, test_config, &router) catch return;
    defer server.deinit();

    const a = try server.conn_pool.acquire(io); // 命中
    const b = try server.conn_pool.acquire(io); // 池空 → 现场分配

    const s = server.stats().pool;
    try std.testing.expectEqual(@as(u64, 1), s.pool_hits);
    try std.testing.expectEqual(@as(u64, 1), s.pool_misses);

    server.conn_pool.release(io, a);
    server.conn_pool.release(io, b);
}

test "Server.init: TLS enabled returns TlsNotSupported" {
    const allocator = std.testing.allocator;

    var test_config = Config.defaults();
    test_config.tls_enabled = true;
    test_config.tls_cert_file = "/tmp/cert.pem";
    test_config.tls_key_file = "/tmp/key.pem";

    var router = Router.init(allocator);
    defer router.deinit();

    try std.testing.expectError(
        error.TlsNotSupported,
        Self.init(allocator, std.testing.io, test_config, &router),
    );
}
